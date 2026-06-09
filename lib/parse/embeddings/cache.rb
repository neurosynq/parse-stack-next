# encoding: UTF-8
# frozen_string_literal: true

require "digest"
require "monitor"

module Parse
  module Embeddings
    # Process-local embedding cache keyed by
    # `(provider, model, input_type, input_hash)`.
    #
    # Query-side embedding is the hot repeat path: the same natural-
    # language query (an agent retrying a tool call, a user paging
    # through results, a dashboard refreshing) re-embeds identical text
    # on every call, paying provider latency and per-token cost each
    # time. The cache short-circuits those repeats. Write-side managed
    # embeds (`embed` / `embed_image` save callbacks) already have their
    # own digest-tracked elision and do not use this cache.
    #
    # == Disabled by default
    #
    # With the cache disabled {.fetch_vector} is a pass-through. Opt in:
    #
    #   Parse::Embeddings::Cache.enable!(max_entries: 2048, ttl: 600)
    #
    # The default store is an in-process LRU with per-entry TTL. A
    # custom store (e.g. Redis-backed) can be supplied via
    # `enable!(store: my_store)` — it must respond to `get(key)`
    # (returning `Array<Float>` or nil) and `set(key, vector)`; TTL
    # management is then the store's responsibility.
    #
    # == Key derivation
    #
    # `provider.class.name | model_name | input_type | SHA-256(input)`.
    # The full input text never becomes part of the key, so a shared
    # external store does not accumulate plaintext queries.
    #
    # == Observability
    #
    # A cache hit emits the same `parse.embeddings.embed` AS::N event a
    # real provider call would, with `cached: true` — existing
    # spend-tracking subscribers see hits and misses on one stream.
    module Cache
      # Internal LRU + TTL store. Access is synchronized by the module-
      # level monitor in {Cache}; the store itself is not thread-safe.
      # @!visibility private
      class LRUStore
        def initialize(max_entries:, ttl:)
          @max_entries = max_entries
          @ttl = ttl
          @entries = {} # key => [vector, monotonic_expiry]
        end

        def get(key)
          entry = @entries[key]
          return nil if entry.nil?
          if @ttl && entry[1] && entry[1] < Cache.monotonic
            @entries.delete(key)
            return nil
          end
          # Refresh recency (Hash preserves insertion order).
          @entries.delete(key)
          @entries[key] = entry
          entry[0]
        end

        def set(key, vector)
          @entries.delete(key)
          expiry = @ttl ? Cache.monotonic + @ttl : nil
          @entries[key] = [vector, expiry]
          @entries.shift while @entries.length > @max_entries
          vector
        end

        def size
          @entries.length
        end

        def clear
          @entries = {}
        end
      end

      # Adapter exposing any Moneta-compatible key/value store (`[]` /
      # `[]=`, optionally `store(key, value, expires:)`) through the
      # `get`/`set` duck {Cache.enable!} expects — the persistent-L2
      # option. Point it at the same Redis your `Parse.cache` uses and
      # query-embed cache entries survive process restarts and are
      # shared across processes:
      #
      #   require "moneta"
      #   moneta = Moneta.new(:Redis, url: ENV["REDIS_URL"])
      #   Parse::Embeddings::Cache.enable!(
      #     store: Parse::Embeddings::Cache::MonetaStore.new(moneta, ttl: 30 * 24 * 3600),
      #   )
      #
      # Keys are namespaced (`emb:` by default) so the entries are
      # recognizable next to other application keys; values are the
      # raw vector Arrays (Moneta's own serializer handles encoding).
      # TTL is forwarded via Moneta's `expires:` option when the
      # backend supports it, ignored otherwise.
      #
      # Fail-open by design: a backend error (Redis down, serialization
      # hiccup) degrades to a cache miss / dropped write — the embed
      # path must never fail because the CACHE is unhealthy.
      #
      # The cross-process race the in-process LRU doesn't have applies
      # here: two processes missing the same key concurrently both call
      # the provider and both write. That is correct (embeddings are
      # deterministic per key) and bounded — no locking is attempted.
      class MonetaStore
        # @param moneta [#[], #[]=] a Moneta store (or anything with the
        #   same indexing duck).
        # @param ttl [Numeric, nil] per-entry lifetime in seconds,
        #   forwarded as `expires:` when the backend supports
        #   `store(key, value, expires:)`. nil = no expiry.
        # @param namespace [String] key prefix.
        def initialize(moneta, ttl: nil, namespace: "emb:")
          unless moneta.respond_to?(:[]) && moneta.respond_to?(:[]=)
            raise ArgumentError,
                  "Parse::Embeddings::Cache::MonetaStore expects a Moneta-compatible " \
                  "store responding to #[] and #[]= (got #{moneta.class})."
          end
          @moneta = moneta
          @ttl = ttl && Float(ttl)
          @namespace = namespace.to_s
        end

        # @return [Array<Float>, nil]
        def get(key)
          value = @moneta[@namespace + key]
          value.is_a?(Array) ? value : nil
        rescue StandardError
          nil
        end

        # @return [Array<Float>] the vector, unchanged.
        def set(key, vector)
          k = @namespace + key
          if @ttl && @moneta.respond_to?(:store)
            begin
              @moneta.store(k, vector, expires: @ttl)
            rescue ArgumentError
              # Hash-like backends define #store(key, value) with no
              # options arg, so the expires: form raises ArgumentError.
              # Fall back to a plain write (no expiry) rather than letting
              # the fail-open rescue below silently drop every vector.
              @moneta[k] = vector
            end
          else
            @moneta[k] = vector
          end
          vector
        rescue StandardError
          vector
        end
      end

      MONITOR = Monitor.new
      private_constant :MONITOR

      class << self
        # Enable the cache.
        #
        # @param max_entries [Integer] LRU capacity (default store only).
        # @param ttl [Numeric, nil] per-entry lifetime in seconds; nil
        #   disables expiry (default store only). Default 600.
        # @param store [#get, #set, nil] custom backing store; overrides
        #   the built-in LRU when given.
        # @return [void]
        def enable!(max_entries: 2048, ttl: 600, store: nil)
          if store && !(store.respond_to?(:get) && store.respond_to?(:set))
            raise ArgumentError,
                  "Parse::Embeddings::Cache.enable!: store must respond to #get and #set."
          end
          me = Integer(max_entries)
          raise ArgumentError, "max_entries must be positive" if me <= 0
          MONITOR.synchronize do
            @store = store || LRUStore.new(max_entries: me, ttl: ttl && Float(ttl))
            @enabled = true
            @hits = 0
            @misses = 0
          end
          nil
        end

        # Disable and drop the store.
        # @return [void]
        def disable!
          MONITOR.synchronize do
            @enabled = false
            @store = nil
          end
          nil
        end

        # @return [Boolean]
        def enabled?
          MONITOR.synchronize { !!@enabled }
        end

        # Clear cached entries (default store) and reset hit/miss counters.
        # @return [void]
        def clear!
          MONITOR.synchronize do
            @store.clear if @store.respond_to?(:clear)
            @hits = 0
            @misses = 0
          end
          nil
        end

        # @return [Hash] `{ enabled:, hits:, misses:, size: }`. `size` is
        #   nil for custom stores that don't expose one.
        def stats
          MONITOR.synchronize do
            {
              enabled: !!@enabled,
              hits: @hits.to_i,
              misses: @misses.to_i,
              size: (@store.respond_to?(:size) ? @store.size : nil),
            }
          end
        end

        # Embed a single input through `provider`, serving repeats from
        # the cache. Pass-through (no caching, no instrumentation
        # changes) when the cache is disabled.
        #
        # @param provider [Provider] the embedding provider.
        # @param input [String] the text to embed.
        # @param input_type [Symbol] forwarded to `embed_text`.
        # @return [Array<Float>] the embedding vector.
        def fetch_vector(provider, input, input_type: :search_query)
          unless enabled?
            return embed_single!(provider, input, input_type)
          end
          key = key_for(provider, input, input_type)
          cached = MONITOR.synchronize { @store && @store.get(key) }
          if cached
            MONITOR.synchronize { @hits = @hits.to_i + 1 }
            instrument_hit(provider, input_type)
            return cached
          end
          vector = embed_single!(provider, input, input_type)
          MONITOR.synchronize do
            @misses = @misses.to_i + 1
            @store.set(key, vector) if @store
          end
          vector
        end

        # @!visibility private
        # Composite cache key. The input is hashed so plaintext never
        # lands in a shared store; provider identity + model + dimensions
        # + input_type namespace the hash (two models' vectors are never
        # confused). Dimensions matter independently of the model name:
        # Matryoshka-capable providers (OpenAI text-embedding-3-*, Cohere
        # embed-v4, Voyage, Jina, Qwen) can register the same model at
        # different output widths, and serving one width's cached vector
        # to the other poisons the narrower/wider field.
        def key_for(provider, input, input_type)
          model = begin
            provider.model_name
          rescue NotImplementedError
            "unknown"
          end
          dims = begin
            provider.dimensions
          rescue NotImplementedError
            "unknown"
          end
          "#{provider.class.name}|#{model}|#{dims}|#{input_type}|#{Digest::SHA256.hexdigest(input.to_s)}"
        end

        # @!visibility private
        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        private

        def embed_single!(provider, input, input_type)
          vectors = provider.embed_text([input], input_type: input_type)
          unless vectors.is_a?(Array) && vectors.length == 1 && vectors.first.is_a?(Array)
            raise InvalidResponseError,
                  "Parse::Embeddings::Cache: provider #{provider.class} did not return a " \
                  "single vector (got #{vectors.inspect[0, 80]})."
          end
          vectors.first
        end

        # Emit the standard embed event so spend subscribers see cache
        # hits on the same stream as real calls.
        def instrument_hit(provider, input_type)
          return unless defined?(ActiveSupport::Notifications)
          model = begin
            provider.model_name
          rescue NotImplementedError
            nil
          end
          dims = begin
            provider.dimensions
          rescue NotImplementedError
            nil
          end
          payload = {
            provider: provider.class.name,
            model: model,
            dimensions: dims,
            input_count: 1,
            input_type: input_type,
            total_tokens: nil,
            cached: true,
            error: nil,
          }
          ActiveSupport::Notifications.instrument(Provider::AS_NOTIFICATION_NAME, payload) {}
        end
      end
    end
  end
end
