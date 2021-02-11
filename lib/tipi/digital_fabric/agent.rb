# frozen_string_literal: true

require_relative './protocol'
require_relative './request_adapter'

require 'msgpack'
require 'tipi/websocket'
require 'tipi/request'

module DigitalFabric
  class Agent
    def initialize(server_url, route, token)
      @server_url = server_url
      @route = route
      @token = token
      @requests = {}
      @long_running_requests = {}
      @name = '<unknown>'
    end

    class TimeoutError < RuntimeError
    end

    class GracefulShutdown < RuntimeError
    end

    def run
      @fiber = Fiber.current
      @keep_alive_timer = spin_loop(interval: 5) { keep_alive }
      while true
        connect_and_process_incoming_requests
        return if @shutdown
        sleep 5
      end
    ensure
      @keep_alive_timer.stop
    end

    def connect_and_process_incoming_requests
      # log 'Connecting...'
      @socket = connect_to_server
      @last_recv = @last_send = Time.now

      df_upgrade
      @connected = true
      @msgpack_reader = MessagePack::Unpacker.new
      
      process_incoming_requests
    rescue IOError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EPIPE, TimeoutError
      log 'Disconnected' if @connected
      @connected = nil
    end

    def connect_to_server
      if @server_url =~ /^([^\:]+)\:(\d+)$/
        host = Regexp.last_match(1)
        port = Regexp.last_match(2)
        Polyphony::Net.tcp_connect(host, port)
      else
        UNIXSocket.new(@server_url)
      end
    end

    UPGRADE_REQUEST = <<~HTTP
    GET / HTTP/1.1
    Host: localhost
    Connection: upgrade
    Upgrade: df
    DF-Token: %s
    DF-Mount: %s
  
    HTTP
  
    def df_upgrade
      @socket << format(UPGRADE_REQUEST, @token, mount_point)
      while (line = @socket.gets)
        break if line.chomp.empty?
      end
      # log 'Connection upgraded'
    end

    def mount_point
      if @route[:host]
        "host=#{@route[:host]}"
      elsif @route[:path]
        "path=#{@route[:path]}"
      else
        nil
      end
    end

    def log(msg)
      puts "#{Time.now} (#{@name}) #{msg}"
    end

    def process_incoming_requests
      @socket.feed_loop(@msgpack_reader, :feed_each) do |msg|
        recv_df_message(msg)
        return if @shutdown && @requests.empty?
      end
    rescue IOError, SystemCallError, TimeoutError
      # ignore
    end

    def keep_alive
      return unless @connected

      now = Time.now
      if now - @last_send >= Protocol::SEND_TIMEOUT
        send_df_message(Protocol.ping)
      end
      # if now - @last_recv >= Protocol::RECV_TIMEOUT
      #   raise TimeoutError
      # end
    rescue IOError, SystemCallError => e
      # transmit exception to fiber running the agent
      @fiber.raise(e)
    end

    def recv_df_message(msg)
      @last_recv = Time.now
      case msg['kind']
      when Protocol::SHUTDOWN
        recv_shutdown
      when Protocol::HTTP_REQUEST
        recv_http_request(msg)
      when Protocol::HTTP_REQUEST_BODY
        recv_http_request_body(msg)
      when Protocol::WS_REQUEST
        recv_ws_request(msg)
      when Protocol::CONN_DATA, Protocol::CONN_CLOSE,
           Protocol::WS_DATA, Protocol::WS_CLOSE
        fiber = @requests[msg['id']]
        fiber << msg if fiber
      end
    end

    def send_df_message(msg)
      # we mark long-running requests by applying simple heuristics to sent DF
      # messages. This is so we can correctly stop long-running requests
      # upon graceful shutdown
      if is_long_running_request_response?(msg)
        id = msg[:id]
        @long_running_requests[id] = @requests[id]
      end
      @last_send = Time.now
      @socket << msg.to_msgpack
    end

    def is_long_running_request_response?(msg)
      case msg[:kind]
      when Protocol::HTTP_UPGRADE
        true
      when Protocol::HTTP_RESPONSE
        msg[:body] && !msg[:complete]
      end
    end

    def recv_shutdown
      # puts "Received shutdown message (#{@requests.size} pending requests)"
      # puts "  (Long running requests: #{@long_running_requests.size})"
      @shutdown = true
      @long_running_requests.values.each { |f| f.terminate(true) }
    end

    def recv_http_request(msg)
      req = prepare_http_request(msg)
      id = msg['id']
      @requests[id] = spin do
        http_request(req)
      rescue IOError, Errno::ECONNREFUSED, Errno::EPIPE
        # ignore
      rescue Polyphony::Terminate
        req.respond(nil, { ':status' => 503 }) if Fiber.current.graceful_shutdown?
      ensure
        @requests.delete(id)
        @long_running_requests.delete(id)
        @fiber.terminate if @shutdown && @requests.empty?
      end
    end

    def prepare_http_request(msg)
      req = Qeweney::Request.new(msg['headers'], RequestAdapter.new(self, msg))
      req.buffer_body_chunk(msg['body']) if msg['body']
      req.complete! if msg['complete']
      req
    end

    def recv_http_request_body(msg)
      fiber = @requests[msg['id']]
      return unless fiber

      fiber << msg['body']
    end

    def get_http_request_body(id, limit)
      send_df_message(Protocol.http_get_request_body(id, limit))
      receive
    end

    def recv_ws_request(msg)
      req = Qeweney::Request.new(msg['headers'], RequestAdapter.new(self, msg))
      id = msg['id']
      @requests[id] = @long_running_requests[id] = spin do
        ws_request(req)
      rescue IOError, Errno::ECONNREFUSED, Errno::EPIPE
        # ignore
      ensure
        @requests.delete(id)
        @long_running_requests.delete(id)
        @fiber.terminate if @shutdown && @requests.empty?
      end
    end

    # default handler for HTTP request
    def http_request(req)
      req.respond(nil, { ':status': 501 })
    end

    # default handler for WS request
    def ws_request(req)
      req.respond(nil, { ':status': 501 })
    end
  end
end
