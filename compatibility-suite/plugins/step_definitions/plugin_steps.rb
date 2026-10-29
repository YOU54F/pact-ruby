# frozen_string_literal: true

# ---- plugin installation / lifecycle ---------------------------------------

Given('the {string} plugin version {string} is installed') do |name, version|
  dir = File.join(PLUGIN_DIR, "#{name}-#{version}")
  raise "plugin #{name} #{version} is not installed in #{PLUGIN_DIR}" unless Dir.exist?(dir)

  installed[name] = version
end

Given('the {string} plugin is not installed') do |name|
  expect(Dir.glob(File.join(PLUGIN_DIR, "#{name}-*"))).to be_empty
end

When('the {string} plugin is loaded for the test') do |name|
  load_plugin(name, nil)
end

When('the {string} plugin version {string} is loaded for the test') do |name, version|
  load_plugin(name, version)
end

# The DSL can't express a version-less plugin and masks PluginInitError behind a
# NoMethodError in its ensure block, so plugin loading goes through the FFI.
def load_plugin(name, version)
  @path = :ffi
  handle = ffi_new_pact
  @load_rc = begin
    PactFfi::PluginConsumer.using_plugin(handle, name, version)
  rescue StandardError => e
    @load_panic = e
    -1
  end
  @load_error = "#{CompatFfi.last_error} (rc=#{@load_rc})"
end

Then('loading the plugin will fail with an error that mentions {string}') do |text|
  expect(@load_rc).not_to eq(0)
  expect(@load_error).to include(text)
end

Then('the test will not have panicked') do
  expect(@load_panic).to be_nil
  expect(@load_error.downcase).not_to include('panic')
end

When('the plugins are cleaned up') do
  PactFfi::PluginConsumer.cleanup_plugins(@pact_handle)
end

Then('no {string} plugin process will still be running') do |name|
  pattern = File.join(PLUGIN_DIR, "#{name}-")
  deadline = Time.now + 10
  running = true
  while Time.now < deadline
    # Only plugin processes started by this runner (its children) count.
    running = !`pgrep -P #{Process.pid} -f #{pattern.shellescape}`.strip.empty?
    break unless running

    sleep 0.2
  end
  expect(running).to be(false)
end

# ---- consumer: defining interactions ---------------------------------------

Given('an HTTP interaction is being defined for a consumer test') do
  interactions << { kind: :http, plugins: [] }
end

Given('another HTTP interaction is being defined for the same consumer test') do
  interactions << { kind: :http, plugins: [] }
end

Given('a message interaction is being defined for a consumer test') do
  interactions << { kind: :message, plugins: [] }
end

Given('a synchronous message interaction is being defined for a consumer test') do
  interactions << { kind: :sync, plugins: [] }
end

Given('the HTTP request is {string} {string}') do |method, path|
  current[:method] = method
  current[:path] = path
end

Given('the HTTP request body is set with the {string} plugin for {string} with:') do |plugin, ct, text|
  current[:plugins] << plugin
  current[:request_plugin] = { name: plugin, content_type: ct, contents: plugin_contents(text) }
end

Given('the HTTP response body is set with the {string} plugin for {string} with:') do |plugin, ct, text|
  current[:plugins] << plugin
  current[:response_plugin] = { name: plugin, content_type: ct, contents: plugin_contents(text) }
end

Given('the HTTP response body is {string} with content type {string}') do |body, ct|
  current[:response_body] = body_cell(body)
  current[:response_content_type] = ct
end

