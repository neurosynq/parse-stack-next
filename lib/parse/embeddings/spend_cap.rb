# encoding: UTF-8
# frozen_string_literal: true

require "thread"

module Parse
  module Embeddings
    # Per-tenant cumulative embedding spend cap.
    #
    # The agent `semantic_search` tool embeds attacker-controlled text
    # (chat queries) on every call. Without a cap, a tenant — or an
    # adversary driving an agent — can run up unbounded embedding-provider
    # cost. {SpendCap} tracks the cumulative number of *tokens* embedded
    # per tenant inside a sliding time window and HARD-REFUSES (raises
    # {Exceeded}) once a tenant would exceed its limit. This is distinct
    # from {Parse::Agent::RateLimiter}, which bounds request *count* per
    # window; the spend cap bounds embedding *volume* (a proxy for cost).
    #
    # == Disabled by default
    #
    # With no configured limit the cap is a no-op — {.charge!} records
    # nothing and never raises. Operators opt in:
    #
    #   Parse::Embeddings::SpendCap.configure(limit_tokens: 1_000_000, window: 3600)
    #   Parse::Embeddings::SpendCap.configure(:acme_tenant, limit_tokens: 50_000)
    #
    # A per-tenant limit (second form) overrides the default for that
    # tenant. The reserved key {DEFAULT_KEY} sets the fallback applied to
    # every tenant without an explicit limit.
    #
    # == Token estimation
    #
    # Callers pass an explicit token count, or use {.estimate_tokens} (a
    # chars/4 heuristic — the same approximation the agent layer uses for
    # its context-token budgets). The cap is intentionally an estimate: it
    # exists to bound runaway cost, not to bill precisely.
    #
    # Thread-safe: all state lives behind a single mutex.
    module SpendCap
      # Raised when a tenant would exceed its token cap. Carries the
      # limit, the already-used count (within the window), and a
      # `retry_after` hint (seconds until enough of the window rolls off
      # to admit the rejected charge — `nil` if the charge can never fit).
      class Exceeded < StandardError
        attr_reader :tenant_id, :limit, :used, :requested, :window, :retry_after

        def initialize(tenant_id:, limit:, used:, requested:, window:, retry_after:)
          @tenant_id = tenant_id
          @limit = limit
          @used = used
          @requested = requested
          @window = window
          @retry_after = retry_after
          super(
            "Embedding spend cap exceeded for tenant #{tenant_id.inspect}: " \
            "#{used}+#{requested} tokens would exceed #{limit}/#{window}s." \
            "#{retry_after ? " Retry after #{retry_after.round(1)}s." : " Request exceeds the cap outright."}"
          )
        end
      end

      # Fallback bucket key for charges with no tenant identity, and the
      # key under which {.configure} (with no explicit tenant) sets the
      # default limit applied to every tenant lacking an override.
      DEFAULT_KEY = :__default__

      # Default sliding window (seconds) when none is configured.
      DEFAULT_WINDOW = 3600

      class << self
        # Configure the cap. Two forms:
        #
        #   configure(limit_tokens:, window:)            # default for all tenants
        #   configure(tenant_id, limit_tokens:, window:) # override one tenant
        #
        # `limit_tokens: nil` disables the cap for that scope (the default
        # scope when no tenant is given).
        #
        # @param tenant_id [Object, nil] tenant to override, or nil for
        #   the global default.
        # @param limit_tokens [Integer, nil] token ceiling per window.
        # @param window [Integer] sliding window length in seconds.
        # @return [void]
        def configure(tenant_id = nil, limit_tokens:, window: DEFAULT_WINDOW)
          key = tenant_id.nil? ? DEFAULT_KEY : tenant_id
          unless limit_tokens.nil?
            li = Integer(limit_tokens)
            raise ArgumentError, "SpendCap: limit_tokens must be positive (got #{li})." if li <= 0
          end
          w = Integer(window)
          raise ArgumentError, "SpendCap: window must be positive (got #{w})." if w <= 0
          mutex.synchronize do
            limits[key] = limit_tokens.nil? ? nil : { limit: Integer(limit_tokens), window: w }
          end
          nil
        end

        # Charge `tokens` against `tenant_id`'s budget. HARD-REFUSES by
        # raising {Exceeded} when the charge would push the tenant over
        # its limit within the window; otherwise records the charge and
        # returns the new in-window total.
        #
        # No-op (returns nil) when no limit applies to the tenant.
        #
        # @param tenant_id [Object, nil] tenant identity (nil → {DEFAULT_KEY}).
        # @param tokens [Integer] tokens to charge (>= 0).
        # @return [Integer, nil] new in-window total, or nil if uncapped.
        # @raise [Exceeded]
        def charge!(tenant_id:, tokens:)
          t = Integer(tokens)
          raise ArgumentError, "SpendCap: tokens must be >= 0 (got #{t})." if t.negative?
          key = tenant_id.nil? ? DEFAULT_KEY : tenant_id

          mutex.synchronize do
            cfg = limit_for(key)
            return nil if cfg.nil? # uncapped

            window = cfg[:window]
            limit = cfg[:limit]
            now = monotonic
            entries = prune(key, now, window)
            used = entries.sum { |e| e[1] }

            if used + t > limit
              raise Exceeded.new(
                tenant_id: key, limit: limit, used: used, requested: t,
                window: window, retry_after: retry_after_for(entries, t, limit, window, now),
              )
            end
            entries << [now, t] if t.positive?
            used + t
          end
        end

        # Current in-window token usage for a tenant (0 when uncapped or
        # idle). Does not mutate.
        #
        # @param tenant_id [Object, nil]
        # @return [Integer]
        def usage(tenant_id: nil)
          key = tenant_id.nil? ? DEFAULT_KEY : tenant_id
          mutex.synchronize do
            cfg = limit_for(key)
            return 0 if cfg.nil?
            prune(key, monotonic, cfg[:window]).sum { |e| e[1] }
          end
        end

        # Estimate token count from a String.
        #
        # The familiar "~4 characters per token" ratio only holds for
        # ASCII. CJK, emoji, and other multibyte text run closer to one
        # token per codepoint in a real tokenizer, so a pure
        # `chars / 4` estimate undercounts such input by up to ~4x — and
        # since this estimate is the sole basis for the hard-refuse
        # decision, that lets a caller feeding multibyte text reach ~4x
        # the real embedding volume before the cap trips. Take the larger
        # of the char-based and byte-based estimates so multibyte input
        # bills at least as much as its UTF-8 byte length implies.
        #
        # @param text [String]
        # @return [Integer]
        def estimate_tokens(text)
          str = text.to_s
          chars = (str.length / 4.0).ceil
          bytes = (str.bytesize / 4.0).ceil
          [chars, bytes].max
        end

        # Clear recorded usage (all tenants, or one). Limits are retained.
        #
        # @param tenant_id [Object, nil]
        def reset!(tenant_id = nil)
          mutex.synchronize do
            if tenant_id.nil?
              @buckets = {}
            else
              buckets.delete(tenant_id)
            end
          end
          nil
        end

        # Remove all configured limits AND recorded usage. Mainly for
        # tests — returns the cap to its disabled-by-default state.
        def reset_all!
          mutex.synchronize do
            @limits = {}
            @buckets = {}
          end
          nil
        end

        private

        MUTEX_INIT = Mutex.new
        private_constant :MUTEX_INIT

        def mutex
          @mutex ||= MUTEX_INIT.synchronize { @mutex ||= Mutex.new }
        end

        def limits
          @limits ||= {}
        end

        def buckets
          @buckets ||= {}
        end

        # Resolve the effective limit config for a key: an explicit
        # per-tenant entry wins; otherwise the DEFAULT_KEY entry; nil when
        # neither is set (uncapped). A key explicitly set to nil disables
        # the cap for that tenant even if a default exists.
        def limit_for(key)
          if limits.key?(key)
            limits[key]
          else
            limits[DEFAULT_KEY]
          end
        end

        # Drop entries older than the window; returns the (mutated) live
        # entry list for the key.
        def prune(key, now, window)
          entries = (buckets[key] ||= [])
          cutoff = now - window
          entries.reject! { |e| e[0] <= cutoff }
          entries
        end

        # Seconds until enough in-window tokens roll off to admit a charge
        # of `requested` tokens. nil when the request alone exceeds the
        # limit (it can never fit).
        def retry_after_for(entries, requested, limit, window, now)
          return nil if requested > limit
          need_to_free = (entries.sum { |e| e[1] } + requested) - limit
          return 0.0 if need_to_free <= 0
          freed = 0
          entries.sort_by { |e| e[0] }.each do |ts, tok|
            freed += tok
            if freed >= need_to_free
              return [(ts + window) - now, 0.0].max
            end
          end
          nil
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
