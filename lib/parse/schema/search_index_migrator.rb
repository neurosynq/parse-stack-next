# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Schema
    # Reconciliation engine for {Parse::Core::SearchIndexing} declarations
    # vs. the actual Atlas Search index state. Reads existing indexes via
    # `$listSearchIndexes` (so `plan` works without writer config);
    # applies via the writer connection through
    # {Parse::AtlasSearch::IndexManager.create_index} /
    # {Parse::AtlasSearch::IndexManager.update_index} /
    # {Parse::AtlasSearch::IndexManager.drop_index}.
    #
    # **Drift semantics are detect-and-refuse, not auto-update.** When a
    # declared definition differs from what Atlas reports as the index's
    # `latestDefinition`, the migrator classifies the declaration as
    # `drifted:` and leaves the index alone. The operator opts into the
    # update with `apply!(update: true)`. This matches the spirit of the
    # regular {Parse::Schema::IndexMigrator}'s `conflicts:` slot but with
    # an explicit opt-in escape hatch, because Atlas Search rebuilds run
    # asynchronously and an over-eager auto-update would silently rebuild
    # production indexes on every deploy.
    #
    # **Builds are async.** `apply!(wait: false)` (the default) submits
    # commands and returns immediately. `apply!(wait: true)` blocks on
    # {Parse::AtlasSearch::IndexManager.wait_for_ready} after each
    # create / update to confirm the index transitions to `READY`.
    # CI / deployment pipelines that need post-apply queryability should
    # opt-in; default fire-and-forget keeps the common rake task fast.
    class SearchIndexMigrator
      attr_reader :model_class

      def initialize(model_class)
        unless model_class.is_a?(Class) && model_class < Parse::Object
          raise ArgumentError,
                "SearchIndexMigrator expects a Parse::Object subclass; got #{model_class.inspect}"
        end
        @model_class = model_class
      end

      # @return [String] the model's collection name (parse_class).
      def collection_name
        @model_class.parse_class
      end

      # Compute the plan: what would change if `apply!` ran now.
      #
      # @return [Hash] keys:
      #   - `:collection` — target collection name
      #   - `:declared` — Array of declaration Hashes
      #   - `:existing` — raw `$listSearchIndexes` result for the
      #     collection (or `[]` when Atlas is not available)
      #   - `:to_create` — declarations whose name is absent from
      #     `:existing`. These will be submitted on `apply!`.
      #   - `:in_sync` — declarations whose name exists AND whose
      #     normalized definition matches the existing `latestDefinition`.
      #   - `:drifted` — declarations whose name exists but whose
      #     definition differs from `latestDefinition`. Reported only;
      #     never auto-updated. Each entry is `{ declared:, existing: }`.
      #   - `:orphans` — names of search indexes present on the
      #     collection but not declared. Reported only by default;
      #     dropped under `apply!(drop: true)`.
      #   - `:atlas_available` — false when `$listSearchIndexes` failed
      #     (e.g. running against vanilla Mongo without Atlas Search).
      #     In that case `:existing` is `[]` and every declaration
      #     appears in `:to_create`.
      def plan
        coll = collection_name
        existing, available = fetch_existing_indexes(coll)
        declared = @model_class.mongo_search_index_declarations

        existing_by_name = existing.each_with_object({}) do |idx, h|
          name = (idx["name"] || idx[:name]).to_s
          h[name] = idx unless name.empty?
        end

        to_create = []
        in_sync   = []
        drifted   = []

        declared.each do |decl|
          target = existing_by_name[decl[:name]]
          if target.nil?
            to_create << decl
          elsif definition_matches?(target, decl[:definition])
            in_sync << decl
          else
            drifted << { declared: decl, existing: serialize_existing(target) }
          end
        end

        declared_names = declared.map { |d| d[:name] }.to_set
        orphans = existing_by_name.keys.reject { |name| declared_names.include?(name) }

        {
          collection:      coll,
          declared:        declared,
          existing:        existing,
          atlas_available: available,
          to_create:       to_create,
          in_sync:         in_sync,
          drifted:         drifted,
          orphans:         orphans,
        }
      end

      # Apply the plan. Additive by default — only `:to_create` is
      # mutated. Pass `update: true` to also rebuild drifted indexes,
      # `drop: true` to also drop orphans, `wait: true` to block on
      # build completion after each mutation.
      #
      # @param update [Boolean]
      # @param drop [Boolean]
      # @param wait [Boolean]
      # @param timeout [Integer] wait-per-mutation seconds (when wait: true)
      # @return [Hash] keys:
      #   - `:created` — Array<Hash> of declarations submitted via create
      #   - `:skipped_exists` — declarations the writer-side check found
      #     present at apply time (rare race: plan said to_create, but
      #     someone created the index in the window between plan and
      #     apply)
      #   - `:in_sync` — declarations the plan classified as in_sync
      #     (returned verbatim, no command issued)
      #   - `:updated` — names of indexes rebuilt via update
      #     (`update: true` only)
      #   - `:drifted_skipped` — names of drifted declarations that were
      #     reported but not updated (default `update: false`)
      #   - `:dropped` — names of orphans dropped (`drop: true` only)
      #   - `:orphans_skipped` — names of orphans reported but not
      #     dropped (default `drop: false`)
      #   - `:wait_results` — Hash{name => :ready|:failed|:timeout} when
      #     `wait: true`; empty otherwise.
      def apply!(update: false, drop: false, wait: false, timeout: 600)
        p = plan
        coll = p[:collection]
        wait_results = {}

        # Drops run BEFORE creates so any per-cluster cap (Atlas has a
        # cluster-wide search-index quota) doesn't reject a create that
        # would have fit after the orphan was removed.
        dropped = []
        orphans_skipped = []
        if drop
          p[:orphans].each do |name|
            confirm = "drop_search:#{coll}:#{name}"
            res = Parse::AtlasSearch::IndexManager.drop_index(coll, name, confirm: confirm)
            dropped << name if res == :dropped
          end
        else
          orphans_skipped = p[:orphans].dup
        end

        created = []
        skipped_exists = []
        p[:to_create].each do |decl|
          res = Parse::AtlasSearch::IndexManager.create_index(coll, decl[:name], decl[:definition])
          if res == :exists
            skipped_exists << decl
          else
            created << decl
            wait_results[decl[:name]] = wait_for(coll, decl[:name], timeout) if wait
          end
        end

        updated = []
        drifted_skipped = []
        if update
          p[:drifted].each do |entry|
            decl = entry[:declared]
            Parse::AtlasSearch::IndexManager.update_index(coll, decl[:name], decl[:definition])
            updated << decl[:name]
            wait_results[decl[:name]] = wait_for(coll, decl[:name], timeout) if wait
          end
        else
          drifted_skipped = p[:drifted].map { |e| e[:declared][:name] }
        end

        {
          created:         created,
          skipped_exists:  skipped_exists,
          in_sync:         p[:in_sync],
          updated:         updated,
          drifted_skipped: drifted_skipped,
          dropped:         dropped,
          orphans_skipped: orphans_skipped,
          wait_results:    wait_results,
        }
      end

      private

      # Read existing search indexes via the IndexManager's cached path.
      # Returns `[indexes, available]`. `available` is false when Atlas
      # isn't reachable (e.g. running against a vanilla Mongo without
      # Search support) — the migrator degrades gracefully and treats
      # the absence as "no indexes yet".
      def fetch_existing_indexes(coll)
        unless defined?(Parse::AtlasSearch::IndexManager)
          return [[], false]
        end
        return [[], false] unless mongodb_enabled?
        [Parse::AtlasSearch::IndexManager.list_indexes(coll, force_refresh: true), true]
      rescue Parse::AtlasSearch::NotAvailable, StandardError
        [[], false]
      end

      def mongodb_enabled?
        defined?(Parse::MongoDB) &&
          Parse::MongoDB.respond_to?(:enabled?) &&
          Parse::MongoDB.enabled?
      end

      # Compare a declared (normalized-already-at-DSL-time) definition
      # against an existing index's `latestDefinition`. Both sides are
      # deep-string-keyed before comparison so a declaration written
      # with symbol keys compares equal to the string-keyed
      # round-tripped value from Atlas.
      #
      # Returns false on any mismatch — including a missing
      # `latestDefinition`, which Atlas may omit during a BUILDING
      # window. A drift report in that case is the conservative answer:
      # the operator sees the diff and decides whether to wait or
      # re-apply.
      def definition_matches?(existing_index, declared_definition)
        current = existing_index["latestDefinition"] || existing_index[:latestDefinition]
        return false unless current.is_a?(Hash)
        normalize_for_compare(current) == normalize_for_compare(declared_definition)
      end

      # Atlas normalizes submitted definitions by filling in empty
      # default containers — e.g. `{ mappings: { dynamic: true } }` is
      # stored as `{ mappings: { dynamic: true, fields: {} } }`. A
      # strict deep-equal would classify every dynamic-mapping
      # declaration as "drifted" after the first apply. Normalize by
      # (a) stringifying keys recursively, and (b) dropping empty
      # Hash/Array values that Atlas adds as defaults. Non-empty
      # divergences still surface as drift.
      def normalize_for_compare(value)
        case value
        when Hash
          value.each_with_object({}) do |(k, v), h|
            sub = normalize_for_compare(v)
            # Drop empty Hash / Array values — Atlas adds these as
            # defaults during normalization. A genuine `fields: {}`
            # declaration is indistinguishable from an absent one in
            # this scheme, but that distinction has no operational
            # meaning either: an empty fields-map matches a missing
            # one in Atlas's behavior.
            next if (sub.is_a?(Hash) || sub.is_a?(Array)) && sub.empty?
            h[k.to_s] = sub
          end
        when Array
          value.map { |v| normalize_for_compare(v) }
        else
          value
        end
      end

      # Retained for the `update_search_index` command path, which
      # needs string-keyed output but not the empty-value stripping.
      def stringify_keys_deep(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify_keys_deep(v) }
        when Array
          value.map { |v| stringify_keys_deep(v) }
        else
          value
        end
      end

      # Trimmed view of an existing search index suitable for inclusion
      # in a plan's `:drifted` entry. Drops bulky fields (full status
      # history, statusDetail) so operator-facing output stays readable.
      def serialize_existing(idx)
        {
          name:               (idx["name"] || idx[:name]).to_s,
          status:             (idx["status"] || idx[:status]).to_s,
          queryable:          idx["queryable"] == true,
          latest_definition:  idx["latestDefinition"] || idx[:latestDefinition],
        }
      end

      def wait_for(coll, name, timeout)
        Parse::AtlasSearch::IndexManager.wait_for_ready(coll, name, timeout: timeout)
      end
    end
  end
end
