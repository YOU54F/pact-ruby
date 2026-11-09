# frozen_string_literal: true

# Steps for V3 generators.feature, V3 http_generators.feature and V4 generators.feature.
#
# pact_ffi has no call that generates a request or response, so generated values are observed the
# way a client sees them: a request by verifying a pact against a provider that records what it
# receives (with a state change server for a provider state context), and a response by sending a
# request to a mock server. The mock server URL generator needs a consumer-mode mock server context
# that an HTTP client cannot supply, so that scenario runs a V4 message's body generators through
# pactffi_generator_generate_string.

GeneratedPart = Struct.new(:status, :path, :headers, :body) do
  def header(name) = headers.find { |k, _| k.casecmp?(name) }&.last
end

GEN_VALUE_TYPES = {
  'integer' => /\A-?\d+\z/,
  'decimal number' => /\A-?\d+\.\d+\z/,
  'hexadecimal number' => /\A[a-fA-F0-9]+\z/,
  'string from the regex' => /\A\d{1,8}\z/,
  'date' => /\A\d{4}-\d{2}-\d{2}\z/,
  'time' => /\A\d{2}:\d{2}:\d{2}\z/,
  'date-time' => /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?/,
  'boolean' => /\A(true|false)\z/
}.merge(
  ['UUID', 'simple UUID', 'lower-case-hyphenated UUID', 'upper-case-hyphenated UUID', 'URN UUID'].to_h do |k|
    [k, /\A(urn:uuid:)?\h{8}-?\h{4}-?\h{4}-?\h{4}-?\h{12}\z/]
  end
).freeze

def gen_assert_value_type(kind, v)
  if ['random string', 'string from the regex'].include?(kind)
    raise "expected a string, got #{v.to_json}" unless v.is_a?(String)
    return if kind == 'random string'
  end
  pattern = GEN_VALUE_TYPES.fetch(kind) { raise "unknown value type #{kind}" }
  raise "expected a(n) #{kind}, got #{v.to_json}" unless json_to_string(v).match?(pattern)
end

def gen_spec = @version == 'v4' ? 5 : 4

# A `| body | generators |` table: the part, and the generators as JSON text.
def gen_configure(table)
  rows = table.raw
  part = CompatModel::Part.new([], nil, nil)
  generators = nil
  rows[0].zip(rows[1]).each do |field, value|
    case field
    when 'body' then setup_body(value, part)
    when 'generators'
      generators = value.start_with?('JSON:') ? value.delete_prefix('JSON:').strip : File.read(fixture_path(value))
    end
  end
  [part, generators]
end

def gen_write_pact(pact)
  FileUtils.mkdir_p(@pact_dir)
  rc = CompatFfi::Raw.pact_handle_write_file(pact, @pact_dir, true)
  CompatFfi::Raw.free_pact_handle(pact)
  raise "pact_handle_write_file failed with #{rc}" unless rc.zero?
end

def gen_prepare_request(state)
  raw = CompatFfi::Raw
  pact = raw.new_pact(consumer_name, 'p')
  raw.with_specification(pact, gen_spec)
  i = raw.new_interaction(pact, 'a request with generators')
  raw.given(i, 'a state') if state
  raw.with_request(i, 'GET', '/path/one')
  register_part(i, CompatFfi::REQUEST, @gen_request || CompatModel::Part.new([], nil, nil))
  raw.with_generators(i, CompatFfi::REQUEST, @gen_request_generators) if @gen_request_generators
  raw.response_status(i, 200)
  gen_write_pact(pact)

  provider = CompatServers::Server.new { |_req, _port| CompatServers::Response.new(200, [], nil) }
  @cleanups << -> { provider.stop }
  state_server = state && CompatServers::Server.new { |_req, _port| CompatServers::Response.json(200, state) }
  @cleanups << -> { state_server.stop } if state_server
  v = raw.verifier_new_for_application('pact-ruby-compat', Pact::VERSION)
  raw.verifier_set_provider_info(v, 'p', 'http', '127.0.0.1', provider.port, '/')
  raw.verifier_set_provider_state(v, state_server.url, 0, 1) if state_server
  raw.verifier_add_file_source(v, pact_file)
  raw.verifier_execute(v)
  raw.verifier_shutdown(v)

  req = provider.requests.first or raise 'the provider received no request'
  GeneratedPart.new(0, req.path, req.headers, req.body.to_s)
end

def gen_prepare_message_body(context)
  raw = CompatFfi::Raw
  pact = raw.new_pact(consumer_name, 'p')
  raw.with_specification(pact, 5)
  i = raw.new_message_interaction(pact, 'a message with generators')
  ct = @gen_request&.header('content-type') || 'application/json'
  body = @gen_request&.body.to_s
  raw.with_body(i, CompatFfi::REQUEST, ct, body.dup.force_encoding('UTF-8'))
  raw.with_generators(i, CompatFfi::REQUEST, @gen_request_generators) if @gen_request_generators
  generated = CompatFfi.async_body_generators_with_context(pact, JSON.dump(context))
  raw.free_pact_handle(pact)

  json = JSON.parse(body)
  generated.each do |path, value|
    raise "no value generated for #{path}" unless value

    keys = path.delete_prefix('$').split('.').reject(&:empty?)
    parent = keys[0..-2].reduce(json) { |o, k| o.fetch(k) }
    raise "#{path} is not in the body" unless parent.is_a?(Hash) && parent.key?(keys.last)

    parent[keys.last] = value
  end
  GeneratedPart.new(0, '', [], JSON.dump(json))
