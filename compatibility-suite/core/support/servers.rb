# frozen_string_literal: true

require 'net/http'

# A minimal recording HTTP/1.1 server, used as the provider under test, the provider state
# callback and a stand-in Pact broker. Each connection serves one request and closes. Written
# on a raw socket (not WEBrick) so responses carry exactly the headers and bytes the steps set.
module CompatServers
  Request = Struct.new(:method, :path, :headers, :body) do
    def header(name) = headers.find { |k, _| k.casecmp?(name) }&.last
    def path_only = path.split('?').first
  end

  Response = Struct.new(:status, :headers, :body) do
    def self.json(status, value)
      new(status, [%w[Content-Type application/json]], JSON.dump(value))
    end
  end

  class Server
    attr_reader :port

    # The handler gets (request, port) and returns a Response.
    def initialize(&handler)
      @server = TCPServer.new('127.0.0.1', 0)
      @port = @server.addr[1]
      @requests = []
      @lock = Mutex.new
      @thread = Thread.new do
        loop do
          client = @server.accept
          Thread.new(client) { |c| serve(c, handler) }
        end
      rescue IOError, SystemCallError
        nil
      end
    end

    def url = "http://127.0.0.1:#{@port}"
    def requests = @lock.synchronize { @requests.dup }

    def stop
      @server.close
      @thread.kill
    end

    private

    def serve(client, handler)
      req = read_request(client)
      return unless req

      res = begin
        handler.call(req, @port)
      rescue StandardError => e
        Response.new(500, [], "#{e.class}: #{e.message}")
      end
      @lock.synchronize { @requests << req }
      client.write(encode(res))
    rescue IOError, SystemCallError
      nil
    ensure
      client.close
    end

    def read_request(client)
      line = client.gets("\r\n") or return nil
      method, path = line.split(' ')
      headers = []
      while (l = client.gets("\r\n")) && l != "\r\n"
        k, v = l.chomp("\r\n").split(':', 2)
        headers << [k.strip, v.to_s.strip]
      end
      len = headers.find { |k, _| k.casecmp?('content-length') }&.last.to_i
      body = len.positive? ? client.read(len) : +''
      Request.new(method, path, headers, body.b)
    end

    def encode(res)
      out = +"HTTP/1.1 #{res.status} X\r\n"
      res.headers.each { |k, v| out << "#{k}: #{v}\r\n" }
      body = (res.body || '').b
      out << "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
      out.b + body
    end
  end

  module_function

  ClientResponse = Struct.new(:status, :headers, :body) do
    def header(name) = headers.find { |k, _| k.casecmp?(name) }&.last
  end

  # Sends a request with exactly the given headers ([name, value] pairs) over a raw socket:
  # Net::HTTP would add Accept, User-Agent and a default Content-Type the scenarios do not expect.
  def http_request(port, method, path, headers, body)
    Socket.tcp('127.0.0.1', port, connect_timeout: 5) do |sock|
      out = +"#{method.upcase} #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n"
      headers.each { |k, v| out << "#{k}: #{v}\r\n" }
      out << "Content-Length: #{body.bytesize}\r\n" if body
      out << "Connection: close\r\n\r\n"
      sock.write(out.b + (body || '').b)
      Timeout.timeout(10) { read_response(sock) }
    end
  end

  def read_response(sock)
    status = sock.gets("\r\n").split(' ')[1].to_i
    headers = []
    while (l = sock.gets("\r\n")) && l != "\r\n"
      k, v = l.chomp("\r\n").split(':', 2)
      headers << [k.strip, v.to_s.strip]
    end
    find = ->(n) { headers.find { |k, _| k.casecmp?(n) }&.last }
    body =
      if find.('transfer-encoding')&.casecmp?('chunked')
        buf = +''
        while (size = sock.gets("\r\n").to_i(16)).positive?
          buf << sock.read(size)
          sock.read(2)
        end
        buf
      elsif find.('content-length')
        sock.read(find.('content-length').to_i)
      else
        sock.read
      end
    ClientResponse.new(status, headers, (body || '').b)
  end
end
