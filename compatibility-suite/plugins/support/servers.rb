# frozen_string_literal: true

require 'webrick'
require 'net/http'
require 'logger'

# Test providers and clients used by the plugin steps.
module CompatServers
  module_function

  def free_port
    s = TCPServer.new('127.0.0.1', 0)
    port = s.addr[1]
    s.close
    port
  end

  USED_MOCK_PORTS = []

  # A free port no earlier mock server in this run has used. The matt plugin keeps
  # per-port mock server state after cleanup, so a reused port inherits old mismatches.
  def fresh_mock_port
    port = free_port
    port = free_port while USED_MOCK_PORTS.include?(port)
    USED_MOCK_PORTS << port
    port
  end

  def quiet_webrick(port = 0)
    WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: port, Logger: WEBrick::Log.new(File::NULL),
                            AccessLog: [])
  end

  def start_webrick(server)
    Thread.new { server.start }
    [server, server.listeners.first.addr[1]]
  end

  # HTTP provider that returns a fixed body for any request.
  def http_provider(body, content_type)
    server = quiet_webrick
    server.mount_proc('/') do |_req, res|
      res.status = 200
      res['Content-Type'] = content_type
      res.body = body
    end
    start_webrick(server)
  end

  # Rack app equivalent of http_provider, for the DSL HttpVerifier.
  def rack_provider(body, content_type)
    ->(_env) { [200, { 'content-type' => content_type }, [body]] }
  end

  # Message provider: answers the verifier's POST for the named message.
  def message_provider(name, body, content_type)
    server = quiet_webrick
    server.mount_proc('/') do |req, res|
      desc = begin
        JSON.parse(req.body || '{}')['description']
      rescue JSON::ParserError
        nil
      end
      if req.request_method == 'POST' && desc == name
        res.status = 200
        res['Content-Type'] = content_type
        res['Pact-Message-Metadata'] = Base64.strict_encode64(JSON.dump({ 'contentType' => content_type }))
        res.body = body
      else
        res.status = 404
      end
    end
    start_webrick(server)
  end

  # Line-based TCP provider for the matt transport.
  def tcp_provider(expected, reply)
    server = TCPServer.new('127.0.0.1', 0)
    thread = Thread.new do
      loop do
        client = server.accept
        Thread.new(client) do |c|
          while (line = c.gets)
            c.write("#{line.chomp == expected ? reply : 'MATTerrorMATT'}\n")
          end
        rescue IOError, SystemCallError
          nil
        ensure
          c.close
        end
      end
    rescue IOError, SystemCallError
      nil
    end
    [server, thread, server.addr[1]]
  end

  # Passes raw protobuf bytes through the grpc gem untouched.
  class RawBytes
    attr_reader :data

    def initialize(data) = @data = data
    def self.encode(obj) = obj.is_a?(RawBytes) ? obj.data : obj
    def self.decode(bytes) = bytes
    def self.marshal(obj) = encode(obj)
    def self.unmarshal(bytes) = bytes
  end

  # gRPC provider answering a single unary method with fixed bytes.
  def grpc_provider(method_path, reply)
    service_name, rpc_name = method_path.delete_prefix('/').split('/')
    handler = rpc_name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
    service = Class.new do
      include GRPC::GenericService

      self.service_name = service_name
      rpc rpc_name.to_sym, CompatServers::RawBytes, CompatServers::RawBytes
      define_method(handler) { |_req, _call| CompatServers::RawBytes.new(reply) }
    end
    server = GRPC::RpcServer.new(pool_size: 2)
    port = server.add_http2_port('127.0.0.1:0', :this_port_is_insecure)
    server.handle(service)
    Thread.new { server.run }
    server.wait_till_running(10)
    [server, port]
  end

  # The pact gRPC mock server listens on ::1 only; prefer 127.0.0.1 if reachable.
  def local_host_for(port)
    TCPSocket.new('127.0.0.1', port).close
    '127.0.0.1'
  rescue SystemCallError
    '[::1]'
  end

  def grpc_call(port, method_path, request)
    stub = GRPC::ClientStub.new("#{local_host_for(port)}:#{port}", :this_channel_is_insecure)
    reply = stub.request_response(method_path, request, RawBytes.method(:encode), RawBytes.method(:decode),
                                  deadline: Time.now + 10)
    [:ok, reply]
  rescue GRPC::BadStatus => e
    [:error, e]
  end

  def tcp_line(port, line)
    host = local_host_for(port).delete('[]')
    Socket.tcp(host, port, connect_timeout: 5) do |sock|
      sock.write("#{line}\n")
      sock.close_write
      Timeout.timeout(10) { sock.gets&.chomp }
    end
  end

  def http_request(port, method, path, content_type = nil, body = nil)
    Net::HTTP.start('127.0.0.1', port, read_timeout: 10) do |http|
      req = Net::HTTPGenericRequest.new(method, !body.nil?, true, path)
      if body
        req['Content-Type'] = content_type if content_type
        req.body = body
      end
      http.request(req)
    end
  end
end
