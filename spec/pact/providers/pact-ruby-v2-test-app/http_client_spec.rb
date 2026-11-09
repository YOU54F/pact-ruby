# frozen_string_literal: true

require 'pact/rspec'

RSpec.describe 'PactProviders::Test::HttpClient', :pact do
  has_http_pact_between 'pact-ruby-test-app-http-consumer', 'pact-ruby-test-app-provider', opts: {
    mock_port: 3000
  }

  let(:pet_id) { 123 }
  let(:host) { 'localhost:3000' }
  let(:interaction) { new_interaction }
  let(:http_client) do
    Faraday.new do |conn|
      conn.response :json
      conn.request :json
    end
  end

  context 'with GET /pets/:id' do
    let(:make_request) do
      http_client.get("http://#{host}/pets/#{pet_id}")
    end

    context 'with successful interaction' do
      let(:interaction) do
        super()
          .given('pet exists', pet_id: pet_id)
          .upon_receiving('getting a pet')
          .with_request(method: :get, path: "/pets/#{pet_id}")
          .will_respond_with(status: 200, body: {
                               pet: {
                                 id: match_any_integer(pet_id),
                                 bark: match_any_boolean_or_nil(true),
                                 breed: match_any_string_or_nil('Husky')
                               }
                             })
      end

      it 'executes the pact test without errors' do
        interaction.execute do
          expect(make_request).to be_success
        end
      end
    end
  end

  context 'with PATCH /pets' do
    let(:make_request) do
      http_client.patch("http://#{host}/pets/#{pet_id}", pet_data.to_json,
                        { 'Authorization' => 'some-token' })
    end
    let(:pet_data) { { breed: 'Shepherd' } }

    context 'with successful interaction' do
      let(:interaction) do
        super()
          .given('pet exists', pet_id: pet_id)
          .upon_receiving('updating a pet')
          .with_request(method: :patch, path: "/pets/#{pet_id}",
                        headers: { Authorization: match_any_string('some-token') },
                        body: pet_data)
          .will_respond_with(status: 200,
                             headers: { TRACE_ID: match_any_string('xxx-xxx') },
                             body: {
                               pet: {
                                 id: match_any_integer(pet_id),
                                 bark: match_any_boolean(true),
                                 breed: match_any_string('Shepherd')
                               }
                             })
      end

      it 'executes the pact test without errors' do
        interaction.execute do
          expect(make_request).to be_success
        end
      end
    end
  end
end

# OR / AND combined matchers (pact_ffi integration JSON `pact:matcher:combine`).
# Uses its own consumer name and pact dir so the interactions are not replayed
# against the test app by the provider verification in spec/pact/consumers.
RSpec.describe 'PactProviders::Test::HttpClient combined matchers', :pact do
  or_pact_dir = Dir.mktmpdir('pact-ruby-or-matcher')

  has_http_pact_between 'pact-ruby-or-matcher-consumer', 'pact-ruby-or-matcher-provider', opts: {
    mock_port: 3010,
    pact_dir: or_pact_dir
  }

  let(:host) { 'localhost:3010' }
  let(:pact_file) { File.join(or_pact_dir, 'pact-ruby-or-matcher-consumer-pact-ruby-or-matcher-provider.json') }
  let(:http_client) do
    Faraday.new do |conn|
      conn.response :json
      conn.request :json
    end
  end

  let(:interaction) do
    new_interaction
      .upon_receiving('creating a pet with nullable fields')
      .with_request(
        method: :post,
        path: '/pets',
        query: { limit: match_or(match_regex(/^\d+$/, '10'), match_regex(/^all$/, 'all'), sample: '10') },
        headers: {
          'X-Request-Id' => match_or(match_regex(/^\d+$/, '123'), match_uuid, sample: '123')
        },
        body: {
          name: match_any_string_or_nil('Rex'),
          owner: match_or(
            match_type_of({}), match_null,
            sample: { name: 'Bob', age: match_any_integer(30) }
          )
        }
      )
      .will_respond_with(status: 201)
  end

  def post_pet(limit:, request_id:, body:)
    http_client.post("http://#{host}/pets?limit=#{limit}", body.to_json,
                     { 'X-Request-Id' => request_id, 'Content-Type' => 'application/json' })
  end

  it 'matches the sample values' do
    interaction.execute do
      expect(post_pet(limit: '10', request_id: '123', body: { name: 'Rex', owner: { name: 'Bob', age: 30 } }).status)
        .to eq(201)
    end
  end

  it 'matches the other alternatives (null, uuid, literal)' do
    interaction.execute do
      expect(post_pet(limit: 'all', request_id: 'e1d01e04-3a2b-4eed-a4fb-54f5cd257338',
                      body: { name: nil, owner: nil }).status).to eq(201)
    end
  end

  it 'still applies nested rules inside a non-null object sample' do
    expect do
      interaction.execute do
        post_pet(limit: '5', request_id: '9', body: { name: 'Fido', owner: { name: 'Al', age: 'old' } })
      end
    end.to raise_error(Pact::Consumer::HttpInteractionBuilder::InteractionMismatchesError, /\$\.owner\.age/)
  end

  it 'fails when a value matches none of the alternatives' do
    expect do
      interaction.execute do
        post_pet(limit: 'some', request_id: 'not-an-id', body: { name: 'Rex', owner: 'nobody' })
      end
    end.to raise_error(Pact::Consumer::HttpInteractionBuilder::InteractionMismatchesError) { |error|
      expect(error.message).to include(
        "Expected 'nobody' (String) to be a null value",
        "Expected 'not-an-id' to match",
        "Expected 'some' to match '(?-mix:^all$)'"
      )
    }
  end

  it 'writes combine OR rules to the pact file' do
    interaction.execute do
      post_pet(limit: '10', request_id: '123', body: { name: 'Rex', owner: { name: 'Bob', age: 30 } })
    end

    request = JSON.parse(File.read(pact_file))['interactions'].first['request']
    rules = request['matchingRules']
    expect(rules['body']['$.name']).to include('combine' => 'OR',
                                               'matchers' => [a_hash_including('match' => 'regex'),
                                                              { 'match' => 'null' }])
    expect(rules['body']['$.owner']).to eq('combine' => 'OR',
                                           'matchers' => [{ 'match' => 'type' }, { 'match' => 'null' }])
    expect(rules['body']['$.owner.age']['matchers']).to eq([{ 'match' => 'integer' }])
    expect(rules['header']['X-Request-Id']).to include('combine' => 'OR')
    expect(rules['query']['limit']).to include('combine' => 'OR')
    expect(request['body']['content']).to eq('name' => 'Rex', 'owner' => { 'name' => 'Bob', 'age' => 30 })
  end
end
