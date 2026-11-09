# frozen_string_literal: true

# V1 to V4 HTTP consumer features: a mock server built through the FFI and driven over HTTP.
# Mirrors tests/consumer.rs in the pact-reference FFI runner.

def start_mock_server(interactions)
  @pact = new_pact(http_spec(@version))
  interactions.each { |i| register(@pact, i) }
  port = CompatFfi::Raw.create_mock_server_for_transport(@pact, '127.0.0.1', 0, 'http', nil)
  raise "pactffi_create_mock_server_for_transport failed with #{port}: #{CompatFfi.last_error}" if port.negative?

  @port = port
  @cleanups << -> { CompatFfi::Raw.cleanup_mock_server(port) }
end

def mock_mismatches
  return @mismatches if @mismatches
  raise 'mock server not started' unless @port

  JSON.parse(CompatFfi::Raw.mock_server_mismatches(@port) || '[]')
end

def request_mismatches
  mock_mismatches.select { |m| m['type'] == 'request-mismatch' }.flat_map { |m| m['mismatches'] || [] }
end

# Applies a `| method | path | query | headers | body | ... |` changes table. `raw headers` are
# added on top of `headers` rather than replacing them, to send repeated headers.
def apply_changes(i, rows)
  raw_headers = []
  rows[0].zip(rows[1]).each do |field, value|
    case field
    when 'method' then i.method = value
    when 'path' then i.path = value
    when 'query' then i.query = value
    when 'headers' then i.request.headers = parse_headers(value)
    when 'body' then setup_body(value, i.request)
    when 'raw headers' then raw_headers = parse_headers(value)
    when 'matching rules' then i.request.matching_rules = matching_rules(value)
    end
  end
  i.request.headers.concat(raw_headers)
end

def send_to_mock_server(i)
  path = i.query.to_s.empty? ? i.path : "#{i.path}?#{i.query}"
  @response = http_request(@port, i.method, path, i.request.headers, i.request.body)
end

def mismatch_matches?(m, kind, error)
  t = m['type'].to_s
  right_type = t == 'BodyTypeMismatch' ? kind == 'body-content-type' : t.downcase.start_with?(kind)
  right_type && m['mismatch'].to_s.include?(error)
end

Given('the following HTTP interactions have been defined:') do |table|
  @interactions = setup_common_interactions(table.raw)
end

When('the mock server is started with interaction {int}') do |n|
  start_mock_server([interaction_n(n)])
end

When('the mock server is started with interaction {int} but with the following changes:') do |n, table|
  i = interaction_n(n)
  apply_changes(i, table.raw)
  start_mock_server([i])
end

When('the mock server is started with interactions {string}') do |list|
  start_mock_server(list.split(',').map { |n| interaction_n(n.strip) })
end

When('request {int} is made to the mock server') do |n|
  send_to_mock_server(interaction_n(n))
end

When('request {int} is made to the mock server with the following changes:') do |n, table|
  i = interaction_n(n)
  apply_changes(i, table.raw)
  send_to_mock_server(i)
end

Then(/^a (\d+) (success|error) response is returned$/) do |status, kind|
  next if @response.status == status.to_i

  raise "Expected #{kind == 'success' ? 'a success' : 'an error'} response of #{status} " \
        "but got #{@response.status}: #{@response.body}"
end

Then('the payload will contain the {string} JSON document') do |name|
  # pactffi_with_body parses JSON bodies, so only the JSON value survives, not the fixture's formatting.
  expected = File.binread(fixture_path("#{name}.json"))
  same = @response.body == expected ||
         (JSON.parse(@response.body) == JSON.parse(expected) rescue false) # rubocop:disable Style/RescueModifier
  raise "Expected payload #{expected} but got #{@response.body}" unless same
end

Then('the content type will be set as {string}') do |expected|
  actual = @response.header('content-type')
  raise 'Response does not contain a content-type header' unless actual
  raise "Expected response content-type of '#{expected}' but was '#{actual}'" unless actual == expected
end

