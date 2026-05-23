# encoding: UTF-8
# frozen_string_literal: true

require_relative "pipeline_security"
require_relative "acl_scope"
require_relative "clp_scope"
require_relative "atlas_search/index_manager"
require_relative "atlas_search/search_builder"
require_relative "atlas_search/result"
require_relative "atlas_search/session"

module Parse
  # Atlas Search module for MongoDB Atlas full-text search capabilities.
  # Provides direct access to Atlas Search features bypassing Parse Server.
  #
  # @example Enable Atlas Search
  #   Parse::MongoDB.configure(uri: "mongodb+srv://...", enabled: true)
  #   Parse::AtlasSearch.configure(enabled: true, default_index: "default")
  #
  # @example Full-text search
  #   result = Parse::AtlasSearch.search("Song", "love", index: "song_search")
  #   result.results.each { |song| puts song.title }
  #
  # @example Autocomplete
  #   result = Parse::AtlasSearch.autocomplete("Song", "lov", field: :title)
  #   result.suggestions # => ["Love Story", "Lovely Day", "Love Me Do"]
  #
  # @note Requires the 'mongo' gem and a MongoDB Atlas cluster with Search enabled.
  #   Also works with local Atlas deployments created via `atlas deployments setup --type local`.
  module AtlasSearch
    # Error raised when Atlas Search is not available
    class NotAvailable < StandardError; end

    # Error raised when search index is not found
    class IndexNotFound < StandardError; end

    # Error raised for invalid search parameters
    class InvalidSearchParameters < StandardError; end

    # Error raised when the caller did not supply +session_token:+ or
    # +master: true+ and {.require_session_token} is +true+. Atlas
    # Search bypasses Parse Server's ACL evaluation, so the caller
    # must either pass a session token (so the SDK can inject a
    # +_rperm+ +$match+) or explicitly opt into master-key semantics.
    class ACLRequired < StandardError; end

    # Error raised when {.faceted_search} is called with a +session_token+.
    # +$searchMeta+ returns a single metadata document — bucket
    # counts that include restricted documents and cannot be
    # post-filtered with +$match+ because the matched documents are
    # not in the output stream. ACL-safe faceting requires the search
    # index to tokenize +_rperm+ and a +compound.filter+ injection
    # path; both are deferred to a follow-up release. Callers that
    # need ACL-aware faceting today must either run with +master: true+
    # or implement post-aggregation filtering themselves.
    class FacetedSearchNotACLSafe < StandardError; end

    class << self
      # @!attribute [rw] enabled
      #   Feature flag to enable/disable Atlas Search.
      #   @return [Boolean]
      attr_accessor :enabled

      # @!attribute [rw] default_index
      #   Default search index name to use when none specified.
      #   @return [String]
      attr_accessor :default_index

      # @!attribute [rw] allow_raw
      #   Whether `raw: true` is honored on {.search}, {.autocomplete},
      #   and {.faceted_search}. When `false` (the default), `raw:` is
      #   ignored and callers receive converted Parse-format
      #   documents. Even when `true`, internal-fields denylist (cf.
      #   {Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST}) is
      #   ALWAYS stripped — there is no path that returns
      #   `_hashed_password`, `_session_token`, etc., regardless of
      #   `raw:`.
      #   @return [Boolean]
      attr_accessor :allow_raw

      # @!attribute [rw] require_session_token
      #   When +true+, {.search}, {.autocomplete}, and
      #   {.faceted_search} raise {ACLRequired} unless the caller
      #   passes either +session_token:+ or +master: true+. Default:
      #   +false+, matching the pre-ACL behavior — a one-time
      #   +[Parse::AtlasSearch:SECURITY]+ banner is emitted instead
      #   for missing-token calls, the same pattern used by
      #   {Parse::Agent} for master-key construction.
      #
      #   New deployments are strongly encouraged to flip this to
      #   +true+ at startup. The next major release will flip the
      #   default.
      #   @return [Boolean]
      attr_accessor :require_session_token

      # @!attribute [rw] session_cache_ttl
      #   TTL (seconds) for {Session}'s session-token → user-id cache.
      #   Default: 3600 (1 hour). Longer values reduce +/users/me+
      #   round-trips but extend the window during which a revoked
      #   session can still authenticate Atlas Search calls; apps
      #   with sub-TTL revocation requirements should call
      #   {Session.invalidate} from their logout path.
      #   @return [Integer]
      attr_accessor :session_cache_ttl

      # @!attribute [rw] role_cache_ttl
      #   TTL (seconds) for {Session}'s user-id → role-name cache.
      #   Default: 120 (2 minutes). Short on purpose: stale role
      #   data yields incorrect ACL decisions, so the cache is sized
      #   to amortize within a single request/turn but expire well
      #   inside the response time the operator notices a role grant.
      #   @return [Integer]
      attr_accessor :role_cache_ttl

      # @!attribute [rw] session_cache
      #   Pluggable cache for {Session}'s session-token lookups.
      #   Replace with a Redis/Memcached adapter for cross-process
      #   sharing; the object must respond to +get(key)+,
      #   +set(key, value, ttl:)+, and +invalidate(key)+. Defaults
      #   to a process-local {Session::MemoryCache}.
      #   @return [#get, #set, #invalidate]
      attr_accessor :session_cache

      # @!attribute [rw] role_cache
      #   Pluggable cache for {Session}'s role-name lookups. See
      #   {.session_cache} for the interface contract.
      #   @return [#get, #set, #invalidate]
      attr_accessor :role_cache

      # Configure Atlas Search (uses Parse::MongoDB connection)
      # @param enabled [Boolean] whether to enable Atlas Search (default: true)
      # @param default_index [String] default search index name (default: "default")
      # @param allow_raw [Boolean] whether `raw: true` is honored on
      #   search/autocomplete/faceted_search. Defaults to `false`
      #   (raw flag ignored) in production-like environments and
      #   `true` when RACK_ENV/RAILS_ENV is `development` or `test`.
      #   Internal-field stripping runs regardless.
      # @param require_session_token [Boolean] when +true+, library
      #   calls without +session_token:+ or +master: true+ raise
      #   {ACLRequired}. See {#require_session_token}. Default: +false+.
      # @param session_cache_ttl [Integer] session-token cache TTL
      #   (seconds). Default: 3600.
      # @param role_cache_ttl [Integer] role-name cache TTL (seconds).
      #   Default: 120.
      # @example
      #   Parse::AtlasSearch.configure(enabled: true, default_index: "default")
      def configure(enabled: true,
                    default_index: "default",
                    allow_raw: nil,
                    require_session_token: nil,
                    session_cache_ttl: nil,
                    role_cache_ttl: nil)
        Parse::MongoDB.require_gem!
        @enabled = enabled
        @default_index = default_index
        @allow_raw = allow_raw.nil? ? default_allow_raw : allow_raw
        @require_session_token = require_session_token unless require_session_token.nil?
        @session_cache_ttl = session_cache_ttl unless session_cache_ttl.nil?
        @role_cache_ttl = role_cache_ttl unless role_cache_ttl.nil?
        IndexManager.clear_cache
      end

      # @!visibility private
      #
      # Default value for {#allow_raw}: permissive only when an
      # explicit non-production environment is signalled. Bare-Ruby
      # processes without `RACK_ENV`/`RAILS_ENV` get the strict
      # default (raw refused) so a forgotten env-var tag can't
      # downgrade security on a production deploy.
      def default_allow_raw
        env = ENV["RACK_ENV"] || ENV["RAILS_ENV"]
        return false if env.nil?
        %w[development test].include?(env)
      end

      # Check if Atlas Search is available and enabled
      # @return [Boolean]
      def available?
        return false unless defined?(Parse::MongoDB)
        Parse::MongoDB.available? && enabled?
      end

      # Check if Atlas Search is enabled
      # @return [Boolean]
      def enabled?
        @enabled == true
      end

      # Reset Atlas Search configuration to first-load defaults.
      # Clears the session/role caches as well; this is primarily a
      # test helper.
      def reset!
        @enabled = false
        @default_index = "default"
        @allow_raw = default_allow_raw
        @require_session_token = false
        @session_cache_ttl = 3600
        @role_cache_ttl = 120
        @session_cache = Session::MemoryCache.new
        @role_cache = Session::MemoryCache.new
        @master_warned = false
        IndexManager.clear_cache
      end

      # List search indexes for a collection (cached)
      # @param collection_name [String] the Parse collection name
      # @return [Array<Hash>] array of index definitions
      def indexes(collection_name)
        IndexManager.list_indexes(collection_name)
      end

      # Check if a search index exists and is ready
      # @param collection_name [String] the Parse collection name
      # @param index_name [String] the index name to check (default: default_index)
      # @return [Boolean] true if index exists and is queryable
      def index_ready?(collection_name, index_name = nil)
        IndexManager.index_ready?(collection_name, index_name || @default_index)
      end

      # Force refresh the index cache for a collection
      # @param collection_name [String] the Parse collection name (nil to clear all)
      def refresh_indexes(collection_name = nil)
        IndexManager.clear_cache(collection_name)
      end

      #----------------------------------------------------------------
      # SEARCH OPERATIONS
      #----------------------------------------------------------------

      # Perform a full-text search using Atlas Search.
      #
      # @param collection_name [String] the Parse collection name (e.g., "Song")
      # @param query [String] the search query text
      # @param options [Hash] search options
      # @option options [String] :index search index name (default: configured default_index)
      # @option options [Array<String>, String, Symbol] :fields fields to search (default: all indexed fields)
      # @option options [Boolean] :fuzzy enable fuzzy matching (default: false)
      # @option options [Integer] :fuzzy_max_edits max edit distance for fuzzy (1 or 2, default: 2)
      # @option options [Symbol, String] :highlight_field field to return highlights for
      # @option options [Integer] :limit max results to return (default: 100)
      # @option options [Integer] :skip number of results to skip (default: 0)
      # @option options [Hash] :filter additional constraints to apply
      # @option options [Hash] :sort sort specification (default: by relevance score)
      # @option options [Boolean] :raw return raw MongoDB documents (default: false)
      # @option options [String] :class_name Parse class name for object conversion
      #
      # @return [Parse::AtlasSearch::SearchResult] search result object
      #
      # @example Basic search
      #   result = Parse::AtlasSearch.search("Song", "love ballad")
      #   result.results.each { |song| puts song.title }
      #
      # @example Search with fuzzy matching and field restriction
      #   result = Parse::AtlasSearch.search("Song", "lvoe",
      #     fields: [:title, :lyrics],
      #     fuzzy: true,
      #     limit: 20
      #   )
      def search(collection_name, query, **options)
        require_available!
        validate_search_params!(query)

        # Wave-3b READPREF-4: read-preference is consumed at the
        # collection-with-read-preference step inside run_atlas_pipeline!.
        # Pop it here so it doesn't surface in `options` for any
        # downstream consumer (SearchBuilder, recursive search()
        # call from faceted_search) that iterates the hash.
        read_preference = options.delete(:read_preference)
        resolution = resolve_scope!(options, method_name: :search)

        # Enforce CLP `find` (and pointerFields requirement) BEFORE
        # we build / execute the pipeline. Without this, a scoped
        # caller can issue $search against a collection whose CLP
        # would refuse them on the equivalent REST find.
        assert_clp_find!(collection_name, resolution)
        pointer_fields = resolve_pointer_fields!(collection_name, resolution)

        # Compute the protectedFields strip set early so we can
        # refuse a highlight_field that's in it (ATLAS-4). Avoids
        # the awkward "we return objects but secretly drop their
        # highlights" state — fail loudly instead.
        protected_fields = Parse::CLPScope.protected_fields_for(
          collection_name, resolution.permission_strings,
        )
        assert_highlight_field_allowed!(options[:highlight_field], protected_fields, resolution)

        index_name = options[:index] || @default_index
        fields = normalize_fields(options[:fields])
        limit = options[:limit] || 100
        skip_val = options[:skip] || 0

        # Build the $search stage
        builder = SearchBuilder.new(index_name: index_name)

        if fields.present?
          fields.each do |field|
            builder.text(query: query, path: field, fuzzy: options[:fuzzy])
          end
        else
          builder.text(query: query, path: { "wildcard" => "*" }, fuzzy: options[:fuzzy])
        end

        if options[:highlight_field]
          builder.with_highlight(path: options[:highlight_field])
        end

        # CRITICAL: $search MUST be stage 0 of an Atlas Search
        # pipeline. MongoDB Atlas rejects pipelines whose first stage
        # is anything other than $search/$searchMeta. Do NOT route
        # through Parse::MongoDB.aggregate here — that helper prepends
        # the ACL $match to position 0, which Atlas would reject. We
        # build the pipeline manually with $search at index 0 and
        # place the ACL $match AFTER $search (which is correct: $search
        # has already produced its candidate set, the $match narrows it
        # to ACL-readable rows, then the caller filter narrows further).
        pipeline = [builder.build]

        # Add score projection
        pipeline << { "$addFields" => { "_score" => { "$meta" => "searchScore" } } }

        # Add highlights projection if requested
        if options[:highlight_field]
          pipeline << { "$addFields" => { "_highlights" => { "$meta" => "searchHighlights" } } }
        end

        # Inject ACL $match BEFORE the caller-supplied filter (but AFTER
        # $search and the $addFields stages) so the user-controlled
        # filter cannot exfiltrate restricted documents that passed the
        # $search operator. The $exists: false branch in `read_predicate`
        # covers documents Parse Server treats as public (no _rperm).
        unless resolution.master?
          acl_match = Parse::ACLScope.match_stage_for(resolution)
          pipeline << acl_match if acl_match
        end

        # Add filter stage if provided
        if options[:filter]
          mongo_filter = convert_filter_for_mongodb(options[:filter], collection_name)
          pipeline << { "$match" => mongo_filter }
        end

        # Add sort (default by score)
        sort_spec = options[:sort] || { "_score" => -1 }
        pipeline << { "$sort" => sort_spec }

        # Add pagination
        pipeline << { "$skip" => skip_val } if skip_val > 0
        pipeline << { "$limit" => limit }

        # Execute directly against the MongoDB collection — bypasses
        # Parse::MongoDB.aggregate so its ACL-prepend doesn't violate
        # the $search-at-stage-0 invariant. We're reproducing the
        # SDK-side enforcement chain (ACL match, protectedFields strip,
        # pointerFields filter, embedded sub-doc redaction) inline below.
        raw_results = run_atlas_pipeline!(
          collection_name, pipeline, options[:max_time_ms],
          read_preference: read_preference,
        )

        # Post-fetch enforcement: walk the result rows the same way
        # Parse::MongoDB.aggregate would. Master mode is the ACL bypass
        # — skip every redaction layer (matches the helper's behavior).
        unless resolution.master?
          Parse::ACLScope.redact_results!(raw_results, resolution)
          Parse::CLPScope.redact_protected_fields!(raw_results, protected_fields) if protected_fields.any?
          if pointer_fields
            raw_results = Parse::CLPScope.filter_by_pointer_fields(
              raw_results, pointer_fields, resolution.user_id,
            )
          end
          # ATLAS-4: drop any `_highlights` entry whose `path` names a
          # protected field. `searchHighlights` returns the matched
          # token plus its surrounding text, which would otherwise leak
          # the protected field's value through the snippet.
          strip_protected_highlights!(raw_results, protected_fields) if protected_fields.any?
        end

        # Convert results
        class_name = options[:class_name] || collection_name
        process_search_results(raw_results, class_name, options[:raw])
      end

      # Perform an autocomplete search for search-as-you-type functionality.
      #
      # @param collection_name [String] the Parse collection name
      # @param query [String] the partial search query (prefix)
      # @param field [Symbol, String] the field configured for autocomplete
      # @param options [Hash] autocomplete options
      # @option options [String] :index search index name (default: configured default_index)
      # @option options [Boolean] :fuzzy enable fuzzy matching (default: false)
      # @option options [Integer] :fuzzy_max_edits max edit distance (1 or 2, default: 1)
      # @option options [String] :token_order "any" or "sequential" (default: "any")
      # @option options [Integer] :limit max suggestions to return (default: 10)
      # @option options [Hash] :filter additional constraints
      # @option options [Boolean] :raw return raw documents (default: false)
      #
      # @return [Parse::AtlasSearch::AutocompleteResult] autocomplete result
      #
      # @example Basic autocomplete
      #   result = Parse::AtlasSearch.autocomplete("Song", "lov", field: :title)
      #   result.suggestions # => ["Love Story", "Lovely Day", "Love Me Do"]
      def autocomplete(collection_name, query, field:, **options)
        require_available!

        raise InvalidSearchParameters, "field is required for autocomplete" if field.nil?
        raise InvalidSearchParameters, "query must be a non-empty string" if query.nil? || query.to_s.strip.empty?

        # Wave-3b READPREF-4: see #search for rationale.
        read_preference = options.delete(:read_preference)
        resolution = resolve_scope!(options, method_name: :autocomplete)

        # Enforce CLP `find` (and pointerFields requirement) on the same
        # collection autocomplete is about to scan. Without this an
        # autocomplete UI on a protected class would silently surface
        # the protected field's leading characters to any caller.
        assert_clp_find!(collection_name, resolution)
        pointer_fields = resolve_pointer_fields!(collection_name, resolution)

        # ATLAS-4: refuse autocomplete on a protected field. The
        # autocomplete operator returns the leading characters of the
        # indexed field value verbatim — running autocomplete on, say,
        # `email` when CLP marks `email` protected would defeat the
        # protectedFields contract.
        protected_fields = Parse::CLPScope.protected_fields_for(
          collection_name, resolution.permission_strings,
        )
        field_str = field.to_s
        if !resolution.master? && protected_fields.include?(field_str)
          raise Parse::CLPScope::Denied.new(
            collection_name, :find,
            "Parse::AtlasSearch.autocomplete refused: field '#{field_str}' is in " \
            "protectedFields for the current scope; autocompleting on it would " \
            "leak the protected field's value.",
          )
        end

        index_name = options[:index] || @default_index
        limit = options[:limit] || 10

        # Build autocomplete search stage
        builder = SearchBuilder.new(index_name: index_name)
        builder.autocomplete(
          query: query.to_s,
          path: field_str,
          fuzzy: options[:fuzzy],
          token_order: options[:token_order],
        )

        # CRITICAL: $search MUST be stage 0 of the pipeline (see
        # comments in #search). Build manually; do NOT route through
        # Parse::MongoDB.aggregate (which would prepend an ACL $match
        # at position 0 and break Atlas's invariant).
        pipeline = [builder.build]

        # Add score
        pipeline << { "$addFields" => { "_score" => { "$meta" => "searchScore" } } }

        # Inject ACL $match AFTER $search/$addFields and BEFORE the
        # caller-supplied filter; see {.search} for the rationale.
        unless resolution.master?
          acl_match = Parse::ACLScope.match_stage_for(resolution)
          pipeline << acl_match if acl_match
        end

        # Add filter if provided
        if options[:filter]
          mongo_filter = convert_filter_for_mongodb(options[:filter], collection_name)
          pipeline << { "$match" => mongo_filter }
        end

        # Sort by score and limit
        pipeline << { "$sort" => { "_score" => -1 } }
        pipeline << { "$limit" => limit }

        raw_results = run_atlas_pipeline!(
          collection_name, pipeline, options[:max_time_ms],
          read_preference: read_preference,
        )

        unless resolution.master?
          Parse::ACLScope.redact_results!(raw_results, resolution)
          Parse::CLPScope.redact_protected_fields!(raw_results, protected_fields) if protected_fields.any?
          if pointer_fields
            raw_results = Parse::CLPScope.filter_by_pointer_fields(
              raw_results, pointer_fields, resolution.user_id,
            )
          end
        end

        # Extract suggestions (the field values). Run after the
        # protectedFields strip / pointerFields filter so a redacted
        # row can't surface its field value through the suggestion list.
        suggestions = raw_results.map { |doc| doc[field_str] }.compact.uniq

        # Convert to full objects if needed
        class_name = options[:class_name] || collection_name
        results = if raw_mode?(options[:raw])
            sanitize_raw_results(raw_results)
          else
            parse_results = Parse::MongoDB.convert_documents_to_parse(raw_results, class_name)
            parse_results.map { |doc| build_parse_object(doc, class_name) }.compact
          end

        AutocompleteResult.new(suggestions: suggestions, results: results)
      end

      # Perform a faceted search with category counts.
      #
      # @param collection_name [String] the Parse collection name
      # @param query [String, nil] the search query text (nil for match-all)
      # @param facets [Hash] facet definitions
      # @param options [Hash] search options (same as #search)
      #
      # @return [Parse::AtlasSearch::FacetedResult] faceted result
      #
      # @example Faceted search by genre and year
      #   facets = {
      #     genre: { type: :string, path: :genre },
      #     decade: { type: :number, path: :year, boundaries: [1970, 1980, 1990, 2000, 2010] }
      #   }
      #   result = Parse::AtlasSearch.faceted_search("Song", "rock", facets)
      #   result.facets[:genre] # => [{ value: "Rock", count: 150 }, ...]
      def faceted_search(collection_name, query, facets, **options)
        require_available!

        # Faceted search uses $searchMeta, which outputs a single
        # metadata document — bucket counts can't be retroactively
        # filtered by a post-$searchMeta $match because the matched
        # documents are not in the output stream. ACL-aware faceting
        # requires either tokenizing _rperm in the search index and
        # injecting a compound.filter inside $searchMeta, or running
        # two passes with manual aggregation. Both are deferred.
        #
        # Library-layer defense: refuse ANY scoped identity kwarg
        # (session_token:, acl_user:, acl_role:) unless the caller
        # explicitly accepts master-key semantics by also passing
        # `master: true`. The original code only checked
        # `session_token:`, leaving `acl_user:` / `acl_role:` callers
        # (ATLAS-10) silently downgraded to the unauthenticated/
        # public-mode banner branch — which on $searchMeta produces
        # bucket counts that include rows the caller cannot read,
        # exfiltrating restricted document counts and category
        # values. Checking the raw options BEFORE resolve_scope!
        # pops them so the error path can name what the caller
        # actually passed.
        scoped_kwargs = %i[session_token acl_user acl_role]
        offending = scoped_kwargs.select { |k| !options[k].nil? }
        if offending.any? && options[:master] != true
          raise FacetedSearchNotACLSafe,
                "Parse::AtlasSearch.faceted_search cannot enforce per-row " \
                "ACL on $searchMeta bucket counts (got #{offending.first}:). " \
                "Pass `master: true` to run with master-key semantics and " \
                "accept that bucket counts include all rows, or use " \
                "#search for ACL-scoped results without facets."
        end
        # Wave-3b READPREF-4: see #search for rationale. Captured
        # before resolve_scope! pops the auth kwargs so the recursive
        # search() call below can re-thread it explicitly (resolve!
        # also strips it during that recursion).
        read_preference = options.delete(:read_preference)
        resolution = resolve_scope!(options, method_name: :faceted_search)
        acl = { master: resolution.master? }

        index_name = options[:index] || @default_index
        limit = options[:limit] || 100
        skip_val = options[:skip] || 0

        # Build facet definitions for $searchMeta
        facet_definitions = build_facet_definitions(facets)

        search_meta_stage = {
          "$searchMeta" => {
            "index" => index_name,
            "facet" => {
              "facets" => facet_definitions,
            },
          },
        }

        # Add operator for the search query if present
        if query.present?
          fields = normalize_fields(options[:fields])
          if fields.present?
            should_clauses = fields.map do |field|
              { "text" => { "query" => query, "path" => field } }
            end
            search_meta_stage["$searchMeta"]["facet"]["operator"] = {
              "compound" => { "should" => should_clauses, "minimumShouldMatch" => 1 },
            }
          else
            search_meta_stage["$searchMeta"]["facet"]["operator"] = {
              "text" => { "query" => query, "path" => { "wildcard" => "*" } },
            }
          end
        end

        # Execute facet query. $searchMeta MUST be the only / first
        # stage of its pipeline — Atlas rejects anything prepended.
        # Bypass Parse::MongoDB.aggregate (which would prepend a
        # public-mode ACL $match at position 0 under the no-auth-kwargs
        # fallthrough) and call the collection directly. At this point
        # the call is master-only by construction (the offending-kwargs
        # check above ensures any scoped caller bailed out), so no
        # ACL/CLP enforcement runs here either.
        facet_pipeline = [search_meta_stage]
        facet_results_raw = run_atlas_pipeline!(
          collection_name, facet_pipeline, options[:max_time_ms],
          read_preference: read_preference,
        )

        # Extract facet results
        facet_data = {}
        total_count = 0

        if facet_results_raw.first
          raw = facet_results_raw.first
          total_count = raw.dig("count", "total") || 0

          if raw["facet"]
            facets.keys.each do |facet_name|
              bucket_key = facet_name.to_s
              if raw["facet"][bucket_key]
                facet_data[facet_name] = raw["facet"][bucket_key]["buckets"].map do |bucket|
                  { value: bucket["_id"], count: bucket["count"] }
                end
              end
            end
          end
        end

        # Get actual results with regular $search. Forward master:
        # explicitly because resolve_acl_options! popped it from the
        # options hash; without re-adding it the recursive call would
        # take the unauthenticated path and emit the banner a second
        # time (or raise ACLRequired under strict mode). Re-thread
        # read_preference: the same way for the same reason — the
        # outer faceted_search popped it before delegating.
        results = if limit > 0 && query.present?
            search_opts = options.merge(limit: limit, skip: skip_val)
            search_opts[:master] = true if acl[:master]
            search_opts[:read_preference] = read_preference if read_preference
            search(collection_name, query, **search_opts).results
          else
            []
          end

        FacetedResult.new(results: results, facets: facet_data, total_count: total_count)
      end

      private

      def require_available!
        Parse::MongoDB.require_gem!
        unless available?
          raise NotAvailable,
            "Atlas Search is not available. Ensure Parse::MongoDB is configured " \
            "and Parse::AtlasSearch.configure(enabled: true) has been called."
        end
      end

      # Pop the auth-related kwargs (+:session_token+, +:master+,
      # +:acl_user+, +:acl_role+) off +options+ and return a fully
      # resolved {Parse::ACLScope::Resolution}. Replaces the old
      # +resolve_acl_options!+ shim that returned a bare Hash — the
      # post-fetch enforcement chain ({Parse::ACLScope.redact_results!},
      # {Parse::CLPScope.redact_protected_fields!}, etc.) all consume a
      # Resolution, so producing one here keeps the call sites uniform.
      #
      # Modes match {Parse::ACLScope::Resolution}:
      #
      #   * +:session+ — +session_token:+ resolved, or +acl_user:+ /
      #     +acl_role:+ supplied. ACL+CLP+protectedFields enforcement
      #     runs in full.
      #   * +:master+ — +master: true+. ACL/CLP enforcement is bypassed
      #     (the caller has explicit master-key intent).
      #   * +:public+ — no scope kwargs supplied, +require_session_token+
      #     is +false+. A one-time banner is emitted and the call
      #     falls through with public-only ACL semantics — public-mode
      #     enforcement still runs (refused rows are filtered, the
      #     CLP allowlist is consulted), the perms set is just
      #     +["*"]+ rather than user-scoped.
      #
      # Raises {ACLRequired} when no scope kwargs are supplied and
      # {.require_session_token} is +true+. The agent-tool path
      # refuses unconditionally regardless of this toggle — see
      # {Parse::Agent::Tools}.
      def resolve_scope!(options, method_name:)
        session_token = options.delete(:session_token)
        master = options.delete(:master)
        acl_user = options.delete(:acl_user)
        acl_role = options.delete(:acl_role)

        # 4-way mutex. Mirrors Parse::ACLScope.resolve!'s
        # `provided.length > 1` check so an `acl_user:` + `acl_role:`
        # combination, or any other 2-of-N, is refused. Chained `if`
        # branches would silently accept 3-way / 4-way combinations.
        provided = [
          session_token,
          master == true ? master : nil,
          acl_user,
          acl_role,
        ].compact
        if provided.length > 1
          raise ArgumentError,
                "Parse::AtlasSearch.#{method_name}: cannot pass more than one of " \
                "session_token:, master: true, acl_user:, or acl_role:. Pick one."
        end

        if session_token
          resolved = Session.resolve(session_token)
          return Parse::ACLScope::Resolution.new(
            mode: :session,
            permission_strings: resolved.permission_strings,
            user_id: resolved.user_id,
            session: resolved,
          )
        end

        if acl_user
          return Parse::ACLScope.resolve_for_user(acl_user)
        end

        if acl_role
          return Parse::ACLScope.resolve_for_role(acl_role)
        end

        if master == true
          return Parse::ACLScope::Resolution.new(
            mode: :master, permission_strings: nil, user_id: nil, session: nil,
          )
        end

        if @require_session_token == true
          raise ACLRequired,
                "Parse::AtlasSearch.#{method_name} requires session_token: or " \
                "master: true (or acl_user:/acl_role:). ACL enforcement is " \
                "disabled when none is supplied; flip " \
                "Parse::AtlasSearch.require_session_token = false to allow " \
                "public-only fallback."
        end

        warn_no_acl_context_once!(method_name)
        anonymous = Session::Resolved.new(nil, Set.new)
        Parse::ACLScope::Resolution.new(
          mode: :public,
          permission_strings: anonymous.permission_strings,
          user_id: nil,
          session: anonymous,
        )
      end

      # CLP `find` boundary check. Master-mode skips; for every other
      # scope, refuse the call when the resolved claim set can't
      # `find` on the collection. Mirrors what Parse::MongoDB.aggregate
      # does inline (we can't reuse that path because of the $search-
      # at-stage-0 invariant).
      def assert_clp_find!(collection_name, resolution)
        return if resolution.nil? || resolution.master?
        unless Parse::CLPScope.permits?(collection_name, :find, resolution.permission_strings)
          raise Parse::CLPScope::Denied.new(
            collection_name, :find,
            "CLP refuses find on '#{collection_name}' for the current Atlas Search scope.",
          )
        end
      end

      # Resolve and return pointerFields for `find` on the collection.
      # Raises CLPScope::Denied when pointerFields is set but the
      # current scope has no user_id (acl_role-only / public agents).
      # Returns nil when master-mode or no pointerFields entry exists.
      def resolve_pointer_fields!(collection_name, resolution)
        return nil if resolution.nil? || resolution.master?
        pointer_fields = Parse::CLPScope.pointer_fields_for(collection_name, :find)
        return nil if pointer_fields.nil?
        if resolution.user_id.nil?
          raise Parse::CLPScope::Denied.new(
            collection_name, :find,
            "CLP requires user identity (pointerFields=#{pointer_fields.inspect}) " \
            "but the current Atlas Search scope has no user_id.",
          )
        end
        pointer_fields
      end

      # ATLAS-4: refuse `highlight_field:` when the field is in the
      # resolved protectedFields set. searchHighlights returns the
      # matched token plus surrounding chars verbatim; running it on
      # a protected field would defeat the protectedFields contract.
      # Master-mode skips (no protectedFields apply).
      def assert_highlight_field_allowed!(highlight_field, protected_fields, resolution)
        return if highlight_field.nil?
        return if resolution.nil? || resolution.master?
        return if protected_fields.nil? || protected_fields.empty?
        path = highlight_field.to_s
        return unless protected_fields.include?(path)
        raise Parse::CLPScope::Denied.new(
          nil, :find,
          "Parse::AtlasSearch.search refused: highlight_field '#{path}' is in " \
          "protectedFields for the current scope; returning highlights would " \
          "leak the protected field's value.",
        )
      end

      # Drop `_highlights` entries whose `path` matches a
      # protectedFields entry. Defense-in-depth complement to
      # {.assert_highlight_field_allowed!} — that gate refuses the
      # SDK-set highlight_field; this scrubs any highlight payload
      # that arrived through other code paths (e.g., builder reuse
      # or a future caller-supplied highlight Hash).
      def strip_protected_highlights!(documents, protected_fields)
        return if documents.nil? || documents.empty?
        return if protected_fields.nil? || protected_fields.empty?
        protected_set = protected_fields.to_set
        documents.each do |doc|
          next unless doc.is_a?(Hash)
          highlights = doc["_highlights"]
          next unless highlights.is_a?(Array)
          doc["_highlights"] = highlights.reject do |h|
            h.is_a?(Hash) && protected_set.include?((h["path"] || h[:path]).to_s)
          end
        end
      end

      # Execute the Atlas Search pipeline directly against the MongoDB
      # collection. Bypasses {Parse::MongoDB.aggregate} (which would
      # prepend the ACL $match at stage 0 — Atlas rejects any pipeline
      # whose stage 0 is not $search/$searchMeta). Timeout translation
      # is preserved to match {Parse::MongoDB.aggregate}'s behavior.
      #
      # Wave-3b READPREF-4: optional `read_preference:` is normalized
      # through the same `Parse::MongoDB.normalize_read_preference`
      # helper {Parse::MongoDB.aggregate} uses so the kwarg semantics
      # are identical on both paths (invalid values warn and route to
      # primary; nil = no override).
      def run_atlas_pipeline!(collection_name, pipeline, max_time_ms = nil, read_preference: nil)
        agg_opts = {}
        agg_opts[:max_time_ms] = max_time_ms if max_time_ms
        coll = Parse::MongoDB.collection(collection_name)
        if (mode = Parse::MongoDB.send(:normalize_read_preference, read_preference))
          coll = coll.with(read: { mode: mode })
        end
        coll.aggregate(pipeline, agg_opts).to_a
      rescue => e
        # `raise_if_timeout!` is module-private on Parse::MongoDB; use
        # `send` so we can reuse the timeout-translation logic without
        # widening its public surface.
        Parse::MongoDB.send(:raise_if_timeout!, e, collection_name, max_time_ms)
        raise
      end

      # Emit a one-time +[Parse::AtlasSearch:SECURITY]+ banner the
      # first time an Atlas Search call runs without a session_token
      # and without an explicit +master: true+. Mirrors the
      # warned-once pattern {Parse::Agent} uses for master-key
      # construction so noisy logs don't drown out the warning, but
      # one log line per process is enough to surface the misuse to
      # operators.
      def warn_no_acl_context_once!(method_name)
        return if @master_warned == true
        @master_warned = true
        warn "[Parse::AtlasSearch:SECURITY] #{method_name} called without " \
             "session_token: or master: true. The pipeline will enforce " \
             "public-only ACL semantics (only documents with no _rperm or " \
             "_rperm including \"*\"). Pass session_token: for per-user " \
             "filtering, or master: true to confirm the master-key bypass " \
             "is intentional. Set Parse::AtlasSearch.require_session_token " \
             "= true to make this misuse an error instead of a warning."
      end

      def validate_search_params!(query)
        raise InvalidSearchParameters, "query must be a string" unless query.is_a?(String)
        raise InvalidSearchParameters, "query cannot be empty" if query.strip.empty?
      end

      def normalize_fields(fields)
        return nil if fields.nil?
        Array(fields).map(&:to_s)
      end

      def convert_filter_for_mongodb(filter, collection_name)
        # The filter hash is interpolated directly into a `$match` stage in
        # the search pipeline. A caller forwarding a user-controlled filter
        # (search UI, autocomplete endpoint) must not be able to inject
        # `$where`, `$function`, `$accumulator`, `$out`, or `$merge` here.
        # `Parse::PipelineSecurity.validate_filter!` recurses through the
        # hash and refuses any of those operators at any depth.
        Parse::PipelineSecurity.validate_filter!(filter) if filter
        filter
      end

      def build_facet_definitions(facets)
        definitions = {}

        facets.each do |name, config|
          path = config[:path].to_s
          facet_def = { "path" => path }

          case config[:type]
          when :string
            facet_def["type"] = "string"
            facet_def["numBuckets"] = config[:num_buckets] || 10
          when :number
            facet_def["type"] = "number"
            facet_def["boundaries"] = config[:boundaries] if config[:boundaries]
            facet_def["default"] = config[:default] if config[:default]
          when :date
            facet_def["type"] = "date"
            facet_def["boundaries"] = config[:boundaries].map do |d|
              d.respond_to?(:iso8601) ? d.iso8601 : d
            end if config[:boundaries]
            facet_def["default"] = config[:default] if config[:default]
          end

          definitions[name.to_s] = facet_def
        end

        definitions
      end

      def build_parse_object(doc, class_name)
        # Try to use Parse::Object.build if available, otherwise return the hash
        if defined?(Parse::Object) && Parse::Object.respond_to?(:build)
          Parse::Object.build(doc, class_name)
        else
          # Fallback: return hash with class info
          doc["className"] ||= class_name
          doc
        end
      end

      def process_search_results(raw_results, class_name, raw_mode)
        sanitized_raw = sanitize_raw_results(raw_results)
        if raw_mode?(raw_mode)
          # The `raw:` channel is the only path callers see the un-
          # converted Mongo shape on. Internal-fields denylist is
          # ALWAYS stripped (cf. INTERNAL_FIELDS_DENYLIST) so a
          # leaked `raw: true` parameter can't surface
          # _hashed_password / _session_token. `raw_results:` on the
          # returned SearchResult mirrors the sanitized form for the
          # same reason.
          SearchResult.new(results: sanitized_raw, raw_results: sanitized_raw)
        else
          parse_results = Parse::MongoDB.convert_documents_to_parse(raw_results, class_name)
          objects = parse_results.each_with_index.map do |doc, idx|
            obj = build_parse_object(doc, class_name)
            raw_doc = raw_results[idx]
            # Attach search metadata from original raw document (scores are stripped during conversion)
            if obj && raw_doc["_score"]
              obj.instance_variable_set(:@_search_score, raw_doc["_score"])
              # Define accessor if not already defined
              unless obj.respond_to?(:search_score)
                obj.define_singleton_method(:search_score) { @_search_score }
              end
            end
            if obj && raw_doc["_highlights"]
              obj.instance_variable_set(:@_search_highlights, raw_doc["_highlights"])
              unless obj.respond_to?(:search_highlights)
                obj.define_singleton_method(:search_highlights) { @_search_highlights }
              end
            end
            obj
          end.compact
          SearchResult.new(results: objects, raw_results: sanitized_raw)
        end
      end

      # Coerce the `raw:` argument against the module-level
      # {#allow_raw} switch. Returns `true` only when both the caller
      # asked for raw mode AND the runtime permits it.
      def raw_mode?(requested)
        return false unless requested
        @allow_raw.nil? ? default_allow_raw : @allow_raw
      end

      # Strip {Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST}
      # entries from every document. Unconditional: even when
      # `raw:`-mode is permitted, internal Parse Server columns are
      # never legitimate to return to a search caller.
      def sanitize_raw_results(docs)
        Array(docs).map { |doc| Parse::PipelineSecurity.strip_internal_fields(doc) }
      end
    end

    # Initialize defaults
    @enabled = false
    @default_index = "default"
    @allow_raw = nil
    @require_session_token = false
    @session_cache_ttl = 3600
    @role_cache_ttl = 120
    @session_cache = Session::MemoryCache.new
    @role_cache = Session::MemoryCache.new
    @master_warned = false
  end
end
