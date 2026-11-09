# frozen_string_literal: true

require 'uri'
require 'rexml/document'

# The suite's interaction tables as plain data, and how they are registered through the FFI.
# Mirrors setup_common_interactions / setup_body in the pact-reference compatibility suite.
module CompatModel
  Part = Struct.new(:headers, :body, :matching_rules) do
    def initialize(headers = [], body = nil, matching_rules = nil) = super

    def header(name)
      headers.find { |k, _| k.casecmp?(name) }&.last
    end

    def set_header(name, value)
      headers.reject! { |k, _| k.casecmp?(name) }
      headers << [name, value]
    end

    def deep_dup = Part.new(headers.map(&:dup), body&.dup, matching_rules&.dup)
  end

  Interaction = Struct.new(:description, :method, :path, :query, :request, :status, :response) do
    def deep_dup = Interaction.new(description, method, path, query, request.deep_dup, status, response.deep_dup)
  end

  module_function

  def fixture_path(name) = File.join(FIXTURES_DIR, name)

  # Builds interactions from a Gherkin table (array of rows) whose first row names the columns.
  def setup_common_interactions(rows)
    cols = rows[0].each_with_index.to_h
    rows.drop(1).each_with_index.map do |values, row|
      get = ->(name) { cols[name] ? (values[cols[name]] || '') : '' }
      status = get.('response')
      interaction = Interaction.new("Interaction #{row}", get.('method'), get.('path'), get.('query'),
                                    Part.new, status.match?(/\A\d+\z/) ? status.to_i : 200, Part.new)
      interaction.request.headers = parse_headers(get.('headers'))
      setup_body(get.('body'), interaction.request)
      interaction.response.headers = parse_headers(get.('response headers'))
      setup_body(get.('response body'), interaction.response)
      interaction.request.matching_rules = matching_rules(get.('matching rules'))
      interaction.response.matching_rules = matching_rules(get.('response matching rules'))
      interaction
    end
  end

  # A matching rules cell: a fixture file name or inline `JSON: {...}`.
  def matching_rules(cell)
    return nil if cell.nil? || cell.empty?
    return cell.delete_prefix('JSON:').strip if cell.start_with?('JSON:')

    File.read(fixture_path(cell.strip))
  end

  # Parses `'Name: value', 'Other: value'` cells.
  def parse_headers(cell)
    return [] if cell.nil? || cell.empty?

    cell.split(',').filter_map do |h|
      h = h.strip.delete_prefix("'").delete_suffix("'")
      k, v = h.split(':', 2)
      [k.strip, v.strip] if v
    end
  end

  # Query string to ordered [name, value] pairs, percent-decoded.
  def parse_query(query)
    return [] if query.nil? || query.empty?

    URI.decode_www_form(query)
  end

  def query_map(pairs)
    pairs.each_with_object({}) { |(k, v), map| (map[k] ||= []) << v }
  end

  def setup_body(cell, part, content_type_override = nil)
    return if cell.nil? || cell.empty?

    content_type, body =
      if cell.start_with?('JSON:')
        ['application/json', cell.delete_prefix('JSON:').strip]
      elsif cell.start_with?('XML:')
        ['application/xml', cell.delete_prefix('XML:').strip]
      elsif cell.start_with?('file:')
        file = cell.delete_prefix('file:').strip
        if file.end_with?('-body.xml')
          body_fixture(file)
        else
          [determine_content_type(file, part), File.binread(fixture_path(file))]
        end
      else
        body = cell == 'EMPTY' ? '' : cell
        [determine_content_type(body, part), body]
      end
    part.set_header('content-type', content_type_override || content_type)
    part.body = body.b
  end

  def determine_content_type(body, part)
    if body.end_with?('.json') then 'application/json'
    elsif body.end_with?('.xml') then 'application/xml'
    elsif body.end_with?('.jpg') then 'image/jpeg'
    elsif body.end_with?('.pdf') then 'application/pdf'
    else part.header('content-type') || 'text/plain'
    end
  end

  # Reads a `*-body.xml` fixture: <body><contentType/><contents eol="CRLF"?/></body>.
  def body_fixture(file)
    doc = REXML::Document.new(File.read(fixture_path(file)))
    text = lambda do |name|
      el = doc.root.elements[name]
      next nil unless el

      s = el.texts.map { |t| t.value.strip }.join
      el.attributes['eol'] == 'CRLF' ? s.gsub("\r\n", "\n").gsub("\n", "\r\n") : s
    end
    [text.('contentType') || 'text/plain', text.('contents') || '']
  end

  def binary?(content_type, body)
    ct = content_type.downcase
    ct.start_with?('image/', 'application/pdf', 'application/octet-stream') ||
      !body.dup.force_encoding('UTF-8').valid_encoding?
  end

  def register_part(i, p, part)
    index = Hash.new(0)
    part.headers.each do |k, v|
      # The content type travels with the body; pactffi_with_body sets the header from it.
      next if part.body && k.casecmp?('content-type')

      key = k.downcase
      CompatFfi::Raw.with_header_v2(i, p, k, index[key], v)
      index[key] += 1
    end
    if part.body
      ct = part.header('content-type') || 'text/plain'
      if binary?(ct, part.body)
        CompatFfi.with_binary_body(i, p, ct, part.body)
      else
        CompatFfi::Raw.with_body(i, p, ct, part.body.dup.force_encoding('UTF-8'))
      end
    end
    CompatFfi::Raw.with_matching_rules(i, p, part.matching_rules) if part.matching_rules
  end

  # Adds one HTTP interaction to the pact with the calls a client library would make.
  def register(pact, interaction)
    i = CompatFfi::Raw.new_interaction(pact, interaction.description)
    CompatFfi::Raw.with_request(i, interaction.method, interaction.path)
    index = Hash.new(0)
    parse_query(interaction.query).each do |k, v|
      CompatFfi::Raw.with_query_parameter_v2(i, k, index[k], v)
      index[k] += 1
    end
    register_part(i, CompatFfi::REQUEST, interaction.request)
    CompatFfi::Raw.response_status(i, interaction.status)
    register_part(i, CompatFfi::RESPONSE, interaction.response)
    i
  end

  HTTP_SPEC = { 'v1' => 1, 'v2' => 3, 'v3' => 4, 'v4' => 5 }.freeze

  def http_spec(version) = HTTP_SPEC.fetch(version)
  def message_spec(version) = version == 'v4' ? 5 : 4
end

World(CompatModel)