When('the pact test is done') do
  raise 'mock server not started' unless @port

  mismatches = mock_mismatches
  CompatFfi::Raw.mock_server_matched(@port)
  if mismatches.empty?
    rc = CompatFfi::Raw.write_pact_file(@port, @pact_dir, true)
    raise "pactffi_write_pact_file failed with #{rc}" unless rc.zero?
  end
  @mismatches = mismatches
  CompatFfi::Raw.cleanup_mock_server(@port)
end

Then(/^the mock server will write out a Pact file for the interactions? when done$/) do
  load_pact_json
  expected = @version == 'v2' ? '2.0.0' : '1.0.0'
  actual = @pact_json.dig('metadata', 'pactSpecification', 'version')
  raise "Expected a #{expected} pact file but metadata.pactSpecification.version was #{actual}" unless actual == expected
end

Then(/^the mock server will NOT write out a Pact file for the interactions? when done$/) do
  raise "Expected no pact file, but found #{pact_file}" if File.exist?(pact_file)
end

Then('the mock server status will be OK') do
  m = mock_mismatches
  raise "Mock server has #{m.size} mismatches: #{m.to_json}" unless m.empty?
end

Then(/^the mock server status will (?:NOT be OK|be mismatches)$/) do
  raise 'Mock server has no mismatches' if mock_mismatches.empty?
end

Then(/^the pact file will contain \{(\d+)\} interactions?$/) do |n|
  count = (@pact_json['interactions'] || []).size
  raise "Expected the pact file to contain #{n} interaction(s), but had #{count}" unless count == n.to_i
end

Then(/^the \{(first|second|third)\} interaction request will be for a "(\w+)"$/) do |nth, method|
  actual = pact_interaction(nth).dig('request', 'method')
  raise "Expected request method #{method} but was #{actual}" unless actual.to_s.casecmp?(method)
end

Then(/^the \{(first|second|third)\} interaction request query parameters will be "(.*)"$/) do |nth, query|
  actual = pact_interaction(nth).dig('request', 'query')
  raise "Expected query #{query} but was #{actual.inspect}" unless pact_query(actual) == query_map(parse_query(query))
end

Then(/^the \{(first|second|third)\} interaction request will contain the header "(.*)" with value "(.*)"$/) do |nth, name, value|
  actual = pact_header(pact_interaction(nth)['request'], name)
  raise "Expected header #{name}: #{value} but was #{actual.inspect}" unless actual == value
end

Then(/^the \{(first|second|third)\} interaction request content type will be "(.*)"$/) do |nth, ct|
  request = pact_interaction(nth)['request']
  actual = pact_header(request, 'content-type') ||
           (request['body'].is_a?(Hash) || request['body'].is_a?(Array) ? 'application/json' : nil)
  raise "Expected request content type #{ct} but was #{actual.inspect}" unless actual == ct
end

Then(/^the \{(first|second|third)\} interaction (request|response) will contain the "(.*)" document$/) do |nth, part, fixture|
  compare_fixture_body(pact_interaction(nth)[part]['body'], fixture)
end

Then('the mismatches will contain a {string} mismatch with error {string}') do |kind, error|
  all = request_mismatches
  raise "Did not find a #{kind} mismatch with error #{error.inspect} in #{all.to_json}" unless
    all.any? { |m| mismatch_matches?(m, kind, error) }
end

Then('the mismatches will contain a {string} mismatch with path {string} with error {string}') do |kind, path, error|
  all = request_mismatches
  found = all.any? do |m|
    actual = { 'QueryMismatch' => m['parameter'], 'HeaderMismatch' => m['key'], 'BodyMismatch' => m['path'] }[m['type']]
    mismatch_matches?(m, kind, error) && actual == path
  end
  raise "Did not find a #{kind} mismatch at #{path} with error #{error.inspect} in #{all.to_json}" unless found
end

Then(/^the mock server status will be an unexpected "(\w+)" request received error for interaction \{(\d+)\}$/) do |method, n|
  i = interaction_n(n)
  expected_query = query_map(parse_query(i.query))
  all = mock_mismatches
  found = all.any? do |m|
    m['type'] == 'request-not-found' && m['method'] == method && m['path'] == i.path &&
      pact_query(m.dig('request', 'query')) == expected_query
  end
  raise "Did not find an unexpected #{method} request for interaction #{n} in #{all.to_json}" unless found
