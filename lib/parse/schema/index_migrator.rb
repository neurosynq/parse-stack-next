# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Schema
    # Reconciliation engine for `Parse::Core::Indexing` declarations vs.
    # the actual MongoDB index state. Reads existing indexes via the
    # reader connection (so `plan` works in dry-run mode without writer
    # config); applies via the writer connection through
    # {Parse::MongoDB.create_index} / {Parse::MongoDB.drop_index} (which
    # re-check the triple gate and run their own per-call idempotency
    # check on the writer-side index list).
    #
    # **Multi-collection.** A single model can declare indexes against
    # both its own collection (via `mongo_index`) and one or more
    # `_Join:<field>:<ParentClass>` collections (via
    # `mongo_relation_index`). `plan` returns a Hash keyed by collection
    # name with one entry per unique target collection across the
    # declaration list. `apply!` returns a similarly-keyed result Hash.
    #
    # Parse-managed indexes (the ones Parse Server auto-creates on
    # collections like `_User`, `_Session`, `_Role`) are never proposed
    # for drop, regardless of whether they appear in the declaration
    # list. The list is conservative — any name matching
    # {PARSE_MANAGED_INDEX_PATTERNS} is treated as off-limits to the
    # migrator, full stop.
    class IndexMigrator
      # Names / patterns of indexes Parse Server creates and owns. The
      # migrator excludes these from both `to_drop` (so a missing
      # declaration never proposes their removal) and from `in_sync`
      # (so they don't visually clutter operator review). They appear
      # in `parse_managed:` for transparency.
      #
      # **Coverage is not forward-compatible.** This list reflects the
      # indexes Parse Server auto-creates as of Parse Server 7.x. Any
      # future Parse Server release that adds a new managed index will
      # cause that index to be classified as an orphan and be eligible
      # for drop under `DROP=true`. Operators upgrading Parse Server
      # should re-review this list before re-running
      # `parse:mongo:indexes:apply` with the drop flag.
      #
      # Any non-declared, non-managed index — including DBA-created
      # diagnostic indexes, indexes created by other Parse SDKs, and
      # MongoDB Atlas index recommendations — is also classified as
      # an orphan. If you need to preserve such an index, declare it
      # via {Parse::Core::Indexing#mongo_index} on the model.
      PARSE_MANAGED_INDEX_PATTERNS = [
        /\A_id_\z/,
        /\A_username_unique\z/,
        /\A_email_unique\z/,
        /\Aemail_1\z/,
        /\Ausername_1\z/,
        /\A_session_token_/,
        /\A_email_verify_token_/,
        /\A_perishable_token_/,
        /\A_account_lockout_/,
        /\Acase_insensitive_/,
      ].freeze

      attr_reader :model_class

      def initialize(model_class)
        unless model_class.is_a?(Class) && model_class < Parse::Object
          raise ArgumentError, "IndexMigrator expects a Parse::Object subclass; got #{model_class.inspect}"
        end
        @model_class = model_class
      end

      # @return [String] the model's primary collection name (parse_class).
      def collection_name
        @model_class.parse_class
      end

      # @return [Array<String>] unique target collections across all
      #   declarations. Includes the parent collection only when at
      #   least one declaration targets it (i.e. a non-relation index).
      def target_collections
        @model_class.mongo_index_declarations.map { |d| d[:collection] || collection_name }.uniq
      end

      # Compute the plan: what would change if `apply!` ran now.
      #
      # @return [Hash{String => Hash}] keyed by collection name. Each
      #   value Hash carries the per-collection result (see
      #   {#plan_for}).
      def plan
        target_collections.each_with_object({}) do |coll, h|
          h[coll] = plan_for(coll)
        end
      end

      # Per-collection plan. Filters declarations to those targeting
      # `collection`, then runs the diff against the actual MongoDB
      # state for that collection.
      #
      # Capacity accounting reports two scenarios so callers can reason
      # about both apply modes from a single plan:
      #   - `:capacity_after`, `:capacity_ok` — additive-only mode
      #     (no drops). Equal to `used + to_create.size`.
      #   - `:capacity_after_with_drop`, `:capacity_ok_with_drop` —
      #     additive + orphan removal. Equal to `used + to_create.size
      #     - orphans.size`. Use these when planning an `apply!(drop:
      #     true)` call.
      #
      # @param collection [String] target collection name
      # @return [Hash] per-collection plan
      def plan_for(collection)
        existing = fetch_existing_indexes(collection)
        declared = declarations_for(collection)
        managed, ours = partition_parse_managed(existing)
        to_create, in_sync, conflicts = diff_declarations(declared, ours)
        declared_names = declared.map { |d| d[:options][:name] }.compact.to_set
        declared_sigs  = declared.map { |d| key_sig(d[:keys]) }.to_set
        orphans = ours.reject do |idx|
          declared_sigs.include?(key_sig(idx["key"] || idx[:key])) ||
            declared_names.include?(idx["name"] || idx[:name])
        end

        max = Parse::Core::Indexing::MAX_INDEXES_PER_COLLECTION
        used = existing.size
        after_no_drop = used + to_create.size
        after_with_drop = after_no_drop - orphans.size

        {
          collection:               collection,
          declared:                 declared,
          existing:                 existing,
          parse_managed:            managed.map { |i| i["name"] || i[:name] },
          to_create:                to_create,
          in_sync:                  in_sync,
          conflicts:                conflicts,
          orphans:                  orphans.map { |i| i["name"] || i[:name] }.compact,
          capacity_used:            used,
          capacity_after:           after_no_drop,
          capacity_remaining:       max - after_no_drop,
          capacity_ok:              after_no_drop <= max,
          capacity_after_with_drop: after_with_drop,
          capacity_remaining_with_drop: max - after_with_drop,
          capacity_ok_with_drop:    after_with_drop <= max,
        }
      end

      # Apply the plan across all target collections. Additive by
      # default; `drop: true` opts into orphan removal on every target.
      # Each drop carries its own confirmation envelope through
      # `Parse::MongoDB.drop_index`.
      #
      # @return [Hash{String => Hash}] keyed by collection name. Each
      #   value Hash mirrors the legacy single-collection apply shape:
      #   `{ created:, skipped_exists:, dropped:, conflicts:, capacity_blocked: }`.
      def apply!(drop: false)
        target_collections.each_with_object({}) do |coll, h|
          h[coll] = apply_for!(coll, drop: drop)
        end
      end

      # Per-collection apply. Honors the same triple-gate / idempotency
      # rules as the cross-collection `apply!`. When `drop: true` the
      # method runs orphan drops BEFORE create_index so freed index
      # slots are available to satisfy `to_create` — required when the
      # collection is at or near the 64-index cap. Capacity is checked
      # against the post-drop count, matching the actual mid-apply
      # state.
      def apply_for!(collection, drop: false)
        p = plan_for(collection)
        capacity_ok = drop ? p[:capacity_ok_with_drop] : p[:capacity_ok]
        return { created: [], skipped_exists: [], dropped: [], conflicts: p[:conflicts],
                 capacity_blocked: true } unless capacity_ok

        created = []
        # Pre-seed skipped_exists with the declarations the plan already
        # classified as in_sync — they don't go through create_index, but
        # callers expect the result to reflect EVERY declaration's fate.
        skipped = p[:in_sync].dup
        dropped = []

        # Drops run BEFORE creates so a full collection with one orphan
        # and one new declaration doesn't hit "too many indexes" before
        # the drop frees a slot.
        if drop
          p[:orphans].each do |name|
            confirm = "drop:#{collection}:#{name}"
            res = Parse::MongoDB.drop_index(collection, name, confirm: confirm,
                                            allow_system_classes: collection.start_with?("_Join:"))
            dropped << name if res == :dropped
          end
        end

        p[:to_create].each do |decl|
          result = Parse::MongoDB.create_index(
            collection,
            decl[:keys],
            name:                decl[:options][:name],
            unique:              decl[:options][:unique] == true,
            sparse:              decl[:options][:sparse] == true,
            partial_filter:      decl[:options][:partial_filter],
            expire_after:        decl[:options][:expire_after],
            allow_system_classes: collection.start_with?("_Join:"),
          )
          (result == :exists ? skipped : created) << decl
        end

        {
          created:        created,
          skipped_exists: skipped,
          dropped:        dropped,
          conflicts:      p[:conflicts],
          capacity_blocked: false,
        }
      end

      private

      # Declarations targeting `collection`. A declaration with
      # `:collection => nil` defaults to the model's parse_class.
      def declarations_for(collection)
        base = collection_name
        @model_class.mongo_index_declarations.select do |d|
          (d[:collection] || base) == collection
        end
      end

      def fetch_existing_indexes(collection)
        return [] unless defined?(Parse::MongoDB) && Parse::MongoDB.respond_to?(:enabled?) && Parse::MongoDB.enabled?
        Parse::MongoDB.indexes(collection)
      end

      def partition_parse_managed(existing)
        managed, ours = existing.partition do |idx|
          name = idx["name"] || idx[:name]
          PARSE_MANAGED_INDEX_PATTERNS.any? { |re| re.match?(name.to_s) }
        end
        [managed, ours]
      end

      def diff_declarations(declared, existing_ours)
        to_create = []
        in_sync   = []
        conflicts = []

        declared.each do |decl|
          decl_sig = key_sig(decl[:keys])
          named    = decl[:options][:name]

          # Prefer a name match when the declaration named one — that's
          # the operator's authoritative target. Otherwise match by key
          # signature alone.
          target = if named
              existing_ours.find { |i| (i["name"] || i[:name]) == named }
            end
          target ||= existing_ours.find { |i| key_sig(i["key"] || i[:key]) == decl_sig }

          if target.nil?
            to_create << decl
          elsif options_match?(decl, target)
            in_sync << decl
          else
            conflicts << { declared: decl, existing: serialize_existing(target) }
          end
        end

        [to_create, in_sync, conflicts]
      end

      def key_sig(keys)
        return [] if keys.nil?
        keys.map { |k, v| [k.to_s, v] }
      end

      def options_match?(decl, idx)
        opt = decl[:options]
        return false if (opt[:unique] == true) != (idx["unique"] == true)
        return false if (opt[:sparse] == true) != (idx["sparse"] == true)
        ex_partial = idx["partialFilterExpression"]
        return false if (opt[:partial_filter] || nil) != (ex_partial || nil)
        return false if opt[:expire_after] && idx["expireAfterSeconds"] != opt[:expire_after]
        true
      end

      def serialize_existing(idx)
        {
          name: idx["name"] || idx[:name],
          key:  idx["key"]  || idx[:key],
          unique: idx["unique"] == true,
          sparse: idx["sparse"] == true,
          partial_filter: idx["partialFilterExpression"],
        }
      end
    end
  end
end
