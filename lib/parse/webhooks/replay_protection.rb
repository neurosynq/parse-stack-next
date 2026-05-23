# encoding: UTF-8
# frozen_string_literal: true

require "digest"
require "openssl"
require "monitor"
require "active_support/security_utils"

module Parse
  class Webhooks
    # NEW-EXT-4: webhook freshness and replay protection.
    #
    # Parse Server's default webhook delivery is authenticated only by the
    # static +X-Parse-Webhook-Key+ header. A captured POST is therefore
    # indefinitely replayable -- a Ruby-initiated save bearing an +_RB_+
    # request id will continue to suppress server-side after_* callbacks
    # every time it is replayed, and a generic trigger payload can be
    # delivered repeatedly to fire double-charges or other side effects.
    #
    # This module adds two layers on top of the existing static-key check:
    #
    # 1. **Always-on body+request-id dedup.** A bounded LRU records a
    #    SHA-256 of +(request_id || "")+ joined with the request body. A
    #    duplicate seen within +replay_window_seconds+ is rejected with
    #    +"Webhook replay detected."+. Cooperation with Parse Server is not
    #    required; this protects against in-window replays only, but those
    #    are the cheapest attack to mount (proxy retries, captured fast
    #    loops, retransmits).
    #
    # 2. **Opt-in HMAC freshness verification.** When a +signing_secret+ is
    #    configured (programmatically or via
    #    +PARSE_WEBHOOK_SIGNING_SECRET+) the dispatcher requires two extra
    #    headers on every request:
    #
    #    * +X-Parse-Webhook-Timestamp+ -- decimal Unix epoch seconds.
    #    * +X-Parse-Webhook-Signature+ -- hex-encoded HMAC-SHA256 of the
    #      bytes +"#{timestamp}.#{body}"+ keyed with the signing secret.
    #
    #    Requests outside +signing_max_skew_seconds+ (default 300) or with
    #    an invalid signature are rejected. Once enabled, this gives full
    #    binding between the body and the time of delivery and closes the
    #    replay window beyond the freshness skew.
    #
    # Operators wanting layer 2 must arrange for Parse Server to add these
    # headers. Parse Server does not natively sign webhook deliveries, so
    # this is typically done with a thin Cloud Code wrapper or an egress
    # proxy. Until enabled, layer 1 still applies.
    module ReplayProtection
      # @!visibility private
      HEADER_TIMESTAMP = "HTTP_X_PARSE_WEBHOOK_TIMESTAMP"
      # @!visibility private
      HEADER_SIGNATURE = "HTTP_X_PARSE_WEBHOOK_SIGNATURE"
      # @!visibility private
      DEFAULT_REPLAY_WINDOW = 300
      # @!visibility private
      DEFAULT_REPLAY_CACHE_SIZE = 10_000
      # @!visibility private
      DEFAULT_MAX_SKEW = 300

      class << self
        attr_writer :signing_secret, :signing_max_skew_seconds,
                    :replay_window_seconds, :replay_cache_size

        # Shared HMAC secret used to verify +X-Parse-Webhook-Signature+.
        # When nil/empty, signature verification is skipped (layer 1 still
        # applies). Defaults to +ENV["PARSE_WEBHOOK_SIGNING_SECRET"]+.
        def signing_secret
          return @signing_secret if defined?(@signing_secret) && !@signing_secret.nil?
          ENV["PARSE_WEBHOOK_SIGNING_SECRET"]
        end

        # Maximum allowed clock skew (in seconds) between the timestamp
        # header and the receiver. Requests outside this window are
        # rejected as stale when +signing_secret+ is set.
        def signing_max_skew_seconds
          @signing_max_skew_seconds || DEFAULT_MAX_SKEW
        end

        # How long a +(request_id, body)+ digest stays in the dedup cache.
        # Duplicates seen within this window are rejected.
        def replay_window_seconds
          @replay_window_seconds || DEFAULT_REPLAY_WINDOW
        end

        # Maximum number of entries retained in the dedup LRU. Older
        # entries are evicted to keep memory bounded.
        def replay_cache_size
          @replay_cache_size || DEFAULT_REPLAY_CACHE_SIZE
        end

        # Reset all configuration (intended for tests).
        # @!visibility private
        def reset!
          @signing_secret = nil
          @signing_max_skew_seconds = nil
          @replay_window_seconds = nil
          @replay_cache_size = nil
          @cache = nil
        end

        # Clear the dedup cache (intended for tests).
        # @!visibility private
        def clear_cache!
          cache.clear
        end

        # @!visibility private
        def cache
          @cache ||= LruCache.new
        end

        # @!visibility private
        # Returns nil when the request passes both replay and signature
        # checks; otherwise returns a short error string suitable for the
        # webhook error response. The headers come from +env+ so this
        # works with any Rack request.
        def verify!(env, body_str, request_id)
          secret = signing_secret
          if secret && !secret.empty?
            ts_header = env[HEADER_TIMESTAMP].to_s
            sig_header = env[HEADER_SIGNATURE].to_s
            return "Missing webhook signature." if ts_header.empty? || sig_header.empty?
            return "Invalid webhook timestamp." unless ts_header =~ /\A-?\d{1,12}\z/
            ts = ts_header.to_i
            skew = (Time.now.to_i - ts).abs
            return "Stale webhook timestamp." if skew > signing_max_skew_seconds
            expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{ts}.#{body_str}")
            unless ActiveSupport::SecurityUtils.secure_compare(expected, sig_header)
              return "Invalid webhook signature."
            end
          end

          digest = Digest::SHA256.hexdigest("#{request_id}\x1f#{body_str}")
          if cache.seen?(digest, replay_window_seconds)
            return "Webhook replay detected."
          end
          cache.record(digest, replay_cache_size)
          nil
        end
      end

      # Bounded, thread-safe LRU keyed on a digest string with per-entry
      # insertion timestamps. Used only by ReplayProtection; intentionally
      # private to avoid leaking another caching primitive into the public
      # API. Ruby Hashes preserve insertion order, so a delete+insert on
      # touch is enough to maintain LRU ordering.
      class LruCache
        include MonitorMixin

        def initialize
          super()
          @entries = {}
        end

        def seen?(key, window_seconds)
          synchronize do
            ts = @entries[key]
            return false unless ts
            if Time.now.to_i - ts > window_seconds
              @entries.delete(key)
              return false
            end
            @entries.delete(key)
            @entries[key] = ts # touch
            true
          end
        end

        def record(key, max_size)
          synchronize do
            @entries.delete(key)
            @entries[key] = Time.now.to_i
            while @entries.size > max_size
              @entries.shift
            end
          end
        end

        def clear
          synchronize { @entries.clear }
        end

        def size
          synchronize { @entries.size }
        end
      end
    end
  end
end