end

Then(/^the mock server status will be an unexpected "(\w+)" request received error for path "(.*)"$/) do |method, path|
  all = mock_mismatches
  raise "Did not find an unexpected #{method} request for #{path} in #{all.to_json}" unless
    all.any? { |m| m['type'] == 'request-not-found' && m['method'] == method && m['path'] == path }
end

Then(/^the mock server status will be an expected but not received error for interaction \{(\d+)\}$/) do |n|
  i = interaction_n(n)
  all = mock_mismatches
  raise "Did not find a missing request for interaction #{n} in #{all.to_json}" unless
    all.any? { |m| m['type'] == 'missing-request' && m['method'] == i.method && m['path'] == i.path }
end

# V3 and V4: interactions defined without a mock server, then written straight from the pact handle.

Given(/^an (integration|HTTP interaction) is being defined for a consumer test$/) do |_kind|
  @mode = :http
  @pact ||= new_pact(http_spec(@version)) # v4.feature mixes HTTP and message interactions in one pact
  @interaction = CompatFfi::Raw.new_interaction(@pact, 'interaction for a consumer test')
  CompatFfi::Raw.with_request(@interaction, 'GET', '/')
end

Given(/^a provider state "(.*)" (?:for the (?:synchronous )?message )?is specified$/) do |state|
  raise "pactffi_given failed: #{CompatFfi.last_error}" unless CompatFfi::Raw.given(@interaction, state)
end

Given(/^a provider state "(.*)" (?:for the (?:synchronous )?message )?is specified with the following data:$/) do |state, table|
  rc = CompatFfi::Raw.given_with_params(@interaction, state, json_params(table.raw).to_json)
  raise "pactffi_given_with_params failed with #{rc}" unless rc.zero?
end

Given(/^a key of "(.*)" is specified for the (?:HTTP|message|synchronous message) interaction$/) do |key|
  raise 'pactffi_set_key failed' unless CompatFfi::Raw.set_key(@interaction, key)
end

Given(/^the (?:HTTP|message|synchronous message) interaction is marked as pending$/) do
  raise 'pactffi_set_pending failed' unless CompatFfi::Raw.set_pending(@interaction, true)
end

Given(/^a comment "(.*)" is added to the (?:HTTP|message|synchronous message) interaction$/) do |comment|
  raise 'pactffi_add_text_comment failed' unless CompatFfi::Raw.add_text_comment(@interaction, comment)
end

When('the Pact file for the test is generated') do
  raise 'no pact is being defined' unless @pact

  write_pact_from_handle(@pact)
end

def first_provider_states
  pact_interaction('first')['providerStates'] || []
end

Then(/^the (?:interaction|first message) in the Pact file will contain (\d+) provider states?$/i) do |n|
  states = first_provider_states
  raise "Expected #{n} provider states but found #{states.to_json}" unless states.size == n.to_i
end

Then(/^the (?:interaction|first message) in the Pact file will contain provider state "(.*)"$/i) do |state|
  states = first_provider_states
  raise "No provider state '#{state}' in #{states.to_json}" unless states.any? { |s| s['name'] == state }
end

Then(/^the provider state "(.*)" (?:in the Pact file|for the message) will contain the following parameters:$/) do |state, table|
  expected = JSON.parse(table.raw[1][0])
  states = first_provider_states
  s = states.find { |x| x['name'] == state } or raise "No provider state '#{state}' in #{states.to_json}"
  raise "Expected parameters #{expected.to_json} but were #{s['params'].to_json}" unless s['params'] == expected
end

Then('the first interaction in the Pact file will have a type of {string}') do |expected|
  actual = pact_interaction('first')['type']
  raise "Expected type '#{expected}' but was #{actual.inspect}" unless actual == expected
end

# The expected value is JSON in single quotes.
Then(/^the first interaction in the Pact file will have "([^"]+)" = '(.*)'$/) do |name, value|
  expected = JSON.parse(value)
  actual = pact_interaction('first')[name]
  raise "Expected #{name} = #{expected.to_json} but was #{actual.to_json}" unless actual == expected
end