Given(/^the (?:synchronous )?message contents are set with the "([^"]*)" plugin for "([^"]*)" with:$/) do |plugin, ct, text|
  current[:plugins] << plugin
  current[:contents_plugin] = { name: plugin, content_type: ct, contents: plugin_contents(text) }
end

# ---- consumer: generating the pact -----------------------------------------

When('the Pact file for the test is generated') do
  spec = current
  if interactions.size == 1 && spec[:kind] == :message
    # DSL: MessageInteractionBuilder#with_plugin / #with_plugin_contents
    @path = :dsl
    c = spec[:contents_plugin]
    config = Pact::Consumer::PactConfig.new(:message, consumer_name: PluginWorld::CONSUMER,
                                                      provider_name: PluginWorld::PROVIDER, opts: { pact_dir: @tmp })
    config.new_interaction('plugin message')
          .with_plugin(c[:name], plugin_version(c[:name]))
          .with_plugin_contents(c[:content_type], JSON.parse(c[:contents]))
          .execute { |_payload, _meta| nil }
  else
    # FFI: the HTTP / sync DSL builders always start a mock server and can't just write a pact.
    @path = :ffi
    @pact_handle = ffi_build_pact
    contents_ok!(PactFfi.pact_handle_write_file(@pact_handle, @tmp, false), 'pact_handle_write_file')
  end
end

When('the mock server is started with the plugin interaction') do
  spec = current
  req = spec[:request_plugin]
  res = spec[:response_plugin]
  if req && res
    # DSL: PluginHttpInteractionBuilder (needs plugin bodies on both request and response).
    @path = :dsl
    config = Pact::Consumer::PactConfig.new(:plugin_http, consumer_name: PluginWorld::CONSUMER,
                                                          provider_name: PluginWorld::PROVIDER, opts: { pact_dir: @tmp, mock_port: CompatServers.fresh_mock_port })
    builder = config.new_interaction('plugin interaction 1')
                    .with_plugin(req[:name], plugin_version(req[:name]))
                    .with_request(method: spec[:method], path: spec[:path],
                                  headers: { 'content-type' => req[:content_type] }, body: req[:contents])
                    .will_respond_with(status: 200, headers: { 'content-type' => res[:content_type] },
                                       body: res[:contents])
    dsl_start(builder)
  else
    # FFI: the DSL can't build a response-only plugin body.
    @path = :ffi
    ffi_start_mock(ffi_build_pact, 'http')
  end
end

When('the mock server is started with all the interactions') do
  # FFI: the DSL builders hold a single interaction per pact handle.
  @path = :ffi
  ffi_start_mock(ffi_build_pact, 'http')
end

When('a mock server is started for the {string} transport') do |transport|
  # DSL: PluginSyncMessageInteractionBuilder#with_transport
  @path = :dsl
  c = current[:contents_plugin]
  contents = JSON.parse(c[:contents])
  request = contents.delete('request')
  response = contents.delete('response')
  config = Pact::Consumer::PactConfig.new(:plugin_sync_message, consumer_name: PluginWorld::CONSUMER,
                                                                provider_name: PluginWorld::PROVIDER,
                                                                opts: { pact_dir: @tmp, mock_port: CompatServers.fresh_mock_port })
  builder = config.new_interaction('plugin interaction 1')
                  .with_plugin(c[:name], plugin_version(c[:name]))
                  .with_content_type(c[:content_type])
                  .with_request(request)
                  .will_respond_with(response)
                  .with_transport(transport)
  builder.with_plugin_metadata(contents) unless contents.empty?
  dsl_start(builder)
end

When(/^a "([^"]*)" request is made to "([^"]*)"(?: with content type "([^"]*)" and body "([^"]*)")?$/) do |method, path, ct, body|
  @response = CompatServers.http_request(@mock_port, method, path, ct, body && body_cell(body))
end

Then('a 200 success response is returned') do
  expect(@response.code).to eq('200')
end

Then('the response body will be {string}') do |expected|
  want = body_cell(expected)
  got = @response.body.to_s
  if got.b == want.b
    expect(got.b).to eq(want.b)
  else
    expect(JSON.parse(got)).to eq(JSON.parse(want))
  end
end

When('the line {string} is sent to the mock server over TCP') do |line|
  @tcp_reply = CompatServers.tcp_line(@mock_port, line)
end

Then('the line {string} will be received from the mock server') do |line|
  expect(@tcp_reply).to eq(line)
end

When('the gRPC method {string} is called on the mock server with {string}') do |method, body|
  @grpc_result = CompatServers.grpc_call(@mock_port, method, body_cell(body))
end

When('the gRPC method {string} is called on the mock server with an empty message') do |method|
  @grpc_result = CompatServers.grpc_call(@mock_port, method, '')
end

Then('the gRPC call will return {string}') do |expected|
  status, reply = @grpc_result
  expect(status).to eq(:ok), "gRPC call failed: #{reply.inspect}"
  expect(reply.b).to eq(body_cell(expected).b)
end

Then('the gRPC call will fail with status {string}') do |code|
  status, error = @grpc_result
  expect(status).to eq(:error)
  expect(GRPC::Core::StatusCodes.constants.find { |c| GRPC::Core::StatusCodes.const_get(c) == error.code }.to_s)
    .to eq(code)
end

When('the pact test is done') do
  pact_test_done
end

Then('the mock server status will be OK') do
  expect(@matched).to be(true), "mismatches: #{@mismatches}"
end

Then('the mock server status will be mismatches') do
  expect(@matched).to be(false)
end

Then('the mismatches will contain a mismatch with error {string}') do |error|
  parsed = begin
    JSON.parse(@mismatches.to_s)
  rescue JSON::ParserError
    @mismatches.to_s
  end
  expect(contains_text?(parsed, error)).to be(true), "#{error.inspect} not found in #{@mismatches}"
end

Then('the mock server will write out a Pact file for the interaction when done') do
  expect(File.exist?(pact_file)).to be(true), "no pact written (matched=#{@matched}, reply=#{@tcp_reply.inspect}, mismatches=#{@mismatches})"
end

# ---- consumer: pact file checks --------------------------------------------

Then(/^the Pact file metadata will list the "([^"]*)" plugin with version "([^"]*)"$/) do |name, version|
  plugins = pact_json.dig('metadata', 'plugins') || []
  expect(plugins.any? { |p| p['name'] == name && p['version'] == version }).to be(true), plugins.inspect
end

Then('the first interaction in the Pact file will have a type of {string}') do |type|
  expect(first_interaction['type']).to eq(type)
end

Then(/^the first interaction in the pact file (request |response |contents |)content type will be "([^"]*)"$/) do |part, ct|
  part = part.strip.empty? ? 'contents' : part.strip
  expect(part_contents(part_of(first_interaction, part))['contentType']).to eq(ct)
