# frozen_string_literal: true

# V1 to V4 HTTP provider and V3/V4 message provider features, verified through the pact_ffi
# verifier functions. Mirrors tests/provider.rs in the pact-reference FFI runner.
#
# Pact files are written through the FFI; the provider, the provider state callback and the Pact
# broker are small local servers (support/servers.rb) that record what they receive. A message
# provider answers the verifier's POST with the message: the body, its content type, and the
# metadata as base64 JSON in the `pact-message-metadata` header.

def provider_spec = http_spec(@version)

# Serves each interaction's response to a request with the same method and path; anything else is a 500.
def start_provider(interactions)
  @provider = CompatServers::Server.new do |req, _port|
    i = interactions.find { |x| x.method.casecmp?(req.method) && x.path == req.path_only }
    if i
      CompatServers::Response.new(i.status, i.response.headers, i.response.body || '')
    else
      CompatServers::Response.new(500, [], 'no matching interaction')
    end
  end
  server = @provider
  @cleanups << -> { server.stop }
end

def provider_dir = File.join(@tmp, 'provider-pacts')

def write_provider_pact(consumer)
  pact = CompatFfi::Raw.new_pact(consumer, 'p')
  CompatFfi::Raw.with_specification(pact, provider_spec)
  yield pact
  rc = CompatFfi::Raw.pact_handle_write_file(pact, provider_dir, false)
  CompatFfi::Raw.free_pact_handle(pact)
  raise "pactffi_pact_handle_write_file failed with #{rc}: #{CompatFfi.last_error}" unless rc.zero?

  File.join(provider_dir, "#{consumer}-p.json")
end

# A one-interaction pact, as a consumer test would have written it; the block adds states, comments etc.
def write_interaction_pact(n)
  interaction = interaction_n(n)
  write_provider_pact("c_#{n}") do |pact|
    i = register(pact, interaction)
    yield i if block_given?
  end
end

def push_interaction_pact(n, &block)
  (@pact_files ||= []) << write_interaction_pact(n, &block)
end

# A one-message pact whose description is the message name, which the message provider looks it up by.
def push_message_pact(name)
  file = write_provider_pact("c_#{name}") do |pact|
    yield CompatFfi::Raw.new_message_interaction(pact, name)
  end
  (@pact_files ||= []) << file
end

# Cucumber regex captures keep `\"`; `{string}` would have unescaped it.
def unescape(s) = s.gsub('\\"', '"')

def message_part(cell)
  part = CompatModel::Part.new
  setup_body(unescape(cell), part)
  part
end

def message_body(i, cell, rules = nil)
  part = message_part(cell)
  part.matching_rules = rules
  register_part(i, CompatFfi::REQUEST, part)
end

def metadata_value(value)
  v = value.strip
  v.start_with?('JSON:') ? JSON.parse(v.delete_prefix('JSON:').strip) : value
end

# pactffi_with_metadata parses the value as JSON and falls back to a string.
def add_message_metadata(i, key, value)
  v = value.strip.start_with?('JSON:') ? value.strip.delete_prefix('JSON:').strip : value
  raise "pactffi_with_metadata failed for #{key}" unless CompatFfi::Raw.with_metadata(i, key, v, CompatFfi::REQUEST)
end

def add_comments(i, rows)
  rows.drop(1).each do |text, kind|
    case kind
    when 'text' then CompatFfi::Raw.add_text_comment(i, text)
    when 'testname' then CompatFfi::Raw.set_comment(i, 'testname', JSON.dump(text))
    else raise "unknown comment type #{kind}"
    end
  end
end

def add_provider_message(name, body, metadata = {})
  (@messages ||= []) << [name, message_part(body), metadata]
end

# Serves every message the scenario defined; the verifier POSTs `{"description": ...}` for each one.
def start_message_provider
  messages = @messages
  @provider = CompatServers::Server.new do |req, _port|
    description = (JSON.parse(req.body)['description'] rescue nil).to_s
    name, part, metadata = messages.find { |n, _, _| n == description }
    if name
      ct = part.header('content-type') || 'text/plain'
      meta = { 'contentType' => ct }.merge(metadata)
      CompatServers::Response.new(200, [['Content-Type', ct], ['pact-message-metadata', Base64.strict_encode64(JSON.dump(meta))]],
                   part.body || '')
    else
      CompatServers::Response.json(404, { 'error' => "no message '#{description}'" })
    end
  end
  server = @provider
  @cleanups << -> { server.stop }
