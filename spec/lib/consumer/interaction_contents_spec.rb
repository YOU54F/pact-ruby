# frozen_string_literal: true

RSpec.describe Pact::Consumer::InteractionContents do
  include Pact::Matchers

  let(:contents) do
    {
      str: match_any_string('str'),
      bool: match_any_boolean(true),
      num: match_any_number(1),
      nested: match_each(
        {
          a: 1,
          b: '2'
        }
      )
    }
  end

  context 'with plugin interaction' do
    it 'serializes properly to json' do
      expect(described_class.plugin(contents).to_json)
        .to eq("{\"str\":\"matching(regex, '(?-mix:.*)', 'str')\",\"bool\":\"matching(boolean, true)\",\"num\":\"matching(number, 1)\",\"nested\":{\"pact:match\":\"eachValue(matching($'SAMPLE'))\",\"SAMPLE\":{\"a\":1,\"b\":\"2\"}}}") # rubocop:disable Layout/LineLength
    end
  end

  context 'with basic interaction' do
    it 'serializes properly to json' do
      expect(described_class.basic(contents).to_json)
        .to eq('{"str":{"pact:matcher:type":"regex","value":"str","regex":"(?-mix:.*)"},"bool":{"pact:matcher:type":"boolean","value":true},"num":{"pact:matcher:type":"number","value":1},"nested":{"pact:matcher:type":"type","value":[{"a":1,"b":"2"}],"min":1}}') # rubocop:disable Layout/LineLength
    end
  end

  context 'with a scalar body' do
    it 'returns a plain string unchanged' do
      expect(described_class.basic('plain text').value).to eq('plain text')
    end

    it 'returns an integer unchanged' do
      expect(described_class.basic(42).value).to eq(42)
    end
  end

  context 'with an array of scalars nested in a hash' do
    it 'serializes without raising' do
      expect(described_class.basic({ some_array: [42] }).to_json).to eq('{"some_array":[42]}')
    end
  end

  context 'with combined (OR) matchers' do
    it 'serializes them inline as integration JSON at any depth' do
      contents = { pet: { name: match_any_string_or_nil('Rex'), tags: [match_any_integer_or_nil(1)] } }
      or_rule = lambda do |rule, value|
        { 'pact:matcher:type' => [rule, { 'pact:matcher:type' => 'null' }], 'pact:matcher:combine' => 'OR',
          'value' => value }
      end

      expect(JSON.parse(described_class.basic(contents).to_json)).to eq(
        'pet' => {
          'name' => or_rule.call({ 'pact:matcher:type' => 'regex', 'regex' => '(?-mix:.*)' }, 'Rex'),
          'tags' => [or_rule.call({ 'pact:matcher:type' => 'integer' }, 1)]
        }
      )
    end

    it 'serializes a top-level combined matcher (e.g. a header value)' do
      expect(described_class.basic({ 'X-Id' => match_or(match_regex(/\d+/, '1'), match_null, sample: '1') })['X-Id'])
        .to include('pact:matcher:combine' => 'OR', 'value' => '1')
    end
  end
end
