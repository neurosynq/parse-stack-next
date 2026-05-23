# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module API
    # Defines the Analytics interface for the Parse REST API
    module Analytics

      # Send analytics data. Parse Server's default `analyticsAdapter`
      # is a no-op: events POSTed here are accepted but not persisted
      # and cannot be read back through Parse Server. Operators who wire
      # in a custom adapter decide what (if anything) to do with each
      # event, including whether to cap dimension count — the legacy
      # parse.com eight-pair cap does NOT apply to Parse Server out of
      # the box. If you need to read events back, persist them to a
      # regular `Parse::Object` subclass instead.
      #
      # @param event_name [String] the name of the event. Restricted to
      #   word characters, hyphens, and dots so the value cannot escape
      #   the `/events/` path segment.
      # @param metrics [Hash] dimension pairs to attach to the event.
      # @param opts [Hash] additional options forwarded to {Parse::Client#request}
      #   (e.g. :session_token, :use_master_key). Analytics events are
      #   typically public-writable, but a session token can be threaded
      #   through for installations that require authentication on /events.
      # @raise [ArgumentError] when `event_name` is empty or contains
      #   characters outside `[\w\-\.]`.
      # @see http://docs.parseplatform.org/rest/guide/#analytics Parse Analytics
      def send_analytics(event_name, metrics = {}, **opts)
        safe = event_name.to_s
        unless safe.match?(/\A[\w\-\.]+\z/)
          raise ArgumentError,
                "Parse::API::Analytics#send_analytics: event_name must contain only " \
                "word characters, hyphens, or dots (got #{event_name.inspect})"
        end
        request :post, "events/#{safe}", body: metrics, opts: opts
      end
    end
  end
end