end

Then(/^the first interaction in the pact file (request |response |contents |)contents will be "([^"]*)"$/) do |part, text|
  part = part.strip.empty? ? 'contents' : part.strip
  expect(decoded_content(part_contents(part_of(first_interaction, part)))).to eq(text)
end

Then(/^the first interaction (request|response|contents) in the pact file will have a matching rule for "([^"]*)" of type "([^"]*)"$/) do |part, key, type|
  rules = part_of(first_interaction, part).dig('matchingRules', 'body', key, 'matchers') || []
  expect(rules.map { |m| m['match'] }).to include(type)
end

Then('the first interaction in the pact file will have plugin configuration for {string}') do |name|
  expect(first_interaction['pluginConfiguration'] || {}).to have_key(name)
end

Then('the second interaction in the pact file will not have plugin configuration') do
  expect(pact_json['interactions'][1]['pluginConfiguration'] || {}).to be_empty
end

Then('the pact file will contain {int} interactions') do |count|
  expect(pact_json['interactions'].size).to eq(count)
end

Then('the first interaction in the pact file will contain {int} response message') do |count|
  expect(first_interaction['response'].size).to eq(count)
end

Then(/^the first interaction in the Pact file will have "([^"]*)" = '(.*)'$/) do |key, json|
  value = first_interaction[key]
  value = value.split('/').last if key == 'transport' && value.is_a?(String)
  expect(value).to eq(JSON.parse(json))
