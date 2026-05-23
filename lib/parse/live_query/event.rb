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
        @raw = raw

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
