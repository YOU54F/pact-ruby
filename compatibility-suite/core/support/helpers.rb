# frozen_string_literal: true

# State and lookups shared by the consumer, provider, message, matching and generator steps.
module CompatHelpers
  ORDINALS = { 'first' => 0, 'second' => 1, 'third' => 2 }.freeze

  def consumer_name = "#{@version}-compatibility-suite-c"
  def pact_file = File.join(@pact_dir, "#{consumer_name}-p.json")

  def load_pact_json
    raise "No pact file found: #{pact_file}" unless File.exist?(pact_file)

    @pact_json = JSON.parse(File.read(pact_file))
  end

  def pact_interaction(nth = 'first')
    list = @pact_json['interactions'] || @pact_json['messages'] || []
    list[ORDINALS.fetch(nth)] || raise("No #{nth} interaction in the pact file")
  end

  def interaction_n(n) = @interactions.fetch(n.to_i - 1).deep_dup

  # A pact header lookup; values may be a string or (V4) an array of strings.
  def pact_header(part, name)
    v = (part['headers'] || {}).find { |k, _| k.casecmp?(name) }&.last
    v.is_a?(Array) ? v.join(', ') : v
  end

  # A V1 pact stores the query as a string; later formats use a map of name to values.
  def pact_query(query)
    case query
    when String then query_map(parse_query(query))
    when Hash then query.transform_values { |v| Array(v).map(&:to_s) }
    else {}
    end
  end

  def compare_fixture_body(body, fixture)
    path = fixture_path(fixture)
    if fixture.end_with?('.json')
      expected = JSON.parse(File.read(path))
      raise "Expected body #{expected.to_json} but was #{body.to_json}" unless body == expected
    else
      expected = File.read(path)
      raise "Expected body #{expected.inspect} but was #{body.inspect}" unless body == expected
    end
  end

  # Cells in a provider state data table are JSON values.
  def json_params(rows) = rows[0].zip(rows[1]).to_h { |k, v| [k, JSON.parse(v)] }

  def new_pact(spec)
    pact = CompatFfi::Raw.new_pact(consumer_name, 'p')
    CompatFfi::Raw.with_specification(pact, spec)
    @cleanups << -> { CompatFfi::Raw.free_pact_handle(pact) }
    pact
  end

  def write_pact_from_handle(pact)
    rc = CompatFfi::Raw.pact_handle_write_file(pact, @pact_dir, true)
    raise "pactffi_pact_handle_write_file failed with #{rc}: #{CompatFfi.last_error}" unless rc.zero?

    load_pact_json
  end
end

World(CompatHelpers, CompatServers)
