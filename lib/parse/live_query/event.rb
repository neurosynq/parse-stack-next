# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module LiveQuery
    # Represents an event received from the LiveQuery server.
    # Events are emitted when objects matching a subscription's query are
    # created, updated, deleted, or enter/leave the query results.
    #
    # @example
    #   subscription.on(:update) do |event|
    #     puts "Object updated: #{event.object.id}"
    #     puts "Original state: #{event.original&.to_h}"
    #     puts "Event type: #{event.type}"
    #   end
    #
    class Event
      # @return [Symbol] the type of event (:create, :update, :delete, :enter, :leave)
      attr_reader :type

      # @return [Parse::Object] the object affected by this event (current state)
      attr_reader :object

      # @return [Parse::Object, nil] the original state of the object (for :update, :enter, :leave)
      attr_reader :original

      # @return [Integer] the subscription request ID this event belongs to
      attr_reader :request_id

      # @return [String] the Parse class name
      attr_reader :class_name

      # @return [Time] when the event was received
      attr_reader :received_at

      # @return [Hash] raw payload from the server
      attr_reader :raw

      # Classes whose LiveQuery payloads have credential fields removed.
      CREDENTIAL_CLASSES = %w[_User _Session].freeze

      # Payload keys removed from `_User` / `_Session` objects. Parse Server
      # releases without the fix for GHSA-349r could deliver another user's
      # `_User` / `_Session` events, `sessionToken` included, to an `$or`
      # subscription. Removing these before hydration keeps a bearer token
      # (or a linked-account credential) out of callbacks, logs, and
      # {#raw} even against such a server.
      CREDENTIAL_KEYS = %w[sessionToken authData _session_token _hashed_password _auth_data].freeze

      # Prefix for per-provider auth-data storage columns.
      CREDENTIAL_KEY_PREFIX = "_auth_data_"

      class << self
        # Remove credential keys from an object payload when it belongs to
        # `_User` or `_Session` (by its own `className` or by `class_name`).
        # Returns a copy; other payloads are returned unchanged.
        #
        # @param data [Hash, Object] object payload from the server.
        # @param class_name [String, nil] the subscription's class.
        # @return [Hash, Object]
        def scrub_credentials(data, class_name = nil)
          return data unless data.is_a?(Hash)
          own = data["className"] || data[:className]
          return data unless CREDENTIAL_CLASSES.include?(own.to_s) || CREDENTIAL_CLASSES.include?(class_name.to_s)
          data.reject do |key, _|
            k = key.to_s
            CREDENTIAL_KEYS.include?(k) || k.start_with?(CREDENTIAL_KEY_PREFIX)
          end
        end

        # Scrub the `object` and `original` payloads of a whole server
        # message. Returns a copy when anything changed.
        #
        # @param message [Hash]
        # @param class_name [String, nil]
        # @return [Hash]
        def scrub_message(message, class_name = nil)
          return message unless message.is_a?(Hash)
          scrubbed = message.dup
          %w[object original].each do |key|
            next unless scrubbed.key?(key)
            scrubbed[key] = scrub_credentials(scrubbed[key], class_name)
          end
          scrubbed
        end
      end

      # Create a new Event from a LiveQuery server message
      # @param type [Symbol] event type
      # @param class_name [String] Parse class name
      # @param object_data [Hash] object data from server
      # @param original_data [Hash, nil] original object data (for update/enter/leave)
      # @param request_id [Integer] subscription request ID
      # @param raw [Hash] raw server payload
      def initialize(type:, class_name:, object_data:, original_data: nil, request_id:, raw: {})
        @type = type.to_sym
        @class_name = class_name
        @request_id = request_id
        @received_at = Time.now
        @raw = self.class.scrub_message(raw, class_name)

        # Credential fields of `_User` / `_Session` objects are removed
        # before hydration (see {CREDENTIAL_KEYS}).
        object_data = self.class.scrub_credentials(object_data, class_name)
        original_data = self.class.scrub_credentials(original_data, class_name)

        # Convert object data to Parse::Object instances
        @object = build_object(class_name, object_data) if object_data
        @original = build_object(class_name, original_data) if original_data
      end

      # @return [Boolean] true if this is a create event
      def create?
        type == :create
      end

      # @return [Boolean] true if this is an update event
      def update?
        type == :update
      end

      # @return [Boolean] true if this is a delete event
      def delete?
        type == :delete
      end

      # @return [Boolean] true if this is an enter event (object now matches query)
      def enter?
        type == :enter
      end

      # @return [Boolean] true if this is a leave event (object no longer matches query)
      def leave?
        type == :leave
      end

      # @return [String] the Parse object ID
      def parse_object_id
        object&.id
      end

      # @return [Hash] event as a hash
      def to_h
        {
          type: type,
          class_name: class_name,
          object_id: parse_object_id,
          request_id: request_id,
          received_at: received_at,
          object: object&.as_json,
          original: original&.as_json,
        }
      end

      private

      # Build a Parse::Object from hash data
      # @param class_name [String] Parse class name
      # @param data [Hash] object attributes
      # @return [Parse::Object]
      def build_object(class_name, data)
        return nil unless data.is_a?(Hash)

        # Use Parse::Object.build which handles class lookup and data application
        Parse::Object.build(data, class_name)
      end
    end
  end
end