end

# ---- provider verification -------------------------------------------------

Given('a Pact file with an HTTP {string} {string} interaction with plugin contents:') do |method, path, table|
  write_provider_pact(:http, table.hashes.first, method: method, path: path)
  @provider_kind = :http
end

Given('a Pact file with a {string} message interaction with plugin contents:') do |name, table|
  write_provider_pact(:message, table.hashes.first, description: name)
  @provider_kind = :message
end

Given('a Pact file with a {string} synchronous message interaction with plugin contents:') do |name, table|
  write_provider_pact(:sync, table.hashes.first, description: name)
  @provider_kind = :message
end

Given('a Pact file with a {string} synchronous message interaction over the {string} transport with plugin contents:') do |name, transport, table|
  write_provider_pact(:sync, table.hashes.first, description: name, transport: transport)
  @provider_kind = :transport
end

Given('a provider is started that returns {string} with content type {string}') do |body, ct|
  @provider_body = body_cell(body)
  @provider_ct = ct
end

Given('a provider is started that can generate the {string} message with {string} and content type {string}') do |name, body, ct|
  server, @provider_port = CompatServers.message_provider(name, body_cell(body), ct)
  @cleanups << -> { server.shutdown }
end

Given('a TCP provider is started that replies to {string} with {string}') do |expected, reply|
  server, thread, @provider_port = CompatServers.tcp_provider(expected, reply)
  @cleanups << lambda {
    server.close
    thread.kill
  }
end

Given('a gRPC provider is started that answers {string} with {string}') do |method, body|
  server, @provider_port = CompatServers.grpc_provider(method, body_cell(body))
  @cleanups << -> { server.stop }
end

Given('no provider is listening') do
  @provider_port = CompatServers.free_port
end

When('the verification is run') do
  if @provider_kind == :http
    run_http_verification
  else
    @path = :ffi # the message verifier DSL only serves JSON from Ruby handlers and hides output
    ffi_verify(@provider_port)
  end
end

# DSL: HttpVerifier with a Rack app. It only reports pass/fail (no output or JSON
# results), so a failing run is repeated through the FFI verifier for diagnostics.
def run_http_verification
  config = Pact::Provider::PactConfig.new(
    :http, provider_name: PluginWorld::PROVIDER,
           opts: { http_port: CompatServers.free_port, provider_setup_port: CompatServers.free_port,
                   app: CompatServers.rack_provider(@provider_body, @provider_ct), pact_uri: @provider_pact,
                   consumer_name: PluginWorld::CONSUMER, log_level: :error }
  )
  config.new_verifier.verify!
  @path = :dsl
  @verified = true
rescue Pact::Provider::BaseVerifier::VerificationError
  @path = :ffi
  server, port = CompatServers.http_provider(@provider_body, @provider_ct)
  @cleanups << -> { server.shutdown }
  ffi_verify(port)
end

When('the verification is run with the {string} transport') do |transport|
  # FFI: the provider DSL has no generic plugin-transport verifier.
  @path = :ffi
  ffi_verify(@provider_port, transport, @provider_port)
end

Then('the verification will be successful') do
  expect(@verified).to be(true), "verification failed:\n#{@verify_output}"
end

Then('the verification will NOT be successful') do
  expect(@verified).to be(false)
end

Then('the verification results will contain a {string} error') do |error|
  types = { 'Body had differences' => %w[BodyMismatch BodyTypeMismatch],
            'Metadata had differences' => %w[MetadataMismatch] }.fetch(error)
  found = collect_values(@verify_results, 'type')
  expect(found & types).not_to be_empty, "mismatch types #{found.uniq.inspect}"
end

Then('the verification output will contain {string}') do |text|
  expect(@verify_output).to include(text)
end
