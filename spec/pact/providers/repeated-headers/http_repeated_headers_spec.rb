# frozen_string_literal: true

require 'pact/rspec'
require 'socket'
require 'tmpdir'

# Repeated HTTP headers (RFC 9110 §5.3, pact-reference#568 / #584).
#
# An Array header value declares one expected value per index. Requests are written over a
# raw TCP socket so every field line reaches the mock server as its own line (HTTP clients
# merge, reorder or reject repeated header lines).
#
# Some of these cases (e.g. H2, one comma-separated field line) need a pact_ffi that
# includes pact-reference#584.
RSpec.describe 'PactProviders::RepeatedHeaders', :pact do
  pact_dir = Dir.mktmpdir('pact-repeated-headers')

  has_http_pact_between 'pact-ruby-repeated-headers-consumer', 'pact-ruby-repeated-headers-provider', opts: {
    pact_specification: 'V3',
    pact_dir: pact_dir
  }

  after(:context) { FileUtils.rm_rf(pact_dir) }

  # Sends GET /headers with one `header` field line per entry in field_lines.
  # Returns [status, response header field lines].
  def send_raw(port, header, field_lines)
    socket = TCPSocket.new('127.0.0.1', port)
    request = +"GET /headers HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n"
    field_lines.each { |line| request << "#{header}: #{line}\r\n" }
    request << "Connection: close\r\n\r\n"
    socket.write(request)
    response = socket.read
    socket.close
    head = response.split("\r\n\r\n", 2).first.split("\r\n")
    [head.first.split[1].to_i, head.drop(1)]
  end

  def repeated_request(header, values)
    new_interaction
      .upon_receiving("a request with a repeated #{header} header")
      .with_request(method: :get, path: '/headers', headers: { header => values })
      .will_respond_with(status: 200)
  end

  context 'with repeated request headers' do
    it 'H1: matches values sent on separate field lines' do
      repeated_request('X-Request', %w[a b]).execute do |mock_server|
        expect(send_raw(mock_server.port, 'X-Request', %w[a b]).first).to eq(200)
      end
    end

    it 'H2: matches values sent as one comma-separated field line' do
      repeated_request('X-Request', %w[a b]).execute do |mock_server|
        expect(send_raw(mock_server.port, 'X-Request', ['a, b']).first).to eq(200)
      end
    end

    it 'H4: does not match a single-value header sent as one comma-separated field line' do
      expect do
        repeated_request('Content-Type', ['text/plain', 'text/html']).execute do |mock_server|
          expect(send_raw(mock_server.port, 'Content-Type', ['text/plain, text/html']).first).not_to eq(200)
        end
      end.to raise_error(Pact::Consumer::HttpInteractionBuilder::InteractionMismatchesError)
    end

    it 'H6a: applies one matcher per index' do
      values = [match_regex(/^first-\d+$/, 'first-1'), match_regex(/^first-\d+$/, 'first-2')]
      repeated_request('X-Request', values).execute do |mock_server|
        expect(send_raw(mock_server.port, 'X-Request', %w[first-42 first-99]).first).to eq(200)
      end
    end

    it 'applies a different matcher at each index' do
      values = [match_regex(/^first-\d+$/, 'first-1'), match_regex(/^second-\d+$/, 'second-1')]
      repeated_request('X-Request', values).execute do |mock_server|
        expect(send_raw(mock_server.port, 'X-Request', %w[first-42 second-99]).first).to eq(200)
      end
    end

    it 'rejects values that do not match the matcher at their index' do
      values = [match_regex(/^first-\d+$/, 'first-1'), match_regex(/^second-\d+$/, 'second-1')]
      expect do
        repeated_request('X-Request', values).execute do |mock_server|
          expect(send_raw(mock_server.port, 'X-Request', %w[second-99 first-42]).first).not_to eq(200)
        end
      end.to raise_error(Pact::Consumer::HttpInteractionBuilder::InteractionMismatchesError)
    end

    it 'mixes literals and matchers' do
      values = ['a', match_regex(/^second-\d+$/, 'second-1')]
      repeated_request('X-Request', values).execute do |mock_server|
        expect(send_raw(mock_server.port, 'X-Request', %w[a second-99]).first).to eq(200)
      end
    end

    it 'H8b: matches Link values sent as one field line' do
      links = ['<https://a.example/x,y>; rel="a"', '<https://b.example/>; rel="b"']
      repeated_request('Link', links).execute do |mock_server|
        expect(send_raw(mock_server.port, 'Link', [links.join(', ')]).first).to eq(200)
      end
    end
  end

  context 'with repeated response headers' do
    it 'returns one value per index, including the example of a matcher' do
      new_interaction
        .upon_receiving('a request for a response with a repeated header')
        .with_request(method: :get, path: '/headers')
        .will_respond_with(status: 200, headers: {
                             'X-Response' => ['a', match_regex(/^second-\d+$/, 'second-1')]
                           })
        .execute do |mock_server|
          status, header_lines = send_raw(mock_server.port, 'X-Other', [])
          values = header_lines.grep(/\Ax-response:/i)
                               .flat_map { |line| line.split(':', 2).last.split(',').map(&:strip) }

          expect(status).to eq(200)
          expect(values).to eq(%w[a second-1])
        end
    end
  end
end
