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
    # static `X-Parse-Webhook-Key` header. A captured POST is therefore
    # indefinitely replayable -- a Ruby-initiated save bearing an `_RB_`
    # request id will continue to suppress server-side after_* callbacks
    # every time it is replayed, and a generic trigger payload can be
    # delivered repeatedly to fire double-charges or other side effects.
    #
    # This module adds two layers on top of the existing static-key check:
    #
    # 1. **Nonce-keyed dedup.** When a delivery carries a per-delivery
    #    identifier (an `X-Parse-Request-Id` or `X-Parse-Webhook-Nonce`
    #    header), a bounded LRU records a SHA-256 of that identifier joined
    #    with the request body. A duplicate seen within
    #    `replay_window_seconds` is rejected with
    #    `"Webhook replay detected."`.
    #
    #    Parse Server sends neither header on its webhook deliveries, so for
    #    a stock deployment this layer is inactive. It deliberately does NOT
    #    fall back to the body alone: two legitimate calls with identical
    #    bodies (the same function called twice with the same params, the
    #    same find run twice) are indistinguishable from a replay by body,
    #    and rejecting them breaks correct traffic.
    #
    # 2. **Opt-in HMAC freshness verification.** When a `signing_secret` is
    #    configured (programmatically or via
    #    `PARSE_WEBHOOK_SIGNING_SECRET`) the dispatcher requires two extra
    #    headers on every request:
    #
    #    * `X-Parse-Webhook-Timestamp` -- decimal Unix epoch seconds.
    #    * `X-Parse-Webhook-Signature` -- hex-encoded HMAC-SHA256 of the
    #      bytes `"#{timestamp}.#{body}"` keyed with the signing secret.
    #
    #    Requests outside `signing_max_skew_seconds` (default 300) or with
    #    an invalid signature are rejected. This bounds a replay to the skew
    #    window; adding an `X-Parse-Webhook-Nonce` header as well closes that
    #    window through layer 1.
    #
    # Operators wanting either layer must arrange for these headers to be
    # added. Parse Server does not natively sign webhook deliveries or tag
    # them with a nonce, so this is typically done with a thin Cloud Code
    # wrapper or an egress proxy.
    module ReplayProtection
      # @!visibility private
      HEADER_TIMESTAMP = "HTTP_X_PARSE_WEBHOOK_TIMESTAMP"
      # @!visibility private
      HEADER_SIGNATURE = "HTTP_X_PARSE_WEBHOOK_SIGNATURE"
      # @!visibility private
      HEADER_NONCE = "HTTP_X_PARSE_WEBHOOK_NONCE"
      # @!visibility private
      DEFAULT_REPLAY_WINDOW = 300
      # @!visibility private
      DEFAULT_REPLAY_CACHE_SIZE = 10_000
      # @!visibility private
      DEFAULT_MAX_SKEW = 300

      class << self
        attr_writer :signing_secret, :signing_max_skew_seconds,
                    :replay_window_seconds, :replay_cache_size

        # Shared HMAC secret used to verify `X-Parse-Webhook-Signature`.
        # When nil/empty, signature verification is skipped (layer 1 still
        # applies). Defaults to `ENV["PARSE_WEBHOOK_SIGNING_SECRET"]`.
        def signing_secret
          return @signing_secret if defined?(@signing_secret) && !@signing_secret.nil?
          ENV["PARSE_WEBHOOK_SIGNING_SECRET"]
        end

        # Maximum allowed clock skew (in seconds) between the timestamp
        # header and the receiver. Requests outside this window are
        # rejected as stale when `signing_secret` is set.
        def signing_max_skew_seconds
          @signing_max_skew_seconds || DEFAULT_MAX_SKEW
        end

        # How long a `(nonce, body)` digest stays in the dedup cache.
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
        # webhook error response. The headers come from `env` so this
        # works with any Rack request. Replay dedup applies only when
        # `request_id` or an `X-Parse-Webhook-Nonce` header is present.
        def verify!(env, body_str, request_id)
          check(env, body_str, request_id).first
        end

        # @!visibility private
        # Same checks as {.verify!}, also reporting whether a signature was
        # verified. The signing secret is read once, so the answer always
        # matches the check that ran.
        # @return [Array(String, Boolean)] the error message (nil when the
        #   request passes) and true when it carried a valid signature.
        def check(env, body_str, request_id)
          secret = signing_secret
          signed_key = nil
          if secret && !secret.empty?
            ts_header = env[HEADER_TIMESTAMP].to_s
            sig_header = env[HEADER_SIGNATURE].to_s
            return ["Missing webhook signature.", false] if ts_header.empty? || sig_header.empty?
            return ["Invalid webhook timestamp.", false] unless ts_header =~ /\A-?\d{1,12}\z/
            ts = ts_header.to_i
            skew = (Time.now.to_i - ts).abs
            return ["Stale webhook timestamp.", false] if skew > signing_max_skew_seconds
            # A sender that signs a per-delivery nonce (`ts.nonce.body`) gets a
            # distinct signature for every delivery, so identical bodies sent
            # in the same second are not mistaken for replays. The original
            # `ts.body` form is still accepted.
            delivery_nonce = env[HEADER_NONCE].to_s.strip
            candidates = ["#{ts}.#{body_str}"]
            candidates.unshift("#{ts}.#{delivery_nonce}.#{body_str}") unless delivery_nonce.empty?
            matched = candidates.any? do |material|
              expected = OpenSSL::HMAC.hexdigest("SHA256", secret, material)
              ActiveSupport::SecurityUtils.secure_compare(expected, sig_header)
            end
            return ["Invalid webhook signature.", false] unless matched
            # A signed delivery is deduplicated on its signature, which covers
            # the timestamp and body and cannot be changed without the secret.
            # Keying it on the unsigned nonce would let a captured request be
            # replayed within the timestamp window by altering or dropping
            # that header.
            signed_key = "sig\x1f#{sig_header}"
          end

          if signed_key
            window = [replay_window_seconds, signing_max_skew_seconds * 2].max
            digest = Digest::SHA256.hexdigest(signed_key)
            return ["Webhook replay detected.", false] if cache.seen?(digest, window)
            cache.record(digest, replay_cache_size)
            return [nil, true]
          end

          # Dedup only when the delivery carries a per-delivery identifier.
          # Keying on the body alone rejects legitimate identical requests.
          nonce = request_id.to_s.strip
          nonce = env[HEADER_NONCE].to_s.strip if nonce.empty?
          return [nil, false] if nonce.empty?

          digest = Digest::SHA256.hexdigest("#{nonce}\x1f#{body_str}")
          if cache.seen?(digest, replay_window_seconds)
            return ["Webhook replay detected.", false]
          end
          cache.record(digest, replay_cache_size)
          [nil, false]
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