end

def start_state_callback(fail)
  @state_callback = CompatServers::Server.new do |_req, _port|
    fail ? CompatServers::Response.json(500, { 'error' => 'state change failed' }) : CompatServers::Response.json(200, {})
  end
  server = @state_callback
  @cleanups << -> { server.stop }
end

def state_calls
  (@state_callback&.requests || []).filter_map { |r| JSON.parse(r.body) rescue nil }
end

def state_called?(action, state = nil, params = {})
  state_calls.any? do |c|
    c['action'] == action && (state.nil? || c['state'] == state) &&
      params.all? { |k, v| (c['params'] || {})[k] == v }
  end
end

def published(n)
  (@brokers || []).select { |i, _| i == n }.flat_map { |_, b| b.requests }
                  .select { |r| r.method == 'POST' && r.path_only.end_with?('/verification-results') }
                  .filter_map { |r| JSON.parse(r.body) rescue nil }
end

# Maps the suite's error wording onto the verifier's JSON report.
def verifier_error?(entries, error)
  types = Array(entries).flat_map { |r| r.dig('mismatch', 'mismatches') || [] }.map { |m| m['type'] }
  has = ->(*t) { types.intersect?(t) }
  case error
  when 'Response status did not match' then has.('StatusMismatch')
  when 'Headers had differences' then has.('HeaderMismatch')
  when 'Body had differences' then has.('BodyMismatch', 'BodyTypeMismatch')
  when 'Body type had differences' then has.('BodyTypeMismatch')
  when 'Metadata had differences' then has.('MetadataMismatch')
  when 'State change request failed' then JSON.dump(entries).include?('state change handlers has failed')
  else raise "unknown error #{error}"
  end
end

def published_with(n, success)
  pub = published(n)
  raise "no verification result with success = #{success} for interaction #{n}: #{pub}" \
    unless pub.any? { |r| r['success'] == success }
end

Given('a provider is started that returns the response from interaction {int}') do |n|
  start_provider([interaction_n(n)])
end

Given('a provider is started that returns the response from interaction {int}, with the following changes:') do |n, table|
  i = interaction_n(n)
  rows = table.raw
  rows[0].zip(rows[1]).each do |col, value|
    case col
    when 'response' then i.status = value.to_i
    when 'response headers' then i.response.headers.concat(parse_headers(value))
    when 'response body' then setup_body(value, i.response)
    else raise "unsupported change column #{col}"
    end
  end
  start_provider([i])
end

Given('a provider is started that returns the responses from interactions {string}') do |ids|
  start_provider(ids.split(',').map { |id| interaction_n(id.strip.to_i) })
end

Given(/^a Pact file for interaction (\d+) is to be verified$/) do |n|
  push_interaction_pact(n)
end

Given(/^a Pact file for interaction (\d+) is to be verified with a provider state "(.*)" defined$/) do |n, state|
  push_interaction_pact(n) { |i| CompatFfi::Raw.given(i, state) }
end

Given(/^a Pact file for interaction (\d+) is to be verified with the following provider states defined:$/) do |n, table|
  rows = table.raw
  params_col = rows[0].index('Parameters')
  push_interaction_pact(n) do |i|
    rows.drop(1).each do |row|
      params = params_col && row[params_col].to_s.strip
      if params.nil? || params.empty?
        CompatFfi::Raw.given(i, row[0])
      else
        rc = CompatFfi::Raw.given_with_params(i, row[0], params)
        raise "pactffi_given_with_params failed with #{rc}" unless rc.zero?
      end
    end
  end
end

Given(/^a Pact file for interaction (\d+) is to be verified, but is marked pending$/) do |n|
  push_interaction_pact(n) { |i| CompatFfi::Raw.set_pending(i, true) }
end

Given(/^a Pact file for interaction (\d+) is to be verified with the following comments:$/) do |n, table|
  push_interaction_pact(n) { |i| add_comments(i, table.raw) }
end

Given(/^a provider is started that can generate the "(.*)" message with "(.*)"$/) do |name, body|
  add_provider_message(name, body)
end

Given(/^a provider is started that can generate the "(.*)" message with "(.*)" and the following metadata:$/) do |name, body, table|
  add_provider_message(name, body, table.raw.drop(1).to_h { |k, v| [k, metadata_value(v)] })
end

Given(/^a Pact file for "([^"]*)":"(.*)" is to be verified$/) do |name, body|
  push_message_pact(name) { |i| message_body(i, body) }
