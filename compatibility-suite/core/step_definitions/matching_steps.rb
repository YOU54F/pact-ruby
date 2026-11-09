# frozen_string_literal: true

# Steps for V3 http_matching.feature and V3/V4 matching_rules.feature. pact_ffi has no request
# comparison call, so each received request is sent to a mock server holding the expected one and
# the mock server's mismatches are read back.

def expected_match_interaction
  @expected ||= CompatModel::Interaction.new(
    'expected request', 'GET', '/', '', CompatModel::Part.new([], nil, nil), 200,
    CompatModel::Part.new([], nil, nil)
  )
end

def received_reqs = (@received_reqs ||= [])

def new_received_req = { query: '', part: CompatModel::Part.new([], nil, nil) }

# Fills a part and its query from one row of a `| body | content type | query | headers | ... |` table.
def match_apply_row(fields, values, target)
  get = ->(name) { (n = fields.index(name)) && values[n] }
  headers = get.('headers')
  target[:part].headers = parse_headers(headers) if headers && !headers.empty?
  if (body = get.('body'))
    ct = get.('content type')
    setup_body(body, target[:part], ct.nil? || ct.empty? ? nil : ct)
  end
  target[:query] = get.('query') if get.('query')
  target[:part].matching_rules = matching_rules(get.('matching rules')) if get.('matching rules')
end

def match_spec = @version == 'v4' ? 5 : 4

def compare_received(req)
  raw = CompatFfi::Raw
  pact = raw.new_pact(consumer_name, 'p')
  raw.with_specification(pact, match_spec)
  register(pact, expected_match_interaction)
  port = raw.create_mock_server_for_transport(pact, '127.0.0.1', 0, 'http', nil)
  if port.negative?
    raw.free_pact_handle(pact)
    raise "create_mock_server_for_transport failed with #{port}"
  end
  begin
    path = req[:query].empty? ? '/' : "/?#{req[:query]}"
    http_request(port, 'GET', path, req[:part].headers, req[:part].body)
    mismatches = JSON.parse(raw.mock_server_mismatches(port) || "[]")
  ensure
    raw.cleanup_mock_server(port)
    raw.free_pact_handle(pact)
  end
  mismatches.flat_map { |m| m['type'] == 'request-mismatch' ? (m['mismatches'] || []) : [m] }
end

def match_mismatch_path(m)
  field = case m['type']
          when 'QueryMismatch' then 'parameter'
          when 'HeaderMismatch', 'MetadataMismatch' then 'key'
          when 'BodyMismatch' then 'path'
          end
  field && m[field]
end

def match_description?(description, error)
  error = error.gsub('\\"', '"')
  description.include?(error) || (Regexp.new(error).match?(description) rescue false)
end

Given(/^an expected request with an? "([^"]*)" header of "([^"]*)"$/) do |name, value|
  expected_match_interaction.request.set_header(name, value)
end

Given(/^a request is received with an? "([^"]*)" header of "([^"]*)"$/) do |name, value|
  r = new_received_req
  r[:part].set_header(name, value)
  received_reqs << r
end

Given('an expected request configured with the following:') do |table|
  rows = table.raw
  target = { query: expected_match_interaction.query, part: expected_match_interaction.request }
  match_apply_row(rows[0], rows[1], target)
  expected_match_interaction.query = target[:query]
end

Given('a request is received with the following:') do |table|
  rows = table.raw
  r = new_received_req
  match_apply_row(rows[0], rows[1], r)
  received_reqs << r
end

Given('the following requests are received:') do |table|
  rows = table.raw
  rows[1..].each do |values|
    r = new_received_req
    match_apply_row(rows[0], values, r)
    received_reqs << r
  end
end

When(/^the requests? (?:is|are) compared to the expected one$/) do
  @match_results = received_reqs.map { |r| compare_received(r) }
end

Then('the comparison should be OK') do
  bad = @match_results.find(&:any?)
  raise "Expected all requests to match, got mismatches #{JSON.dump(bad)}" if bad
end

Then('the comparison should NOT be OK') do
  raise 'All requests matched' if @match_results.all?(&:empty?)
end

Then(/^the mismatches will contain a mismatch with error "(.*)" -> "(.*)"$/) do |path, error|
  all = @match_results.flatten
  found = all.any? { |m| match_mismatch_path(m) == path && match_description?(m['mismatch'].to_s, error) }
  raise "Did not find a mismatch at #{path} with error #{error.inspect} in #{JSON.dump(all)}" unless found
end

Given('an expected response configured with the following:') do |table|
  rows = table.raw
  rows[0].zip(rows[1]).each do |field, value|
    case field
    when 'status' then @expected_status = value.to_i
    when 'matching rules' then @response_rules = matching_rules(value)
    else raise "unsupported response field #{field}"
    end
  end
end

Given('a status {int} response is received') do |status|
  @received_status = status
end

# pact_ffi has no response comparison call, so verify a one-interaction pact against a provider
# returning the received status.
When('the response is compared to the expected one') do
  raw = CompatFfi::Raw
  pact = raw.new_pact(consumer_name, 'p')
  raw.with_specification(pact, match_spec)
  i = raw.new_interaction(pact, 'expected response')
  raw.with_request(i, 'GET', '/')
  raw.response_status(i, @expected_status)
  raw.with_matching_rules(i, CompatFfi::RESPONSE, @response_rules) if @response_rules
  FileUtils.mkdir_p(@pact_dir)
  rc = raw.pact_handle_write_file(pact, @pact_dir, true)
  raw.free_pact_handle(pact)
  raise "pact_handle_write_file failed with #{rc}" unless rc.zero?

  status = @received_status
  provider = CompatServers::Server.new { |_req, _port| CompatServers::Response.new(status, [], nil) }
  @cleanups << -> { provider.stop }
  v = raw.verifier_new_for_application('pact-ruby-compat', Pact::VERSION)
  raw.verifier_set_provider_info(v, 'p', 'http', '127.0.0.1', provider.port, '/')
  raw.verifier_add_file_source(v, pact_file)
  raw.verifier_execute(v)
  json = CompatFfi.take_string(raw.verifier_json(v))
  raw.verifier_shutdown(v)
  results = json ? JSON.parse(json) : {}
  @response_mismatches = Array(results['errors']).flat_map { |e| e.dig('mismatch', 'mismatches') || [] }
end

Then('the response comparison should be OK') do
  raise "Expected the response to match, got #{JSON.dump(@response_mismatches)}" unless @response_mismatches.empty?
end

Then('the response comparison should NOT be OK') do
  raise 'The response matched' if @response_mismatches.empty?
end

Then('the response mismatches will contain a {string} mismatch with error {string}') do |type, error|
  want = { 'status' => 'StatusMismatch', 'header' => 'HeaderMismatch', 'body' => 'BodyMismatch' }.fetch(type)
  found = @response_mismatches.any? { |m| m['type'] == want && m['mismatch'].to_s.include?(error) }
  raise "No #{want} with error #{error.inspect} in #{JSON.dump(@response_mismatches)}" unless found
end
