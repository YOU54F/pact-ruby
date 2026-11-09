# frozen_string_literal: true

# V3/V4 message consumer, V4 synchronous message consumer and V4 general features.
# A port of the pact-reference FFI runner's message.rs. Provider state, key, pending,
# comment, "the Pact file for the test is generated" and the interaction attribute steps
# are shared with the HTTP consumer steps.

def ffi_message_part(which) = which.to_s.strip == 'response' ? CompatFfi::RESPONSE : CompatFfi::REQUEST

def defined_interaction = @interaction || raise('no message is being defined')

# Metadata values come back from the FFI as text: strings bare, everything else as JSON.
def contents_metadata(contents, key)
  pair = contents.metadata.find { |k, _| k == key } or raise "no metadata #{key} in #{contents.metadata.inspect}"
  JSON.parse(pair[1])
rescue JSON::ParserError
  pair[1]
end

# `JSON: {...}` is a JSON value (the feature escapes its quotes); anything else is a string.
def expected_value(s)
  s.start_with?('JSON:') ? JSON.parse(s.delete_prefix('JSON:').strip.gsub('\\"', '"')) : s
end

def json_to_string(v) = v.is_a?(String) ? v : JSON.generate(v)

def body_value(body, path)
  keys = path.delete_prefix('$').split('.').reject(&:empty?)
  keys.reduce(body) do |v, k|
    raise "#{path} is not in the body #{body.to_json}" unless v.is_a?(Hash) && v.key?(k)

    v[k]
  end
end

VALUE_TYPES = { 'integer' => /\A-?\d+\z/, 'decimal number' => /\A-?\d+\.\d+\z/, 'boolean' => /\A(true|false)\z/ }.freeze

def assert_value_type(kind, v)
  pattern = VALUE_TYPES.fetch(kind) { raise "unknown value type #{kind}" }
  raise "expected a(n) #{kind}, got #{v.to_json}" unless json_to_string(v).match?(pattern)
end

# Sets a message body the way a client would; returns the body as a JSON value when it is one.
def add_message_body(i, p, cell)
  part = CompatModel::Part.new
  setup_body(cell, part)
  body = part.body || ''.b
  ct = part.header('content-type') || 'text/plain'
  ok = if binary?(ct, body)
         CompatFfi.with_binary_body(i, p, ct, body)
       else
         CompatFfi::Raw.with_body(i, p, ct, body.dup.force_encoding('UTF-8'))
       end
  raise "pactffi_with_body failed: #{CompatFfi.last_error}" unless ok

  JSON.parse(body)
rescue JSON::ParserError
  nil
end

def add_message_metadata_value(which, key, value)
  ok = CompatFfi::Raw.with_metadata(defined_interaction, key, JSON.generate(value), ffi_message_part(which))
  raise "pactffi_with_metadata failed for #{key}" unless ok

  (which == 'response' ? @response_metadata : @request_metadata)[key] = value
end

def document_value(cell)
  cell = "file: #{cell}" unless cell.include?(':')
  part = CompatModel::Part.new
  setup_body(cell, part)
  body = (part.body || '').dup.force_encoding('UTF-8')
  JSON.parse(body)
rescue JSON::ParserError
  body
end

def compare_document(actual, cell)
  expected = document_value(cell)
  if actual.is_a?(String) && !expected.is_a?(String)
    actual = begin
      JSON.parse(actual)
    rescue JSON::ParserError
      actual
    end
  end
  raise "Expected document #{expected.to_json} but was #{actual.to_json}" unless actual == expected
end

def contents_body_value(contents)
  s = contents.body_str || ''
  JSON.parse(s)
rescue JSON::ParserError
  s
end

def received(which)
  if @sync
    request, responses = @received_sync.first || raise('no synchronous message was received')
    which == 'request' ? request : (responses.first || raise('the message has no response'))
  else
    @received.first || raise('no message was received')
  end
end

def first_message
  (@pact_json['messages'] || @pact_json['interactions'] || []).first || raise('no messages in the pact file')