end

Given(/^a Pact file for "([^"]*)":"(.*)" is to be verified with provider state "(.*)"$/) do |name, body, state|
  push_message_pact(name) do |i|
    CompatFfi::Raw.given(i, state)
    message_body(i, body)
  end
end

Given(/^a Pact file for "([^"]*)":"(.*)" is to be verified, but is marked pending$/) do |name, body|
  push_message_pact(name) do |i|
    message_body(i, body)
    CompatFfi::Raw.set_pending(i, true)
  end
end

Given(/^a Pact file for "([^"]*)":"(.*)" is to be verified with the following comments:$/) do |name, body, table|
  push_message_pact(name) do |i|
    message_body(i, body)
    add_comments(i, table.raw)
  end
end

Given(/^a Pact file for "([^"]*)":"(.*)" is to be verified with the following metadata:$/) do |name, body, table|
  push_message_pact(name) do |i|
    message_body(i, body)
    table.raw.drop(1).each { |k, v| add_message_metadata(i, k, v) }
  end
end

# Rows of `body`, `matching rules` (a fixture or `JSON:`) and `metadata` (`key=value; ...`).
Given(/^a Pact file for "([^"]*)" is to be verified with the following:$/) do |name, table|
  rows = table.raw.to_h { |k, v| [k, v] }
  push_message_pact(name) do |i|
    message_body(i, rows['body'].to_s, matching_rules(rows['matching rules']))
    rows['metadata'].to_s.split(';').reject { |e| e.strip.empty? }.each do |entry|
      key, value = entry.strip.split('=', 2)
      raise "bad metadata #{entry}" unless value

      add_message_metadata(i, key, value)
    end
  end
end

# The broker serves the pacts-for-verification flow for one pact and accepts verification results.
Given(/^a Pact file for interaction (\d+) is to be verified from a Pact broker$/) do |n|
  n = n.to_i
  pact = JSON.parse(File.read(write_interaction_pact(n)))
  broker = CompatServers::Server.new do |req, port|
    base = "http://127.0.0.1:#{port}"
    pact_path = "/pacts/provider/p/consumer/c_#{n}"
    pact_url = base + pact_path
    for_verification = "#{base}/pacts/provider/p/for-verification"
    case [req.method, req.path_only]
    in ['GET', '/']
      CompatServers::Response.json(200, { '_links' => { 'pb:provider-pacts-for-verification' => {
                      'href' => "#{base}/pacts/provider/{provider}/for-verification", 'templated' => true
                    } } })
    in ['GET', '/pacts/provider/p/for-verification']
      CompatServers::Response.json(200, { '_links' => { 'self' => { 'href' => for_verification } } })
    in ['POST', '/pacts/provider/p/for-verification']
      CompatServers::Response.json(200, {
                      '_embedded' => { 'pacts' => [{
                        '_links' => { 'self' => { 'href' => pact_url, 'name' => "Pact between c_#{n} and p" } },
                        'shortDescription' => 'latest'
                      }] },
                      '_links' => { 'self' => { 'href' => for_verification } }
                    })
    in ['GET', ^pact_path]
      CompatServers::Response.json(200, pact.merge('_links' => {
                                      'self' => { 'href' => pact_url },
                                      'pb:publish-verification-results' => { 'href' => "#{pact_url}/verification-results" }
                                    }))
    in ['POST', String => path] if path.end_with?('/verification-results')
      CompatServers::Response.json(201, {})
    else
      CompatServers::Response.json(404, { 'error' => 'not found' })
    end
  end
  @cleanups << -> { broker.stop }
  (@brokers ||= []) << [n, broker]
end

Given('publishing of verification results is enabled') do
  @publish = true
end

Given('a provider state callback is configured') do
  start_state_callback(false)
end

Given('a provider state callback is configured, but will return a failure') do
  start_state_callback(true)
end

# pact_ffi has no request filter callback, only custom headers.
Given('a request filter is configured to make the following changes:') do |table|
  rows = table.raw
  rows[0].zip(rows[1]).each do |col, value|
    raise "pact_ffi has no request filter for #{col}; only pactffi_verifier_add_custom_header exists" unless col == 'headers'

    (@custom_headers ||= []).concat(parse_headers(value))
  end
end