end

def gen_generated_body
  g = @generated_request || @generated_response or raise 'nothing was prepared'
  JSON.parse(g.body)
rescue JSON::ParserError => e
  raise "generated body is not JSON (#{e.message}): #{g.body.inspect}"
end

def gen_original_body
  part = @generated_request ? @gen_request : @gen_response
  JSON.parse(part&.body.to_s)
rescue JSON::ParserError
  nil
end

def gen_original_value(path)
  body_value(gen_original_body, path)
rescue StandardError
  :missing
end

# `header[X-TEST]` -> ['header', 'X-TEST']; `path` -> ['path', ''].
def gen_field(name)
  m = name.match(/\[(.*)\]/)
  m ? [name[0...m.begin(0)], m[1]] : [name, '']
end

def gen_request_field(g, name)
  f, key = gen_field(name)
  case f
  when 'path' then g.path.split('?').first
  when 'header' then g.header(key) || raise("no #{key} header in #{g.headers}")
  when 'queryParameter'
    pair = parse_query(g.path.split('?', 2)[1]).find { |k, _| k == key }
    pair ? pair.last : raise("no #{key} query parameter in #{g.path}")
  else raise "unknown request field #{f}"
  end
end

def gen_response_field(g, name)
  f, key = gen_field(name)
  case f
  when 'status' then g.status.to_s
  when 'header' then g.header(key) || raise("no #{key} header in #{g.headers}")
  else raise "unknown response field #{f}"
  end
end

Given('a request configured with the following generators:') do |table|
  @gen_request, @gen_request_generators = gen_configure(table)
end

Given('a response configured with the following generators:') do |table|
  @gen_response, @gen_response_generators = gen_configure(table)
end

Given('the generator test mode is set as {string}') do |mode|
  @gen_mode = mode
end

When('the request is prepared for use') do
  @generated_request = gen_prepare_request(nil)
end

When('the request is prepared for use with a {string} context:') do |kind, table|
  context = JSON.parse(table.raw[0][0])
  @generated_request =
    case kind
    when 'providerState' then gen_prepare_request(context)
    when 'mockServer'
      href = context['href']
      gen_prepare_message_body({ 'mockServer' => { 'url' => href, 'href' => href } })
    else raise "unknown context #{kind}"
    end
end

When('the response is prepared for use') do
  raw = CompatFfi::Raw
  pact = raw.new_pact(consumer_name, 'p')
  raw.with_specification(pact, gen_spec)
  i = raw.new_interaction(pact, 'a response with generators')
  raw.with_request(i, 'GET', '/path/one')
  raw.response_status(i, 200)
  register_part(i, CompatFfi::RESPONSE, @gen_response || CompatModel::Part.new([], nil, nil))
  raw.with_generators(i, CompatFfi::RESPONSE, @gen_response_generators) if @gen_response_generators
  port = raw.create_mock_server_for_transport(pact, '127.0.0.1', 0, 'http', nil)
  if port.negative?
    raw.free_pact_handle(pact)
    raise "create_mock_server_for_transport failed with #{port}"
  end
  begin
    res = http_request(port, 'GET', '/path/one', [], nil)
  ensure
    raw.cleanup_mock_server(port)
    raw.free_pact_handle(pact)
  end
  @generated_response = GeneratedPart.new(res.status, '', res.headers, res.body.to_s)
end

Then(/^the body value for "([^"]*)" will have been replaced with an? "([^"]*)"$/) do |path, kind|
  value = body_value(gen_generated_body, path)
  raise "#{path} was not replaced: #{value.to_json}" if value == gen_original_value(path)

  gen_assert_value_type(kind, value)
end

Then(/^the body value for "([^"]*)" will have been replaced with "([^"]*)"$/) do |path, expected|
  value = body_value(gen_generated_body, path)
  raise "#{path} was not replaced: #{value.to_json}" if value == gen_original_value(path)
  raise "expected #{path} to be #{expected.inspect}, got #{value.to_json}" unless json_to_string(value) == expected
end

Then('the request {string} will be set as {string}') do |name, expected|
  actual = gen_request_field(@generated_request || raise('the request was not prepared'), name)
  raise "expected request #{name} to be #{expected.inspect}, got #{actual.inspect}" unless actual == expected
end

Then('the request {string} will match {string}') do |name, pattern|
  actual = gen_request_field(@generated_request || raise('the request was not prepared'), name)
  raise "expected request #{name} to match #{pattern.inspect}, got #{actual.inspect}" \
    unless actual.match?(/\A(?:#{pattern})\z/)
end

Then('the response {string} will not be {string}') do |name, value|
  actual = gen_response_field(@generated_response || raise('the response was not prepared'), name)
  raise "expected response #{name} not to be #{value.inspect}" if actual == value
end

Then('the response {string} will match {string}') do |name, pattern|
  actual = gen_response_field(@generated_response || raise('the response was not prepared'), name)
  raise "expected response #{name} to match #{pattern.inspect}, got #{actual.inspect}" \
    unless actual.match?(/\A(?:#{pattern})\z/)
end