end

def first_pact_interaction
  (@pact_json['interactions'] || []).first || raise('no interactions in the pact file')
end

# A V4 message part's `contents` is `{content, contentType, encoded}`.
def v4_content(contents)
  content = contents['content']
  return content unless contents['encoded'].to_s.casecmp?('base64') && content.is_a?(String)

  Base64.decode64(content).force_encoding('UTF-8')
end

def start_message(sync)
  @pact ||= new_pact(message_spec(@version))
  @sync = sync
  @received = []
  @received_sync = []
  @request_metadata = {}
  @response_metadata = {}
  @interaction = if sync
                   CompatFfi::Raw.new_sync_message_interaction(@pact, 'a synchronous message')
                 else
                   CompatFfi::Raw.new_message_interaction(@pact, 'a message')
                 end
end

# ---- Defining the interaction ----

Given(/^a message (?:integration|interaction) is being defined for a consumer test$/) do
  start_message(false)
end

Given('a synchronous message interaction is being defined for a consumer test') do
  start_message(true)
end

Given('a message is defined') do
  defined_interaction
end

Given(/^the message (request |)payload contains the "([^"]+)" JSON document$/) do |_request, name|
  @request_body = add_message_body(defined_interaction, CompatFfi::REQUEST, "file: #{name}.json")
end

Given(/^the message response payload contains the "([^"]+)" document$/) do |cell|
  @response_body = add_message_body(defined_interaction, CompatFfi::RESPONSE, cell)
end

Given(/^the message (request |)contains the following metadata:$/) do |_request, table|
  table.raw.drop(1).each { |key, value| add_message_metadata_value('request', key, expected_value(value)) }
end

# `| body | generators | metadata |`, any of them. Generators are inline `JSON:` or a fixture file.
Given(/^the message (request |response |)is configured with the following:$/) do |which, table|
  which = which.strip
  i = defined_interaction
  p = ffi_message_part(which)
  cells = table.raw[0].zip(table.raw[1]).to_h
  if cells['body']
    value = add_message_body(i, p, cells['body'])
    which == 'response' ? @response_body = value : @request_body = value
  elsif @sync && which == 'response'
    # Sync response metadata and generators only apply to responses that exist; only a body adds one.
    raise 'pactffi_with_body failed' unless CompatFfi::Raw.with_body(i, p, 'text/plain', '')
  end
  JSON.parse(cells['metadata']).each { |k, v| add_message_metadata_value(which, k, v) } if cells['metadata']
  if (generators = cells['generators'])
    json = if generators.start_with?('JSON:')
             generators.delete_prefix('JSON:').strip
           else
             File.read(fixture_path(generators))
           end
    raise "pactffi_with_generators failed: #{CompatFfi.last_error}" unless CompatFfi::Raw.with_generators(i, p, json)
  end
end

# ---- Processing ----

When('the message is successfully processed') do
  raise 'no pact is being defined' unless @pact

  if @sync
    @received_sync = CompatFfi.sync_messages(@pact)
  else
    @received = CompatFfi.async_messages(@pact)
  end
  write_pact_from_handle(@pact)
end

When('the message is NOT successfully processed with a {string} exception') do |error|
  raise 'no pact is being defined' unless @pact

  @received = CompatFfi.async_messages(@pact)
  @failed = error
end

Then('the consumer test will have passed') do
  raise "the consumer test failed with #{@failed}" if @failed
end

Then('the consumer test will have failed') do
  raise 'the consumer test passed' unless @failed
end

Then('the consumer test error will be {string}') do |error|
  raise "Expected error #{error.inspect} but was #{@failed.inspect}" unless @failed == error
end

# ---- What the consumer received ----

Then(/^the received message payload will contain the "([^"]+)" (?:JSON )?document$/) do |cell|
  cell = "#{cell}.json" unless cell.include?(':')
  compare_document(contents_body_value(received('')), cell)
end

Then('the received message content type will be {string}') do |expected|
  actual = contents_metadata(received(''), 'contentType')
  raise "Expected content type #{expected} but was #{actual.inspect}" unless actual == expected
