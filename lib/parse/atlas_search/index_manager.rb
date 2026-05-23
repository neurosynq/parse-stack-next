# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module AtlasSearch
    # Manages Atlas Search index discovery and caching.
    # Uses $listSearchIndexes aggregation stage to discover available indexes.
    #
    # The cache is process-local, time-bounded (default 300 seconds), and
    # protected by a Mutex. Override the TTL via:
    #
    #   Parse::AtlasSearch::IndexManager.cache_ttl = 60  # seconds
    #
    # @example List indexes
    #   indexes = Parse::AtlasSearch::IndexManager.list_indexes("Song")
    #   # => [{"name" => "default", "status" => "READY", ...}]
    #
    # @example Check if index is ready
    #   IndexManager.index_ready?("Song", "song_search")
    #   # => true
    module IndexManager
      # Default cache TTL in seconds. Index definitions rarely change at
      # runtime, but new indexes built via the Atlas UI should become
      # visible without a process restart.
      DEFAULT_CACHE_TTL = 300

      class << self
        # @return [Numeric] the cache TTL in seconds. Set to 0 or negative
        #   to disable caching entirely.
        attr_writer :cache_ttl

        def cache_ttl
          @cache_ttl || DEFAULT_CACHE_TTL
        end

        # List all search indexes for a collection (cached).
        # Uses the $listSearchIndexes aggregation stage.
        #
        # @param collection_name [String] the Parse collection name
        # @param force_refresh [Boolean] bypass cache and fetch fresh data
        # @return [Array<Hash>] array of index definitions with keys:
        #   - id: String - the index ID
        #   - name: String - the index name
        #   - status: String - "READY", "BUILDING", etc.
        #   - queryable: Boolean - whether the index is queryable
        #   - mappings: Hash - field mappings definition
        def list_indexes(collection_name, force_refresh: false)
          if !force_refresh
            cached = cache_mutex.synchronize do
              cached_indexes(collection_name) if cache_valid?(collection_name)
            end
            return cached if cached
          end

          # $listSearchIndexes must be the first and only stage in pipeline
          pipeline = [{ "$listSearchIndexes" => {} }]

          begin
            # `$listSearchIndexes` returns server-side index metadata,
            # not document rows. CLP gates row access ("find") and is
            # not the right gate for "what indexes exist on this
            # collection" — every code path that introspects index
            # state (`Model.describe`, the migrator, `wait_for_ready`)
            # would otherwise refuse under any scoped agent. Pass
            # `master: true` so the SDK's CLP layer skips this metadata
            # pipeline. The mongo-side privilege check still applies
            # (the underlying connection must hold `listSearchIndexes`).
            results = Parse::MongoDB.aggregate(collection_name, pipeline, master: true)
            cache_mutex.synchronize { cache_indexes(collection_name, results) }
            results
          rescue => e
            handle_list_error(e, collection_name)
          end
        end

        # Check if a search index exists for a collection
        # @param collection_name [String] the Parse collection name
        # @param index_name [String] the index name to check
        # @return [Boolean] true if index exists
        def index_exists?(collection_name, index_name)
          indexes = list_indexes(collection_name)
          indexes.any? { |idx| idx["name"] == index_name }
        end

        # Check if a search index exists and is ready to query
        # @param collection_name [String] the Parse collection name
        # @param index_name [String] the index name to check
        # @return [Boolean] true if index exists and is queryable
        def index_ready?(collection_name, index_name)
          indexes = list_indexes(collection_name)
          index = indexes.find { |idx| idx["name"] == index_name }
          index.present? && index["queryable"] == true
        end

        # Get a specific index definition
        # @param collection_name [String] the Parse collection name
        # @param index_name [String] the index name
        # @return [Hash, nil] the index definition or nil if not found
        def get_index(collection_name, index_name)
          indexes = list_indexes(collection_name)
          indexes.find { |idx| idx["name"] == index_name }
        end

        # Validate that an index exists and is ready
        # @param collection_name [String] the Parse collection name
        # @param index_name [String] the index name to validate
        # @raise [IndexNotFound] if the index doesn't exist or isn't ready
        def validate_index!(collection_name, index_name)
          unless index_ready?(collection_name, index_name)
            available = list_indexes(collection_name).map { |i| i["name"] }.join(", ")
            raise IndexNotFound,
              "Atlas Search index '#{index_name}' not found or not ready on collection '#{collection_name}'. " \
              "Available indexes: #{available.presence || "none"}"
          end
        end

        # Create an Atlas Search index on a collection and invalidate the
        # local cache so subsequent {.index_exists?}/{.index_ready?}
        # observations reflect the new index. Thin wrapper over
        # {Parse::MongoDB.create_search_index} — triple-gated, idempotent
        # on name, asynchronous on the Atlas Search node.
        #
        # The build runs in the background. Poll {.index_ready?} to
        # confirm the index has transitioned to `READY` before issuing
        # queries against it.
        #
        # @param collection_name [String] target collection / Parse class
        # @param index_name [String] the search index name
        # @param definition [Hash] the search index definition, e.g.
        #   `{ mappings: { dynamic: true } }` or
        #   `{ mappings: { fields: { title: { type: "string" } } } }`
        # @param allow_system_classes [Boolean] opt-in for Parse-internal
        # @return [Symbol] `:created` on submission, `:exists` if already present
        def create_index(collection_name, index_name, definition, allow_system_classes: false)
          result = Parse::MongoDB.create_search_index(
            collection_name, index_name, definition,
            allow_system_classes: allow_system_classes,
          )
          clear_cache(collection_name)
          result
        end

        # Drop an Atlas Search index by name and invalidate the local
        # cache. Confirm token is `"drop_search:#{collection}:#{name}"`
        # — distinct from {Parse::MongoDB.drop_index}'s `"drop:"` prefix.
        #
        # @param collection_name [String]
        # @param index_name [String]
        # @param confirm [String] must equal `"drop_search:#{collection}:#{index_name}"`
        # @param allow_system_classes [Boolean]
        # @return [Symbol] `:dropped` or `:absent`
        def drop_index(collection_name, index_name, confirm:, allow_system_classes: false)
          result = Parse::MongoDB.drop_search_index(
            collection_name, index_name, confirm: confirm,
            allow_system_classes: allow_system_classes,
          )
          clear_cache(collection_name)
          result
        end

        # Replace the definition of an existing Atlas Search index and
        # invalidate the local cache. The rebuild runs asynchronously;
        # the new mapping is not live until {.index_ready?} returns true
        # again.
        #
        # @param collection_name [String]
        # @param index_name [String]
        # @param definition [Hash] replacement definition
        # @param allow_system_classes [Boolean]
        # @return [Symbol] `:updated`
        def update_index(collection_name, index_name, definition, allow_system_classes: false)
          result = Parse::MongoDB.update_search_index(
            collection_name, index_name, definition,
            allow_system_classes: allow_system_classes,
          )
          clear_cache(collection_name)
          result
        end

        # Block until a search index reaches `READY` (queryable) status,
        # the build fails, or the timeout elapses. Bypasses the
        # IndexManager's 300-second cache via `force_refresh: true` on
        # every poll — naive callers using `until index_ready?; sleep`
        # cache the `BUILDING` state for the full TTL and never see the
        # transition to `READY`. This helper is the correct path.
        #
        # **Resilience to transient connectivity loss.** Atlas Local's
        # internal supervisor periodically restarts `mongod` (5-10s
        # outage windows during replica-set sync events). If a poll
        # lands in a restart window, the underlying `$listSearchIndexes`
        # call raises `Mongo::Error::NoServerAvailable` (or surfaces it
        # via `Parse::AtlasSearch::NotAvailable`). The poll treats those
        # as transient and continues until the deadline — only the
        # final deadline-elapsed condition produces `:timeout`. A non-
        # transient error (e.g. an Atlas-side `FAILED` status surfaced
        # through some other exception class) still raises out.
        #
        # @param collection_name [String]
        # @param index_name [String]
        # @param timeout [Numeric] seconds to wait before returning
        #   `:timeout`. Default 600 (10 minutes).
        # @param interval [Numeric] seconds between polls. Default 5.
        # @return [Symbol] `:ready` once the index is queryable,
        #   `:failed` when the index reports a `FAILED` status,
        #   `:timeout` when the deadline elapses without either.
        def wait_for_ready(collection_name, index_name, timeout: 600, interval: 5)
          deadline = Time.now + timeout
          # Cap consecutive transient failures. The intent of the
          # resilience is to bridge a single mongod-restart window
          # (5-10s); a sustained failure of 25+ seconds is a real outage,
          # not a restart, and should raise rather than loop until the
          # caller's full timeout elapses (which can be 10+ minutes for
          # large-build callers).
          #
          # `interval <= 0` is a unit-test affordance (tests stub `sleep`
          # to a no-op and pass `interval: 0` so the suite isn't paced by
          # real wall-clock waits). Dividing 25.0 by zero produces
          # Infinity, and `Float#ceil` on Infinity raises
          # `FloatDomainError`, so guard the divisor with a small
          # positive epsilon. The clamp upper bound (12) is what the
          # formula resolves to in that case, which is the right answer
          # — with no inter-poll delay, the consecutive-failure counter
          # is the only thing bounding the loop, and the upper bound is
          # the most permissive setting.
          divisor = interval > 0 ? interval.to_f : 0.001
          max_consecutive_transient = (25.0 / divisor).ceil.clamp(3, 12)
          consecutive_transient = 0
          last_transient = nil
          loop do
            indexes = begin
                last_transient = nil
                list_indexes(collection_name, force_refresh: true)
              rescue Parse::AtlasSearch::NotAvailable, StandardError => e
                raise unless transient_poll_error?(e)
                last_transient = e
                nil
              end
            if indexes
              consecutive_transient = 0
              idx = indexes.find { |i| (i["name"] || i[:name]).to_s == index_name.to_s }
              if idx
                return :ready if idx["queryable"] == true
                status = (idx["status"] || idx[:status]).to_s.upcase
                return :failed if status == "FAILED"
              end
            else
              consecutive_transient += 1
              if consecutive_transient >= max_consecutive_transient
                raise last_transient
              end
            end
            return :timeout if Time.now >= deadline
            sleep interval
          end
        end

        # Clear the index cache
        # @param collection_name [String, nil] specific collection to clear, or nil for all
        def clear_cache(collection_name = nil)
          cache_mutex.synchronize do
            if collection_name
              index_cache.delete(collection_name)
            else
              @index_cache = {}
            end
          end
        end

        private

        # Class names (string-matched to avoid hard-requiring the mongo gem
        # in environments where Atlas Search isn't used) and error-message
        # substrings that indicate a transient connectivity loss: typically
        # mongodb-atlas-local's supervisor cycling `mongod` for replica-set
        # sync. wait_for_ready treats these as "keep polling" rather than
        # propagating. Real errors (auth, permission, programmer bugs) fall
        # through and raise.
        TRANSIENT_POLL_ERROR_CLASS_NAMES = %w[
          Mongo::Error::NoServerAvailable
          Mongo::Error::SocketError
          Mongo::Error::SocketTimeoutError
          Mongo::Error::ServerSelectionError
          Parse::AtlasSearch::NotAvailable
        ].to_set.freeze
        private_constant :TRANSIENT_POLL_ERROR_CLASS_NAMES

        TRANSIENT_POLL_ERROR_MESSAGE_FRAGMENTS = [
          "no primary",
          "connection refused",
          "not available",
          "host unreachable",
          "no server",
          "could not connect",
        ].freeze
        private_constant :TRANSIENT_POLL_ERROR_MESSAGE_FRAGMENTS

        def transient_poll_error?(err)
          return true if TRANSIENT_POLL_ERROR_CLASS_NAMES.include?(err.class.name)
          msg = err.message.to_s.downcase
          TRANSIENT_POLL_ERROR_MESSAGE_FRAGMENTS.any? { |fragment| msg.include?(fragment) }
        end

        # Mutex protecting @index_cache. Initialized lazily but the
        # initialization itself is guarded by a class-level mutex created at
        # load time, so two threads can't race on first access.
        CACHE_MUTEX_INIT = Mutex.new
        private_constant :CACHE_MUTEX_INIT

        def cache_mutex
          @cache_mutex ||= CACHE_MUTEX_INIT.synchronize { @cache_mutex ||= Mutex.new }
        end

        def index_cache
          @index_cache ||= {}
        end

        def cached_indexes(collection_name)
          index_cache.dig(collection_name, :indexes) || []
        end

        def cache_valid?(collection_name)
          entry = index_cache[collection_name]
          return false unless entry
          ttl = cache_ttl
          return false if ttl <= 0
          (Time.now - entry[:cached_at]) < ttl
        end

        def cache_indexes(collection_name, indexes)
          index_cache[collection_name] = {
            indexes: indexes,
            cached_at: Time.now,
          }
        end

        def handle_list_error(error, collection_name)
          msg = error.message.to_s.downcase
          if msg.include?("not available") ||
             msg.include?("atlas") ||
             msg.include?("command not found") ||
             msg.include?("unrecognized") ||
             msg.include?("not supported")
            raise NotAvailable,
              "Atlas Search is not available for collection '#{collection_name}'. " \
              "Ensure you're using MongoDB Atlas with Search enabled, or a local Atlas deployment. " \
              "Original error: #{error.message}"
          end
          raise error
        end
      end
    end
  end
end
