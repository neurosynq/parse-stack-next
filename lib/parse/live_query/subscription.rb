# encoding: UTF-8
# frozen_string_literal: true

require "monitor"

module Parse
  module LiveQuery
    # Represents an active subscription to a LiveQuery.
    # Manages event callbacks and subscription lifecycle.
    #
    # @example
    #   subscription = Song.subscribe(where: { artist: "Beatles" })
    #
    #   # Register callbacks using on() method
    #   subscription.on(:create) { |song| puts "New song!" }
    #   subscription.on(:update) { |song, original| puts "Updated!" }
    #
    #   # Or use shorthand methods
    #   subscription.on_create { |song| puts "New song!" }
    #   subscription.on_update { |song, original| puts "Updated!" }
    #   subscription.on_delete { |song| puts "Deleted!" }
    #   subscription.on_enter { |song, original| puts "Entered query!" }
    #   subscription.on_leave { |song, original| puts "Left query!" }
    #
    #   # Error handling
    #   subscription.on_error { |error| puts "Error: #{error.message}" }
    #
    #   # Connection events
    #   subscription.on_subscribe { puts "Subscribed!" }
    #   subscription.on_unsubscribe { puts "Unsubscribed!" }
    #
    #   # Cleanup
    #   subscription.unsubscribe
    #
    class Subscription
      # Class-level monitor for request ID generation
      @@id_monitor = Monitor.new
      @@request_counter = 0

      # @return [Integer] unique request ID for this subscription
      attr_reader :request_id

      # @return [String] Parse class name being subscribed to
      attr_reader :class_name

      # @return [Hash] the query constraints (where clause)
      attr_reader :query

      # @return [Parse::LiveQuery::Client] the LiveQuery client
      attr_reader :client

      # @return [Array<String>] fields to watch for changes (nil = all fields)
      attr_reader :fields

      # @return [String, nil] session token for ACL-aware subscriptions
      attr_reader :session_token

      # Create a new subscription
      # @param client [Parse::LiveQuery::Client] the LiveQuery client
      # @param class_name [String] Parse class name
      # @param query [Hash] query constraints (where clause)
      # @param fields [Array<String>, nil] specific fields to watch
      # @param session_token [String, nil] session token for authentication
      def initialize(client:, class_name:, query: {}, fields: nil, session_token: nil)
        @monitor = Monitor.new
        @client = client
        @class_name = class_name
        @query = query
        @fields = fields
        @session_token = session_token
        @request_id = generate_request_id
        @state = :pending
        @callbacks = Hash.new { |h, k| h[k] = [] }

        Logging.debug("Subscription created",
                      request_id: @request_id,
                      class_name: @class_name,
                      query_keys: @query.keys)
      end

      # Current subscription state
      # @return [Symbol] :pending, :subscribed, :unsubscribed, or :error
      def state
        @monitor.synchronize { @state }
      end

      # Register a callback for a specific event type
      # @param event_type [Symbol] :create, :update, :delete, :enter, :leave, :error, :subscribe, :unsubscribe
      # @yield [object, original] block to call when event occurs
      # @return [self]
      def on(event_type, &block)
        return self unless block_given?

        @monitor.synchronize do
          @callbacks[event_type.to_sym] << block
        end
        self
      end

      # Register callback for create events
      # @yield [Parse::Object] the created object
      # @return [self]
      def on_create(&block)
        on(:create, &block)
      end

      # Register callback for update events
      # @yield [Parse::Object, Parse::Object] updated object, original object
      # @return [self]
      def on_update(&block)
        on(:update, &block)
      end

      # Register callback for delete events
      # @yield [Parse::Object] the deleted object
      # @return [self]
      def on_delete(&block)
        on(:delete, &block)
      end

      # Register callback for enter events (object now matches query)
      # @yield [Parse::Object, Parse::Object] current object, original object
      # @return [self]
      def on_enter(&block)
        on(:enter, &block)
      end

      # Register callback for leave events (object no longer matches query)
      # @yield [Parse::Object, Parse::Object] current object, original object
      # @return [self]
      def on_leave(&block)
        on(:leave, &block)
      end

      # Register callback for errors
      # @yield [Exception] the error that occurred
      # @return [self]
      def on_error(&block)
        on(:error, &block)
      end

      # Register callback for successful subscription
      # @yield called when subscription is confirmed
      # @return [self]
      def on_subscribe(&block)
        on(:subscribe, &block)
      end

      # Register callback for unsubscription
      # @yield called when unsubscribed
      # @return [self]
      def on_unsubscribe(&block)
        on(:unsubscribe, &block)
      end

      # Unsubscribe from this subscription
      # @return [Boolean] true if unsubscribe message was sent
      def unsubscribe
        @monitor.synchronize do
          return false if @state == :unsubscribed
          @state = :unsubscribed
        end

        Logging.debug("Unsubscribing", request_id: @request_id)
        client.unsubscribe(self)
        emit(:unsubscribe)
        true
      end

      # @return [Boolean] true if currently subscribed
      def subscribed?
        state == :subscribed
      end

      # @return [Boolean] true if pending subscription confirmation
      def pending?
        state == :pending
      end

      # @return [Boolean] true if unsubscribed
      def unsubscribed?
        state == :unsubscribed
      end

      # @return [Boolean] true if in error state
      def error?
        state == :error
      end

      # Build the subscription message to send to the server
      # @return [Hash]
      def to_subscribe_message
        msg = {
          op: "subscribe",
          requestId: request_id,
          query: {
            className: class_name,
            where: query,
          },
        }

        msg[:query][:fields] = fields if fields&.any?
        msg[:sessionToken] = session_token if session_token

        msg
      end

      # Build the unsubscribe message
      # @return [Hash]
      def to_unsubscribe_message
        {
          op: "unsubscribe",
          requestId: request_id,
        }
      end

      # Handle an incoming event from the server
      # @param event [Parse::LiveQuery::Event]
      # @api private
      def handle_event(event)
        Logging.debug("Handling event",
                      request_id: @request_id,
                      event_type: event.type)
        emit(event.type, event.object, event.original)
      end

      # Mark subscription as confirmed by server
      # @api private
      def confirm!
        @monitor.synchronize { @state = :subscribed }
        Logging.info("Subscription confirmed",
                     request_id: @request_id,
                     class_name: @class_name)
        emit(:subscribe)
      end

      # Mark subscription as failed with error
      # @param error [Exception, String]
      # @api private
      def fail!(error)
        @monitor.synchronize { @state = :error }
        error = SubscriptionError.new(error) if error.is_a?(String)
        Logging.error("Subscription failed",
                      request_id: @request_id,
                      error: error)
        emit(:error, error)
      end

      # @return [Hash] subscription info as hash
      def to_h
        @monitor.synchronize do
          {
            request_id: request_id,
            class_name: class_name,
            query: query,
            state: @state,
            fields: fields,
          }
        end
      end

      private

      # Emit an event to registered callbacks
      # @param event_type [Symbol]
      # @param args [Array] arguments to pass to callbacks
      def emit(event_type, *args)
        # Copy callbacks under lock, iterate outside to prevent deadlocks
        callbacks = @monitor.synchronize { @callbacks[event_type].dup }

        callbacks.each do |callback|
          begin
            callback.call(*args)
          rescue => e
            # Don't let callback errors break the subscription
            Logging.error("Callback error",
                          request_id: @request_id,
                          event_type: event_type,
                          error: e)
            emit(:error, e) unless event_type == :error
          end
        end
      end

      # Generate a unique request ID (thread-safe)
      # @return [Integer]
      def generate_request_id
        @@id_monitor.synchronize do
          @@request_counter += 1
        end
      end
    end
  end
end