end

Then(/^the received message (request |response |)metadata will contain "([^"]+)" == "(.*)"$/) do |which, key, value|
  actual = contents_metadata(received(which.strip), key)
  expected = expected_value(value)
  raise "Expected metadata #{key} = #{expected.to_json} but was #{actual.to_json}" unless actual == expected
end

Then(/^the received message (request |response |)metadata will contain "([^"]+)" replaced with an? "([^"]+)"$/) do |which, key, kind|
  which = which.strip
  actual = contents_metadata(received(which), key)
  originals = which == 'response' ? @response_metadata : @request_metadata
  raise "metadata #{key} was not replaced: #{actual.to_json}" if originals.key?(key) && originals[key] == actual

  assert_value_type(kind, actual)
end

Then(/^the message (request |response |)contents for "([^"]+)" will have been replaced with an? "([^"]+)"$/) do |which, path, kind|
  which = which.strip
  value = body_value(contents_body_value(received(which)), path)
  original = which == 'response' ? @response_body : @request_body
  original_value = begin
    original && body_value(original, path)
  rescue StandardError
    nil
  end
  raise "#{path} was not replaced: #{value.to_json}" if !original_value.nil? && original_value == value

  assert_value_type(kind, value)
end

# ---- The pact file ----

Then(/^a Pact file for the message interaction will (NOT )?have been written$/) do |negated|
  exists = File.exist?(pact_file)
  raise "#{pact_file} was not written" if !negated && !exists
  raise "#{pact_file} was written" if negated && exists
end

Then(/^the pact file will contain (\d+) (message )?interactions?$/) do |n, message|
  key = message.nil? || @version == 'v4' ? 'interactions' : 'messages'
  actual = (@pact_json[key] || []).size
  raise "Expected #{n} #{key} but found #{actual}" unless actual == n.to_i
end

Then('the first message in the pact file will contain the {string} document') do |fixture|
  compare_document(first_message['contents'], fixture)
end

Then('the first message in the pact file content type will be {string}') do |expected|
  actual = (first_message['metadata'] || {})['contentType']
  raise "Expected content type #{expected} but was #{actual.inspect}" unless actual == expected
end

Then(/^the first message in the pact file will contain the (request |)message metadata "([^"]+)" == "(.*)"$/) do |request, key, value|
  message = first_message
  metadata = (request.to_s.empty? ? message['metadata'] : message.dig('request', 'metadata')) || {}
  expected = expected_value(value)
  raise "Expected metadata #{key} = #{expected.to_json} but was #{metadata[key].to_json}" unless metadata[key] == expected
end

Then(/^the first interaction in the pact file will contain the "([^"]+)" document as (the request|a response|the first response message|the second response message)$/) do |cell, which|
  i = first_pact_interaction
  contents = case which
             when 'the request' then i.dig('request', 'contents')
             when 'the second response message' then i.dig('response', 1, 'contents')
             else i.dig('response', 0, 'contents')
             end
  raise "No #{which} contents in #{i.to_json}" unless contents

  compare_document(v4_content(contents), cell)
end

Then(/^the first interaction in the pact file (request|response) content type will be "([^"]+)"$/) do |which, expected|
  i = first_pact_interaction
  part = which == 'request' ? i['request'] : i.dig('response', 0)
  actual = part&.dig('contents', 'contentType')
  raise "Expected #{which} content type #{expected} but was #{actual.inspect} in #{part.to_json}" unless actual == expected
end

Then(/^the first interaction in the pact file will contain (\d+) response messages?$/) do |n|
  actual = (first_pact_interaction['response'] || []).size
  raise "Expected #{n} response messages but found #{actual}" unless actual == n.to_i
end

Then('there will be an interaction in the Pact file with a type of {string}') do |expected|
  interactions = @pact_json['interactions'] || []
  raise "No interaction of type '#{expected}' in #{interactions.to_json}" unless interactions.any? { |i| i['type'] == expected }
end
