# frozen_string_literal: true

# Scenario state and helpers shared by the plugin step definitions.
module PluginWorld
  CONSUMER = 'c'
  PROVIDER = 'p'
  V4 = PactFfi::FfiSpecificationVersion['SPECIFICATION_VERSION_V4']

  def installed
    @installed ||= {}
  end

  def interactions
    @interactions ||= []
  end

  def current
    interactions.last
  end

  def body_cell(value)
    value.start_with?('file: ') ? File.binread(File.join(FIXTURES_DIR, value.delete_prefix('file: '))) : value
  end

  def plugin_contents(text)
    text.gsub('"fixture:', "\"#{FIXTURES_DIR}/")
  end

  def plugin_version(name)
    installed.fetch(name) { raise "plugin #{name} has not been declared as installed" }
  end

  def pact_file
    File.join(@tmp, "#{CONSUMER}-#{PROVIDER}.json")
  end

  def pact_json
    @pact_json ||= JSON.parse(File.read(pact_file))
  end

  def first_interaction
    pact_json['interactions'][0]
  end

  def part_of(interaction, part)
    value = part == 'contents' ? interaction : interaction[part]
    value.is_a?(Array) ? value[0] : value
  end

  def part_contents(part)
    part['contents'] || part['body']
  end

  def decoded_content(contents)
    contents['encoded'] == 'base64' ? Base64.decode64(contents['content']) : contents['content']
  end

  def contains_text?(value, text)
    case value
    when String then value.include?(text)
    when Array then value.any? { |v| contains_text?(v, text) }
    when Hash then value.any? { |k, v| contains_text?(k, text) || contains_text?(v, text) }
    else false
    end
  end

  def collect_values(value, key, acc = [])
    case value
    when Array then value.each { |v| collect_values(v, key, acc) }
    when Hash
      value.each do |k, v|
        acc << v if k == key && v.is_a?(String)
        collect_values(v, key, acc)
      end
    end
    acc
  end

  def check_ffi(ok, what)
    raise "#{what} failed: #{CompatFfi.last_error}" unless ok
  end

  def contents_ok!(rc, what)
    raise "#{what} failed (#{rc}): #{CompatFfi.last_error}" unless rc.zero?
  end

  # ---- FFI pact building -------------------------------------------------

  def ffi_new_pact
    handle = PactFfi.new_pact(CONSUMER, PROVIDER)
    PactFfi.with_specification(handle, V4)
    @cleanups << lambda {
      PactFfi::PluginConsumer.cleanup_plugins(handle)
      PactFfi.free_pact_handle(handle)
    }
    handle
  end

  def ffi_use_plugins(handle, names)
    names.uniq.each do |name|
      rc = PactFfi::PluginConsumer.using_plugin(handle, name, plugin_version(name))
      contents_ok!(rc, "using_plugin(#{name})")
    end
  end

  def ffi_add_interaction(handle, spec, index)
    desc = spec[:description] || "plugin interaction #{index + 1}"
    case spec[:kind]
    when :http
      i = PactFfi.new_interaction(handle, desc)
      check_ffi(PactFfi.with_request(i, spec[:method] || 'GET', spec[:path] || '/'), 'with_request')
      if (req = spec[:request_plugin])
        contents_ok!(PactFfi::PluginConsumer.interaction_contents(i, 0, req[:content_type], req[:contents]),
                     'request interaction_contents')
      end
      if (res = spec[:response_plugin])
        contents_ok!(PactFfi::PluginConsumer.interaction_contents(i, 1, res[:content_type], res[:contents]),
                     'response interaction_contents')
      elsif spec[:response_body]
        check_ffi(PactFfi.with_body(i, 1, spec[:response_content_type], spec[:response_body]), 'with_body')
      end
    when :message, :sync
      i = spec[:kind] == :message ? PactFfi.new_message_interaction(handle, desc) : PactFfi.new_sync_message_interaction(handle, desc)
      c = spec[:contents_plugin]
      contents_ok!(PactFfi::PluginConsumer.interaction_contents(i, 0, c[:content_type], c[:contents]),
                   'interaction_contents')
    end
    i
  end

  def ffi_build_pact
    handle = ffi_new_pact
    ffi_use_plugins(handle, interactions.flat_map { |s| s[:plugins] })
    interactions.each_with_index { |spec, idx| ffi_add_interaction(handle, spec, idx) }
    handle
  end

  # ---- consumer mock servers ---------------------------------------------

  # DSL: the builder's execute block spans several steps, so run it in a Fiber.
  def dsl_start(builder)
    @fiber = Fiber.new do
      builder.execute { |*args| Fiber.yield(args.last) }
      :done
    end
    @dsl_mock = @fiber.resume
    @mock_port = @dsl_mock.port
    @cleanups << -> { finish_dsl_mock }
  end

  def finish_dsl_mock
    return unless @fiber&.alive?

    @fiber.resume
  rescue Pact::Consumer::PluginHttpInteractionBuilder::InteractionMismatchesError,
         Pact::Consumer::PluginSyncMessageInteractionBuilder::InteractionMismatchesError => e
    @dsl_error = e
    # The DSL raises before cleaning up on mismatches, so release what it left behind.
    # MockServer#cleanup_plugins/#free_pact_handle pass the mock server port rather than
    # the pact handle, so use the pact handle directly.
    @dsl_mock.cleanup
    pact = @dsl_mock.instance_variable_get(:@pact)
    PactFfi::PluginConsumer.cleanup_plugins(pact)
    PactFfi.free_pact_handle(pact)
  end

  def ffi_start_mock(handle, transport)
    port = PactFfi::MockServer.create_for_transport(handle, '127.0.0.1', CompatServers.fresh_mock_port, transport, nil)
    raise "create_mock_server_for_transport failed (#{port}): #{CompatFfi.last_error}" unless port.positive?

    @ffi_mock = port
    @mock_port = port
    @cleanups << -> { PactFfi::MockServer.cleanup(port) }
  end

  def pact_test_done
    if @dsl_mock
      @matched = @dsl_mock.matched?
      @mismatches = @dsl_mock.mismatches
      finish_dsl_mock
    elsif @ffi_mock
      @matched = PactFfi::MockServer.matched(@ffi_mock)
      @mismatches = PactFfi::MockServer.mismatches(@ffi_mock)
      PactFfi::MockServer.write_pact_file(@ffi_mock, @tmp, false) if @matched
    else
      raise 'no mock server was started'
    end
  end

  # ---- provider verification ---------------------------------------------

  def write_provider_pact(kind, row, description: nil, method: nil, path: nil, transport: nil)
    dir = File.join(@tmp, 'pacts')
    FileUtils.mkdir_p(dir)
    handle = PactFfi.new_pact(CONSUMER, PROVIDER)
    PactFfi.with_specification(handle, V4)
    ffi_use_plugins(handle, [row['plugin']])
    spec = { kind: kind, description: description, method: method, path: path }
    ct = row['content type']
    if kind == :http
      spec[:request_plugin] = { content_type: ct, contents: plugin_contents(row['request']) } if row['request']
      spec[:response_plugin] = { content_type: ct, contents: plugin_contents(row['response']) } if row['response']
    else
      spec[:contents_plugin] = { content_type: ct, contents: plugin_contents(row['contents']) }
    end
    ffi_add_interaction(handle, spec, 0)
    contents_ok!(PactFfi.pact_handle_write_file(handle, dir, false), 'pact_handle_write_file')
    PactFfi::PluginConsumer.cleanup_plugins(handle)
    PactFfi.free_pact_handle(handle)
    file = File.join(dir, "#{CONSUMER}-#{PROVIDER}.json")
    if transport
      json = JSON.parse(File.read(file))
      json['interactions'][0]['transport'] = transport
      File.write(file, JSON.dump(json))
    end
    @provider_pact = file
  end

  def ffi_verify(port, transport = nil, transport_port = nil)
    handle = PactFfi::Verifier.new_for_application('pact-ruby-compat', PactFfi.version)
    PactFfi::Verifier.set_provider_info(handle, PROVIDER, 'http', '127.0.0.1', port, '/')
    if transport
      PactFfi::Verifier.add_provider_transport(handle, transport, transport_port, '/',
                                               transport == 'grpc' ? 'http' : 'tcp')
    end
    PactFfi::Verifier.add_file_source(handle, @provider_pact)
    rc = Pact::Native::BlockingVerifier.execute(handle)
    @verify_rc = rc
    @verify_output = PactFfi::Verifier.output(handle, 0).to_s.gsub(/\e\[[0-9;]*m/, '')
    json = PactFfi::Verifier.json(handle)
    @verify_results = json && !json.empty? ? JSON.parse(json) : {}
    @verified = rc.zero? && @verify_results['result'] == true
  ensure
    PactFfi::Verifier.shutdown(handle) if handle
  end
end

World(PluginWorld)
