# frozen_string_literal: true

RSpec.describe Pact::Consumer::HttpInteractionBuilder do
  let(:pact_config) do
    instance_double(
      'Pact::ConsumerContractBuilder',
      pact_handle: nil,
      'pact_handle=' => nil,
      consumer_name: 'consumer',
      provider_name: 'provider',
      pact_specification: 'V4',
      log_level: 'INFO'
    )
  end

  subject { described_class.new(pact_config) }

  describe '#reference' do
    it 'queues the reference and returns self' do
      result = subject.reference('group', 'name', 'value')
      expect(subject.instance_variable_get(:@references)).to eq([%w[group name value]])
      expect(result).to be(subject)
    end

    it 'raises when group is blank' do
      expect do
        subject.reference('', 'name', 'value')
      end.to raise_error(described_class::InteractionBuilderError, /group is required/)
    end

    it 'raises when name is blank' do
      expect do
        subject.reference('group', '', 'value')
      end.to raise_error(described_class::InteractionBuilderError, /name is required/)
    end

    it 'raises when value is blank' do
      expect do
        subject.reference('group', 'name', '')
      end.to raise_error(described_class::InteractionBuilderError, /value is required/)
    end
  end

  describe 'headers' do
    let(:request_part) { PactFfi::FfiInteractionPart['INTERACTION_PART_REQUEST'] }
    let(:response_part) { PactFfi::FfiInteractionPart['INTERACTION_PART_RESPONSE'] }

    before { allow(PactFfi).to receive(:with_header_v2).and_call_original }

    it 'registers a single value at index 0' do
      subject.with_request(method: :get, path: '/', headers: { 'X-Request' => 'a' })

      expect(PactFfi).to have_received(:with_header_v2).with(anything, request_part, 'X-Request', 0, 'a').once
    end

    it 'registers each request header array element at its own index' do
      subject.with_request(method: :get, path: '/', headers: { 'X-Request' => %w[a b] })

      expect(PactFfi).to have_received(:with_header_v2).with(anything, request_part, 'X-Request', 0, 'a').ordered
      expect(PactFfi).to have_received(:with_header_v2).with(anything, request_part, 'X-Request', 1, 'b').ordered
    end

    it 'serialises each matcher in a request header array at its own index' do
      subject.with_request(method: :get, path: '/', headers: {
                             'X-Request' => [Pact::Matchers::V2::Regex.new(/^first-\d+$/, 'first-1'), 'b']
                           })

      expect(PactFfi).to have_received(:with_header_v2)
        .with(anything, request_part, 'X-Request', 0, satisfy { |v| JSON.parse(v)['pact:matcher:type'] == 'regex' })
      expect(PactFfi).to have_received(:with_header_v2).with(anything, request_part, 'X-Request', 1, 'b')
    end

    it 'registers each response header array element at its own index' do
      subject.will_respond_with(status: 200, headers: {
                                  'X-Response' => ['a', Pact::Matchers::V2::Regex.new(/^first-\d+$/, 'first-1')]
                                })

      expect(PactFfi).to have_received(:with_header_v2).with(anything, response_part, 'X-Response', 0, 'a')
      expect(PactFfi).to have_received(:with_header_v2)
        .with(anything, response_part, 'X-Response', 1, satisfy { |v| JSON.parse(v)['pact:matcher:type'] == 'regex' })
    end
  end
end