When('the verification is run') do
  start_message_provider if @messages&.any?
  raise 'no provider started' unless @provider

  raw = CompatFfi::Raw
  v = raw.verifier_new_for_application('pact-ruby-compat', Pact::VERSION)
  raw.verifier_set_provider_info(v, 'p', 'http', '127.0.0.1', @provider.port, '/')
  raw.verifier_set_provider_state(v, @state_callback.url, 1, 1) if @state_callback
  raw.verifier_set_publish_options(v, '1.2.3', nil, nil, 0, nil) if @publish
  (@custom_headers || []).each { |k, val| raw.verifier_add_custom_header(v, k, val) }
  (@pact_files || []).each { |f| raw.verifier_add_file_source(v, f) }
  (@brokers || []).each do |_, b|
    raw.verifier_broker_source_with_selectors(v, b.url, nil, nil, nil, 0, nil, nil, 0, nil, nil, 0, nil, 0)
  end
  @exit = raw.verifier_execute(v)
  @output = CompatFfi.take_string(raw.verifier_output(v, 1)).to_s
  json = CompatFfi.take_string(raw.verifier_json(v))
  @results = json ? JSON.parse(json) : {}
  raw.verifier_shutdown(v)
end

Then('the verification will be successful') do
  raise "verification failed (exit #{@exit}):\n#{@output}" unless @exit.zero? && @results['result'] == true
end

Then('the verification will NOT be successful') do
  raise "verification passed (exit #{@exit})" if @exit.zero? || @results['result'] != false
end

Then('the verification results will contain a {string} error') do |error|
  raise "no \"#{error}\" error in the verification results: #{@results}" \
    unless verifier_error?(@results['interactionResults'], error)
end

Then('there will be a pending {string} error') do |error|
  raise "no pending \"#{error}\" error in the verification results: #{@results}" \
    unless verifier_error?(@results['pendingErrors'], error)
end

Then(/^the comment "(.*)" will have been printed to the console$/) do |comment|
  raise "comment '#{comment}' not in the verifier output:\n#{@output}" unless @output.include?(comment)
end

Then(/^the "(.*)" will displayed as the original test name$/) do |name|
  raise "test name '#{name}' not in the verifier output:\n#{@output}" unless @output.include?("Test Name: #{name}")
end

Then(/^the provider state callback will receive a setup call with "(.*)" and the following parameters:$/) do |state, table|
  params = json_params(table.raw)
  raise "no setup call for '#{state}' with #{params}: #{state_calls}" unless state_called?('setup', state, params)
end

Then(/^the provider state callback will receive a teardown call "(.*)" and the following parameters:$/) do |state, table|
  params = json_params(table.raw)
  raise "no teardown call for '#{state}' with #{params}: #{state_calls}" unless state_called?('teardown', state, params)
end

Then('a verification result will NOT be published back') do
  pub = (@brokers || []).flat_map { |n, _| published(n) }
  raise "verification results were published: #{pub}" unless pub.empty?
end

Then(/^a successful verification result will be published back for interaction \{(\d+)\}$/) do |n|
  published_with(n.to_i, true)
end

Then(/^a failed verification result will be published back for the interaction \{(\d+)\}$/) do |n|
  published_with(n.to_i, false)
end

Then('the provider state callback will be called before the verification is run') do
  raise "provider state callback was not called for setup: #{state_calls}" unless state_called?('setup')
end

Then(/^the provider state callback will receive a setup call with "(.*)" as the provider state parameter$/) do |state|
  raise "no setup call for '#{state}': #{state_calls}" unless state_called?('setup', state)
end

Then('the provider state callback will be called after the verification is run') do
  raise "provider state callback was not called for teardown: #{state_calls}" unless state_called?('teardown')
end

Then(/^the provider state callback will receive a teardown call "(.*)" as the provider state parameter$/) do |state|
  raise "no teardown call for '#{state}': #{state_calls}" unless state_called?('teardown', state)
end

Then('the provider state callback will NOT receive a teardown call') do
  raise "provider state callback received a teardown call: #{state_calls}" if state_called?('teardown')
end

# The reference suite does not check this either: the warning only goes to the log.
Then(/^a warning will be displayed that there was no provider state callback configured for provider state "(.*)"$/) do |_state|
  nil
end

Then(/^the request to the provider will contain the header "(.*)"$/) do |header|
  name, value = header.split(':', 2).map(&:strip)
  reqs = @provider.requests
  raise "not every provider request had #{name}: #{value}: #{reqs}" \
    if reqs.empty? || !reqs.all? { |r| r.header(name) == value }
end
