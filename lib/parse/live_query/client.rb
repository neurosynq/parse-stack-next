# encoding: UTF-8
# frozen_string_literal: true

require "json"
require "uri"
require "socket"
require "openssl"
require "securerandom"
require "base64"
require "digest"
require "monitor"
require "timeout"

require_relative "health_monitor"
require_relative "circuit_breaker"
require_relative "event_queue"

module Parse
  module LiveQuery
    # WebSocket client for Parse LiveQuery server.
    # Manages WebSocket connection, authentication, and subscription lifecycle.
    #
    # Features:
    # - Automatic ping/pong keep-alive with stale connection detection
    # - Circuit breaker for intelligent failure handling
    # - Event queue with backpressure protection
    # - Automatic reconnection with exponential backoff and jitter
    #
    # @example Basic usage
    #   client = Parse::LiveQuery::Client.new(
    #     url: "wss://your-parse-server.com",
    #     application_id: "your_app_id",
    #     client_key: "your_client_key"
    #   )
    #
    #   subscription = client.subscribe("Song", where: { artist: "Beatles" })
    #   subscription.on(:create) { |song| puts "New song!" }
    #
    #   client.shutdown(timeout: 5)
    #
    class Client
      # WebSocket operation codes
      OPCODE_CONTINUATION = 0x0
      OPCODE_TEXT = 0x1
      OPCODE_BINARY = 0x2
      OPCODE_CLOSE = 0x8
      OPCODE_PING = 0x9
      OPCODE_PONG = 0xA

      # Default maximum message size (1MB) - prevents memory exhaustion attacks
      DEFAULT_MAX_MESSAGE_SIZE = 1_048_576

      # Default frame read timeout in seconds - prevents indefinite blocking
      DEFAULT_FRAME_READ_TIMEOUT = 30

      # @return [String] WebSocket URL
      attr_reader :url

      # @return [String] Parse application ID
      attr_reader :application_id

      # @return [String, nil] Parse client key (REST API key)
      attr_reader :client_key

      # @return [String, nil] Parse master key
      attr_reader :master_key

      # @return [Symbol] connection state (:disconnected, :connecting, :connected, :closed)
      attr_reader :state

      # @return [Hash<Integer, Subscription>] active subscriptions by request ID
      attr_reader :subscriptions

      # @return [HealthMonitor] connection health monitor
      attr_reader :health_monitor

      # @return [CircuitBreaker] connection circuit breaker
      attr_reader :circuit_breaker

      # @return [EventQueue] event processing queue
      attr_reader :event_queue

      # @return [Integer] maximum allowed message size in bytes
      attr_reader :max_message_size

      # @return [Integer] frame read timeout in seconds
      attr_reader :frame_read_timeout

      # Create a new LiveQuery client
      # @param url [String] WebSocket URL (wss://...)
      # @param application_id [String] Parse application ID
      # @param client_key [String] Parse REST API key
      # @param master_key [String, nil] Parse master key (optional)
      # @param auto_connect [Boolean] connect immediately (default: true)
      # @param auto_reconnect [Boolean] automatically reconnect on disconnect (default: true)
      def initialize(url: nil, application_id: nil, client_key: nil, master_key: nil,
                     auto_connect: nil, auto_reconnect: nil)
        cfg = config

        # Use provided values or fall back to configuration/environment
        @url = url || cfg.url || derive_websocket_url
        @application_id = application_id || cfg.application_id ||
                          parse_client_value(:application_id)
        @client_key = client_key || cfg.client_key ||
                      parse_client_value(:api_key)
        @master_key = master_key || cfg.master_key ||
                      parse_client_value(:master_key)

        @auto_connect = auto_connect.nil? ? cfg.auto_connect : auto_connect
        @auto_reconnect = auto_reconnect.nil? ? cfg.auto_reconnect : auto_reconnect
        @max_message_size = cfg.max_message_size || DEFAULT_MAX_MESSAGE_SIZE
        @frame_read_timeout = cfg.frame_read_timeout || DEFAULT_FRAME_READ_TIMEOUT

        @state = :disconnected
        @subscriptions = {}
        @monitor = Monitor.new
        @socket = nil
        @reader_thread = nil
        @reconnect_thread = nil
        @reconnect_interval = cfg.initial_reconnect_interval
        @callbacks = Hash.new { |h, k| h[k] = [] }
        @client_id = nil

        # Initialize production components
        @health_monitor = HealthMonitor.new(
          client: self,
          ping_interval: cfg.ping_interval,
          pong_timeout: cfg.pong_timeout,
        )

        @circuit_breaker = CircuitBreaker.new(
          failure_threshold: cfg.circuit_failure_threshold,
          reset_timeout: cfg.circuit_reset_timeout,
          on_state_change: method(:on_circuit_state_change),
        )

        @event_queue = EventQueue.new(
          max_size: cfg.event_queue_size,
          strategy: cfg.backpressure_strategy,
          on_drop: method(:on_event_dropped),
        )

        Logging.info("LiveQuery client initialized", url: @url, application_id: @application_id)

        connect if @auto_connect && @url
      end

      # Connect to the LiveQuery server
      # @return [Boolean] true if connection initiated
      def connect
        return true if connected? || connecting?

        # Check circuit breaker before attempting connection
        unless @circuit_breaker.allow_request?
          time_remaining = @circuit_breaker.time_until_half_open
          Logging.warn("Connection blocked by circuit breaker",
                       state: @circuit_breaker.state,
                       time_until_retry: time_remaining)
          emit(:circuit_open, time_remaining)
          schedule_reconnect if @auto_reconnect
          return false
        end

        @monitor.synchronize do
          @state = :connecting
        end

        begin
          Logging.info("Connecting to LiveQuery server", url: @url)
          establish_connection
          start_reader_thread
          send_connect_message
          true
        rescue => e
          @circuit_breaker.record_failure
          @state = :disconnected
          Logging.error("Failed to connect", error: e)
          emit(:error, ConnectionError.new("Failed to connect: #{e.message}"))
          schedule_reconnect if @auto_reconnect
          false
        end
      end

      # Disconnect from the LiveQuery server
      # @param code [Integer] WebSocket close code
      # @param reason [String] close reason
      def close(code: 1000, reason: "Client closing")
        @auto_reconnect = false
        @monitor.synchronize do
          return if @state == :closed

          Logging.info("Closing connection", code: code, reason: reason)
          send_close_frame(code, reason) if @socket
          cleanup_connection
          @state = :closed
        end
        emit(:close)
      end

      # Graceful shutdown with timeout
      # @param timeout [Float] seconds to wait for graceful shutdown
      # @return [void]
      def shutdown(timeout: 5.0)
        Logging.info("Shutting down LiveQuery client", timeout: timeout)

        @auto_reconnect = false

        # Cancel any pending reconnect thread
        cancel_reconnect_thread

        # Stop health monitor
        @health_monitor.stop

        # Stop event queue and drain remaining events
        @event_queue.stop(drain: true, timeout: timeout / 2)

        # Close connection
        close(code: 1000, reason: "Shutdown")

        # Wait for reader thread to finish
        @reader_thread&.join(timeout / 2)

        # Force kill if still running
        @reader_thread&.kill
        @reader_thread = nil

        Logging.info("Shutdown complete",
                     events_processed: @event_queue.processed_count,
                     events_dropped: @event_queue.dropped_count)
      end

      # @return [Boolean] true if connected
      def connected?
        @state == :connected
      end

      # @return [Boolean] true if connecting
      def connecting?
        @state == :connecting
      end

      # @return [Boolean] true if closed
      def closed?
        @state == :closed
      end

      # Check if connection is healthy
      # @return [Boolean]
      def healthy?
        connected? && @health_monitor.healthy?
      end

      # Get comprehensive health information
      # @return [Hash]
      def health_info
        {
          state: @state,
          connected: connected?,
          healthy: healthy?,
          client_id: @client_id,
          subscription_count: @subscriptions.size,
          max_message_size: @max_message_size,
          health_monitor: @health_monitor.health_info,
          circuit_breaker: @circuit_breaker.info,
          event_queue: @event_queue.stats,
        }
      end

      # Subscribe to a Parse class with optional query constraints
      # @param class_name [String, Class] Parse class name or model class
      # @param where [Hash] query constraints
      # @param fields [Array<String>] specific fields to watch
      # @param session_token [String] session token for ACL-aware subscriptions
      # @return [Subscription]
      def subscribe(class_name, where: {}, fields: nil, session_token: nil)
        # Handle Parse::Object subclass
        if class_name.is_a?(Class) && class_name < Parse::Object
          class_name = class_name.parse_class
        end

        # Handle Parse::Query object
        if class_name.is_a?(Parse::Query)
          query = class_name
          class_name = query.table
          where = query.compile_where
        end

        subscription = Subscription.new(
          client: self,
          class_name: class_name,
          query: where,
          fields: fields,
          session_token: session_token,
        )

        @monitor.synchronize do
          @subscriptions[subscription.request_id] = subscription
        end

        Logging.debug("Subscription created",
                      request_id: subscription.request_id,
                      class_name: class_name)

        # Send subscribe message if connected
        if connected?
          send_message(subscription.to_subscribe_message)
        else
          # Queue subscription for when connection is established
          connect unless connecting?
        end

        subscription
      end

      # Unsubscribe from a subscription
      # @param subscription [Subscription]
      def unsubscribe(subscription)
        Logging.debug("Unsubscribing", request_id: subscription.request_id)
        send_message(subscription.to_unsubscribe_message) if connected?

        @monitor.synchronize do
          @subscriptions.delete(subscription.request_id)
        end
      end

      # Register callback for connection events
      # @param event [Symbol] :open, :close, :error, :circuit_open, :circuit_closed
      # @yield callback block
      def on(event, &block)
        @monitor.synchronize do
          @callbacks[event] << block if block_given?
        end
        self
      end

      # Callback for connection opened
      def on_open(&block)
        on(:open, &block)
      end

      # Callback for connection closed
      def on_close(&block)
        on(:close, &block)
      end

      # Callback for errors
      def on_error(&block)
        on(:error, &block)
      end

      private

      # Get configuration object
      # @return [Configuration]
      def config
        LiveQuery.config
      end

      # Safely get a value from the default Parse::Client if it exists
      # @param method [Symbol] the method to call on the client
      # @return [Object, nil] the value or nil if client not configured
      def parse_client_value(method)
        return nil unless Parse::Client.client?
        Parse::Client.client.send(method)
      rescue Parse::Error::ConnectionError
        nil
      end

      # Derive WebSocket URL from Parse server URL
      def derive_websocket_url
        server_url = parse_client_value(:server_url)
        return nil unless server_url

        uri = URI.parse(server_url)
        scheme = uri.scheme == "https" ? "wss" : "ws"
        "#{scheme}://#{uri.host}:#{uri.port || (scheme == "wss" ? 443 : 80)}"
      end

      # Establish TCP/SSL connection and perform WebSocket handshake
      def establish_connection
        uri = URI.parse(@url)
        host = uri.host
        port = uri.port || (uri.scheme == "wss" ? 443 : 80)
        path = uri.path.empty? ? "/" : uri.path

        # Create TCP socket
        tcp_socket = TCPSocket.new(host, port)

        # Wrap with SSL if wss://
        if uri.scheme == "wss"
          ssl_context = OpenSSL::SSL::SSLContext.new
          ssl_context.verify_mode = OpenSSL::SSL::VERIFY_PEER
          ssl_context.cert_store = OpenSSL::X509::Store.new
          ssl_context.cert_store.set_default_paths

          # Apply TLS version constraints from configuration
          cfg = config
          if cfg.ssl_min_version
            ssl_context.min_version = Configuration.tls_version_constant(cfg.ssl_min_version)
          end
          if cfg.ssl_max_version
            ssl_context.max_version = Configuration.tls_version_constant(cfg.ssl_max_version)
          end

          @socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, ssl_context)
          @socket.sync_close = true
          @socket.hostname = host
          @socket.connect
        else
          @socket = tcp_socket
        end

        # Perform WebSocket handshake
        perform_handshake(host, path)
      end

      # Perform WebSocket handshake
      def perform_handshake(host, path)
        key = Base64.strict_encode64(SecureRandom.random_bytes(16))

        handshake = [
          "GET #{path} HTTP/1.1",
          "Host: #{host}",
          "Upgrade: websocket",
          "Connection: Upgrade",
          "Sec-WebSocket-Key: #{key}",
          "Sec-WebSocket-Version: 13",
          "Sec-WebSocket-Protocol: graphql-ws",
          "",
        ].join("\r\n") + "\r\n"

        @socket.write(handshake)

        # Read response
        response = ""
        while (line = @socket.gets)
          response += line
          break if line == "\r\n"
        end

        unless response.include?("101")
          raise ConnectionError, "WebSocket handshake failed: #{response}"
        end

        Logging.debug("WebSocket handshake complete")
      end

      # Start background thread for reading messages
      def start_reader_thread
        @reader_thread = Thread.new do
          read_loop
        end
        @reader_thread.abort_on_exception = false
      end

      # Main read loop
      def read_loop
        while @socket && !@socket.closed?
          begin
            frame = read_frame
            handle_frame(frame) if frame
          rescue IOError, Errno::ECONNRESET, EOFError => e
            Logging.debug("Connection closed", reason: e.class.name)
            break
          rescue => e
            Logging.error("Read loop error", error: e)
            emit(:error, e)
            break
          end
        end

        handle_disconnect
      end

      # Read a WebSocket frame with timeout protection
      def read_frame
        first_byte = read_with_timeout(1)
        return nil unless first_byte

        first_byte = first_byte.unpack1("C")
        fin = (first_byte & 0x80) != 0
        opcode = first_byte & 0x0F

        second_byte = read_with_timeout(1).unpack1("C")
        masked = (second_byte & 0x80) != 0
        length = second_byte & 0x7F

        if length == 126
          length = read_with_timeout(2).unpack1("n")
        elsif length == 127
          length = read_with_timeout(8).unpack1("Q>")
        end

        # Prevent memory exhaustion from oversized frames
        if length > @max_message_size
          Logging.error("Message size exceeds limit",
                        size: length,
                        max_size: @max_message_size)
          raise ConnectionError, "Message size #{length} exceeds maximum allowed #{@max_message_size}"
        end

        mask_key = masked ? read_with_timeout(4) : nil
        payload = length > 0 ? read_with_timeout(length) : ""

        if masked && payload && mask_key
          payload = payload.bytes.each_with_index.map do |byte, i|
            byte ^ mask_key.bytes[i % 4]
          end.pack("C*")
        end

        { fin: fin, opcode: opcode, payload: payload }
      end

      # Read from socket with timeout protection
      # @param length [Integer] number of bytes to read
      # @return [String] the data read
      # @raise [ConnectionError] if read times out
      def read_with_timeout(length)
        return @socket.read(length) unless @frame_read_timeout && @frame_read_timeout > 0

        Timeout.timeout(@frame_read_timeout) do
          @socket.read(length)
        end
      rescue Timeout::Error
        Logging.error("Frame read timeout", timeout: @frame_read_timeout)
        raise ConnectionError, "Frame read timed out after #{@frame_read_timeout} seconds"
      end

      # Handle a WebSocket frame
      def handle_frame(frame)
        # Record activity for health monitoring
        @health_monitor.record_activity

        case frame[:opcode]
        when OPCODE_TEXT
          handle_message(frame[:payload])
        when OPCODE_PING
          send_pong(frame[:payload])
        when OPCODE_PONG
          @health_monitor.record_pong
        when OPCODE_CLOSE
          handle_close_frame(frame[:payload])
        end
      end

      # Handle incoming text message
      def handle_message(data)
        return unless data

        begin
          message = JSON.parse(data)
          process_server_message(message)
        rescue JSON::ParserError => e
          Logging.error("Failed to parse message", error: e, data: data)
          emit(:error, e)
        end
      end

      # Process a server message
      def process_server_message(message)
        op = message["op"]

        case op
        when "connected"
          handle_connected(message)
        when "subscribed"
          handle_subscribed(message)
        when "unsubscribed"
          handle_unsubscribed(message)
        when "create", "update", "delete", "enter", "leave"
          handle_event(op, message)
        when "error"
          handle_server_error(message)
        end
      end

      # Handle connected message from server
      def handle_connected(message)
        @client_id = message["clientId"]
        @monitor.synchronize do
          @state = :connected
          @reconnect_interval = config.initial_reconnect_interval
        end

        # Record successful connection
        @circuit_breaker.record_success

        # Start health monitoring
        @health_monitor.start

        # Start event queue processing
        @event_queue.start { |event| dispatch_event(event) }

        Logging.info("Connected to LiveQuery server", client_id: @client_id)
        emit(:open)

        # Send pending subscriptions
        resubscribe_all
      end

      # Handle subscription confirmed
      def handle_subscribed(message)
        request_id = message["requestId"]
        subscription = @subscriptions[request_id]
        if subscription
          subscription.confirm!
          Logging.debug("Subscription confirmed", request_id: request_id)
        end
      end

      # Handle unsubscription confirmed
      def handle_unsubscribed(message)
        request_id = message["requestId"]
        @monitor.synchronize do
          @subscriptions.delete(request_id)
        end
        Logging.debug("Unsubscription confirmed", request_id: request_id)
      end

      # Handle data event (create/update/delete/enter/leave)
      # Routes through event queue for backpressure handling
      def handle_event(op, message)
        request_id = message["requestId"]
        subscription = @subscriptions[request_id]
        return unless subscription

        event = Event.new(
          type: op.to_sym,
          class_name: message.dig("object", "className") || subscription.class_name,
          object_data: message["object"],
          original_data: message["original"],
          request_id: request_id,
          raw: message,
        )

        # Route through event queue for backpressure handling
        @event_queue.enqueue({ subscription: subscription, event: event })
      end

      # Dispatch event to subscription (called from event queue processor)
      # @param item [Hash] contains :subscription and :event
      def dispatch_event(item)
        subscription = item[:subscription]
        event = item[:event]
        subscription.handle_event(event)
      rescue => e
        Logging.error("Event dispatch error", error: e, event_type: event.type)
      end

      # Handle server error
      def handle_server_error(message)
        request_id = message["requestId"]
        error_message = message["error"] || "Unknown server error"
        code = message["code"]

        Logging.error("Server error", error: error_message, code: code, request_id: request_id)

        if request_id && @subscriptions[request_id]
          @subscriptions[request_id].fail!("#{error_message} (code: #{code})")
        else
          emit(:error, Error.new("#{error_message} (code: #{code})"))
        end
      end

      # Handle close frame
      def handle_close_frame(payload)
        code = payload[0..1].unpack1("n") if payload && payload.length >= 2
        Logging.debug("Received close frame", code: code)
        cleanup_connection
      end

      # Handle disconnect
      def handle_disconnect
        was_connected = connected?
        cleanup_connection

        if was_connected
          emit(:close)
          schedule_reconnect if @auto_reconnect
        end
      end

      # Cleanup connection resources
      def cleanup_connection
        # Stop health monitor
        @health_monitor.stop

        # Stop event queue (but don't drain during disconnect - we may reconnect)
        @event_queue.stop(drain: false)

        @monitor.synchronize do
          @state = :disconnected unless @state == :closed
          @socket&.close rescue nil
          @socket = nil
        end

        Logging.debug("Connection cleaned up")
      end

      # Schedule reconnection with exponential backoff and jitter
      def schedule_reconnect
        return if @state == :closed

        # Cancel any existing reconnect thread to prevent accumulation
        cancel_reconnect_thread

        cfg = config
        jitter_factor = cfg.reconnect_jitter
        jitter = @reconnect_interval * jitter_factor * (rand - 0.5) * 2
        delay = @reconnect_interval + jitter
        delay = [delay, 0.1].max # Ensure positive delay

        Logging.info("Scheduling reconnect", delay: delay.round(2))

        @reconnect_thread = Thread.new do
          sleep delay
          @monitor.synchronize do
            @reconnect_thread = nil
          end
          @reconnect_interval = [@reconnect_interval * cfg.reconnect_multiplier,
                                 cfg.max_reconnect_interval].min
          connect
        end
      end

      # Cancel any pending reconnect thread
      def cancel_reconnect_thread
        @monitor.synchronize do
          if @reconnect_thread&.alive?
            @reconnect_thread.kill
            @reconnect_thread = nil
          end
        end
      end

      # Resubscribe all pending subscriptions
      def resubscribe_all
        subs = @monitor.synchronize { @subscriptions.values.dup }
        subs.each do |subscription|
          send_message(subscription.to_subscribe_message)
        end
        Logging.debug("Resubscribed to all subscriptions", count: subs.size)
      end

      # Send connect message to server
      def send_connect_message
        message = {
          op: "connect",
          applicationId: @application_id,
        }

        message[:clientKey] = @client_key if @client_key
        message[:masterKey] = @master_key if @master_key

        send_message(message)
      end

      # Send a message through the WebSocket
      def send_message(message)
        data = message.is_a?(String) ? message : message.to_json
        send_frame(OPCODE_TEXT, data)
      end

      # Send a WebSocket frame
      def send_frame(opcode, data)
        @monitor.synchronize do
          return unless @socket && !@socket.closed?

          bytes = data.bytes
          length = bytes.length

          # Build frame
          frame = [0x80 | opcode].pack("C") # FIN + opcode

          # Length with mask bit set (client must mask)
          if length < 126
            frame += [0x80 | length].pack("C")
          elsif length < 65536
            frame += [0x80 | 126, length].pack("Cn")
          else
            frame += [0x80 | 127, length].pack("CQ>")
          end

          # Generate mask key and apply
          mask = SecureRandom.random_bytes(4)
          frame += mask

          masked_data = bytes.each_with_index.map do |byte, i|
            byte ^ mask.bytes[i % 4]
          end.pack("C*")

          frame += masked_data

          @socket.write(frame)
        end
      end

      # Send ping frame (called by health monitor)
      def send_ping
        Logging.debug("Sending ping")
        send_frame(OPCODE_PING, "")
      end

      # Send pong frame
      def send_pong(data)
        send_frame(OPCODE_PONG, data || "")
      end

      # Send close frame
      def send_close_frame(code, reason)
        data = [code].pack("n") + reason.to_s
        send_frame(OPCODE_CLOSE, data)
      end

      # Handle stale connection (called by health monitor)
      def handle_stale_connection
        Logging.warn("Connection stale, triggering reconnect")
        cleanup_connection
        schedule_reconnect if @auto_reconnect
      end

      # Circuit breaker state change callback
      def on_circuit_state_change(old_state, new_state)
        Logging.info("Circuit breaker state change", from: old_state, to: new_state)
        case new_state
        when :open
          emit(:circuit_open, @circuit_breaker.time_until_half_open)
        when :closed
          emit(:circuit_closed)
        end
      end

      # Event dropped callback
      def on_event_dropped(event, reason)
        Logging.warn("Event dropped due to backpressure",
                     reason: reason,
                     event_type: event[:event]&.type)
      end

      # Emit event to callbacks (thread-safe)
      def emit(event, *args)
        # Copy callbacks under lock, iterate outside to prevent deadlocks
        callbacks = @monitor.synchronize { @callbacks[event].dup }
        callbacks.each do |callback|
          begin
            callback.call(*args)
          rescue => e
            Logging.error("Callback error", event: event, error: e)
          end
        end
      end
    end
  end
end
