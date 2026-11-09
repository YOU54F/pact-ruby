# frozen_string_literal: true

# Pact compatibility suite runner for the core (non-plugin) V1-V4 features.
#
# Run with compatibility-suite/run-core.sh (needs PACT_COMPAT_SUITE).
# The steps drive libpact_ffi (loaded the same way pact-ruby loads it) through
# the calls a client library makes, mirroring the pact-reference FFI runner.

require 'json'
require 'base64'
require 'fileutils'
require 'tmpdir'
require 'socket'
require 'timeout'
require 'rspec/expectations'
require 'pact'
require 'pact/ffi'

SUITE_DIR = ENV.fetch('PACT_COMPAT_SUITE', '')
FIXTURES_DIR = File.join(SUITE_DIR, 'fixtures')

# libpact_ffi functions with pointer-friendly signatures.
module CompatFfi
  REQUEST = 0
  RESPONSE = 1
  GENERATOR_BODY = 4

  class MetadataPair < FFI::Struct
    layout :key, :pointer, :value, :pointer
  end

  class GeneratorPair < FFI::Struct
    layout :path, :pointer, :generator, :pointer
  end

  module Raw
    extend FFI::Library
    ffi_lib DetectOS.get_bin_path

    {
      get_error_message: [%i[pointer int32], :int32],
      new_pact: [%i[string string], :uint16],
      with_specification: [%i[uint16 int], :bool],
      new_interaction: [%i[uint16 string], :uint32],
      new_message_interaction: [%i[uint16 string], :uint32],
      new_sync_message_interaction: [%i[uint16 string], :uint32],
      with_request: [%i[uint32 string string], :bool],
      with_query_parameter_v2: [%i[uint32 string size_t string], :bool],
      with_header_v2: [%i[uint32 int string size_t string], :bool],
      with_matching_rules: [%i[uint32 int string], :bool],
      with_generators: [%i[uint32 int string], :bool],
      response_status: [%i[uint32 uint16], :bool],
      with_body: [%i[uint32 int string string], :bool],
      with_binary_body: [%i[uint32 int string pointer size_t], :bool],
      with_metadata: [%i[uint32 string string int], :bool],
      create_mock_server_for_transport: [%i[uint16 string uint16 string pointer], :int32],
      mock_server_matched: [%i[int32], :bool],
      mock_server_mismatches: [%i[int32], :string],
      write_pact_file: [%i[int32 string bool], :int32],
      cleanup_mock_server: [%i[int32], :bool],
      free_pact_handle: [%i[uint16], :uint32],
      given: [%i[uint32 string], :bool],
      given_with_params: [%i[uint32 string string], :int32],
      pact_handle_write_file: [%i[uint16 string bool], :int32],
      set_pending: [%i[uint32 bool], :bool],
      set_key: [%i[uint32 string], :bool],
      set_comment: [%i[uint32 string string], :bool],
      add_text_comment: [%i[uint32 string], :bool],
      string_delete: [%i[pointer], :void],
      verifier_new_for_application: [%i[string string], :pointer],
      verifier_set_provider_info: [%i[pointer string string string uint16 string], :void],
      verifier_set_provider_state: [%i[pointer string uint8 uint8], :void],
      verifier_set_publish_options: [%i[pointer string pointer pointer int pointer], :int32],
      verifier_add_custom_header: [%i[pointer string string], :void],
      verifier_add_file_source: [%i[pointer string], :void],
      verifier_broker_source_with_selectors: [
        %i[pointer string pointer pointer pointer uint8 pointer pointer uint16 pointer pointer uint16 pointer uint16],
        :int32
      ],
      verifier_execute: [%i[pointer], :int32],
      verifier_json: [%i[pointer], :pointer],
      verifier_output: [%i[pointer uint8], :pointer],
      verifier_shutdown: [%i[pointer], :void],
      message_contents_get_contents_length: [%i[pointer], :size_t],
      message_contents_get_contents_bin: [%i[pointer], :pointer],
      message_contents_get_metadata_iter: [%i[pointer], :pointer],
      message_metadata_iter_next: [%i[pointer], :pointer],
      message_metadata_pair_delete: [%i[pointer], :void],
      message_metadata_iter_delete: [%i[pointer], :void],
      message_contents_delete: [%i[pointer], :void],
      message_contents_get_generators_iter: [%i[pointer int], :pointer],
      generators_iter_next: [%i[pointer], :pointer],
      generators_iter_pair_delete: [%i[pointer], :void],
      generators_iter_delete: [%i[pointer], :void],
      generator_generate_string: [%i[pointer string], :pointer],
      pact_handle_get_async_message_iter: [%i[uint16], :pointer],
      pact_async_message_iter_next: [%i[pointer], :pointer],
      pact_async_message_iter_delete: [%i[pointer], :void],
      async_message_generate_contents: [%i[pointer], :pointer],
      async_message_get_contents: [%i[pointer], :pointer],
      pact_handle_get_sync_message_iter: [%i[uint16], :pointer],
      pact_sync_message_iter_next: [%i[pointer], :pointer],
      pact_sync_message_iter_delete: [%i[pointer], :void],
      sync_message_generate_request_contents: [%i[pointer], :pointer],
      sync_message_get_number_responses: [%i[pointer], :size_t],
      sync_message_generate_response_contents: [%i[pointer size_t], :pointer]
    }.each do |name, (args, ret)|
      # The verifier calls back into servers running on Ruby threads, so it must release the GVL.
      attach_function name, :"pactffi_#{name}", args, ret, blocking: name == :verifier_execute
    end
  end

  # Message contents read back from the FFI: body bytes and metadata pairs.
  Contents = Struct.new(:body, :metadata) do
    def body_str = body&.dup&.force_encoding('UTF-8')
  end

  module_function

  def last_error
    buf = FFI::MemoryPointer.new(:char, 4096)
    len = Raw.get_error_message(buf, 4096)
    len.positive? ? buf.read_string : ''
  end

  def take_string(ptr)
    return nil if ptr.null?

    s = ptr.read_string.force_encoding('UTF-8')
    Raw.string_delete(ptr)
    s
  end

  def with_binary_body(i, part, content_type, bytes)
    buf = FFI::MemoryPointer.new(:uint8, [bytes.bytesize, 1].max)
    buf.put_bytes(0, bytes)
    Raw.with_binary_body(i, part, content_type, buf, bytes.bytesize)
  end

  def read_contents(contents)
    out = Contents.new(nil, [])
    return out if contents.null?

    len = Raw.message_contents_get_contents_length(contents)
    if len.positive?
      p = Raw.message_contents_get_contents_bin(contents)
      out.body = p.read_bytes(len) unless p.null?
    end
    iter = Raw.message_contents_get_metadata_iter(contents)
    unless iter.null?
      loop do
        pair = Raw.message_metadata_iter_next(iter)
        break if pair.null?

        s = MetadataPair.new(pair)
        out.metadata << [s[:key].read_string.force_encoding('UTF-8'), s[:value].read_string.force_encoding('UTF-8')]
        Raw.message_metadata_pair_delete(pair)
      end
      Raw.message_metadata_iter_delete(iter)
    end
    Raw.message_contents_delete(contents)
    out
  end

  def async_messages(pact)
    iter = Raw.pact_handle_get_async_message_iter(pact)
    return [] if iter.null?

    out = []
    loop do
      m = Raw.pact_async_message_iter_next(iter)
      break if m.null?

      out << read_contents(Raw.async_message_generate_contents(m))
    end
    Raw.pact_async_message_iter_delete(iter)
    out
  end

  def sync_messages(pact)
    iter = Raw.pact_handle_get_sync_message_iter(pact)
    return [] if iter.null?

    out = []
    loop do
      m = Raw.pact_sync_message_iter_next(iter)
      break if m.null?

      request = read_contents(Raw.sync_message_generate_request_contents(m))
      n = Raw.sync_message_get_number_responses(m)
      responses = (0...n).map { |idx| read_contents(Raw.sync_message_generate_response_contents(m, idx)) }
      out << [request, responses]
    end
    Raw.pact_sync_message_iter_delete(iter)
    out
  end

  # Generates each body generator of the first async message with a context.
  def async_body_generators_with_context(pact, context)
    iter = Raw.pact_handle_get_async_message_iter(pact)
    return [] if iter.null?

    out = []
    m = Raw.pact_async_message_iter_next(iter)
    unless m.null?
      contents = Raw.async_message_get_contents(m)
      gens = Raw.message_contents_get_generators_iter(contents, GENERATOR_BODY)
      unless gens.null?
        loop do
          pair = Raw.generators_iter_next(gens)
          break if pair.null?

          s = GeneratorPair.new(pair)
          path = s[:path].read_string
          value = take_string(Raw.generator_generate_string(s[:generator], context))
          Raw.generators_iter_pair_delete(pair)
          out << [path, value]
        end
        Raw.generators_iter_delete(gens)
      end
    end
    Raw.pact_async_message_iter_delete(iter)
    out
  end
end

# Scenarios that fail because of a pact_ffi limitation, not this runner. Each is skipped with the
# reason so it shows in the run instead of failing it; remove an entry once pact_ffi fixes it.
KNOWN_FAILURES = {
  "Supports a not empty matcher with binary data (negative case)" =>
    "pact_ffi mock server reads a 0-byte request body as no body, so the notEmpty rule never sees it"
}.freeze

Before do |scenario|
  skip_this_scenario('PACT_COMPAT_SUITE is not set or has no features') if SUITE_DIR.empty? || !Dir.exist?(FIXTURES_DIR)
  @version = File.basename(File.dirname(scenario.location.file)).downcase
  @tmp = Dir.mktmpdir('pact-compat-')
  @pact_dir = File.join(@tmp, 'pacts')
  FileUtils.mkdir_p(@pact_dir)
  @cleanups = []
  reason = KNOWN_FAILURES[scenario.name]
  skip_this_scenario("known pact_ffi failure: #{reason}") if reason
end

After do
  @cleanups&.reverse_each do |c|
    c.call
  rescue StandardError
    nil
  end
  FileUtils.rm_rf(@tmp) if @tmp
end
