# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # DSL module that adds agent metadata capabilities to Parse::Object models.
    # Allows models to self-document with descriptions and expose safe methods
    # to the Parse Agent for LLM interaction.
    #
    # @example Define a model with agent metadata
    #   class Workspace < Parse::Object
    #     agent_description "A group of users contributing to a Project"
    #
    #     property :name, :string, description: "The workspace's display name"
    #     property :member_count, :integer, description: "Number of active members"
    #
    #     agent_method :active_projects, "Returns projects currently in progress"
    #     agent_method :member_names, "Returns array of member display names"
    #
    #     def self.active_projects
    #       Project.query(status: "active")
    #     end
    #
    #     def member_names
    #       members.map(&:display_name)
    #     end
    #   end
    #
    module MetadataDSL
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Mark this class as visible to agents.
        # Only classes marked with agent_visible will be included in schema listings.
        # If no classes are marked, all classes are shown (backwards compatible).
        #
        # @example Mark a class as agent-visible
        #   class Song < Parse::Object
        #     agent_visible
        #     agent_description "A music track"
        #   end
        #
        # @return [Boolean] true
        def agent_visible
          @agent_visible = true
          Parse::Agent::MetadataRegistry.register_visible_class(self)
          true
        end

        # Check if this class is marked as visible to agents
        # @return [Boolean]
        def agent_visible?
          @agent_visible == true
        end

        # Mark this class as hidden from agent tools. Hidden classes are
        # filtered out of `get_all_schemas`, refused by `query_class` /
        # `count_objects` / `get_object` / `get_objects` / `get_sample_objects` /
        # `aggregate` / `explain_query` / `get_schema` with a sanitized
        # `:permission_denied` error response, and excluded from the
        # `RelationGraph` prompt diagram.
        #
        # Unlike `agent_visible` (which is opt-in for diagram-walking only),
        # `agent_hidden` is a hard access denial. Use it for classes that
        # contain PII the agent must never touch — student SSN tables,
        # internal billing records, password reset tokens, etc.
        #
        # Records still exist in the database; only the agent surface is
        # blocked. Direct application code (Parse::Object#query, Parse::MongoDB)
        # is unaffected.
        #
        # @example Hide a PII class from every agent surface
        #   class StudentSSN < Parse::Object
        #     parse_class "StudentSSN"
        #     property :student_name, :string
        #     property :ssn, :string
        #     agent_hidden
        #   end
        #
        # @param except [Symbol, nil] when set to `:master_key`, session-bound
        #   agents refuse this class but master-key agents are allowed through.
        #   This is the "internal admin tooling can see it, user-facing agents
        #   never can" tier — intended for collections like `_Session` where a
        #   dev-MCP / customer-support tool may legitimately need read access
        #   but no end-user-bound agent ever should. The field-level
        #   `INTERNAL_FIELDS_DENYLIST` floor (sessionToken, _hashed_password,
        #   etc.) still applies, so even master-key reads cannot exfiltrate
        #   credential columns.
        # @return [Boolean] true
        def agent_hidden(except: nil)
          @agent_hidden = true
          @agent_hidden_except = case except
                                 when nil    then nil
                                 when :master_key, "master_key" then :master_key
                                 else
                                   raise ArgumentError,
                                         "agent_hidden(except:) accepts only :master_key (got #{except.inspect})"
                                 end
          Parse::Agent::MetadataRegistry.register_hidden_class(self, except: @agent_hidden_except)
          true
        end

        # Reverse a previous `agent_hidden` declaration on this class. Clears the
        # per-class hidden flag and removes the class from the registry's hidden
        # set so that every agent tool surface treats the class as visible again
        # (subject to the per-tool `agent_fields` allowlist and other policy).
        # The field-level `INTERNAL_FIELDS_DENYLIST` floor still strips
        # credential columns from every response.
        #
        # The intended use is to opt back in to a built-in class that
        # parse-stack marks hidden by default — for example `Parse::Product`,
        # which is hidden in `lib/parse/agent.rb` because the `_Product`
        # collection is a vestigial iOS IAP feature, but an application that
        # actually does use the collection can call:
        #
        #   Parse::Product.agent_unhidden
        #
        # at boot time (after `require 'parse/stack'`) to expose it. The same
        # mechanism applies to any application-defined class that was marked
        # `agent_hidden` and needs to be re-enabled for a specific deployment.
        #
        # @return [Boolean] true if a previous `agent_hidden` declaration was
        #   actually reversed; false when the class was not hidden to begin
        #   with (idempotent no-op). Matches `Hash#delete?`/`Set#delete?`
        #   "did anything change" semantics so callers can branch on the
        #   return value.
        def agent_unhidden
          was_hidden = @agent_hidden == true
          @agent_hidden = false
          @agent_hidden_except = nil
          Parse::Agent::MetadataRegistry.unregister_hidden_class(self)
          # Only audit on a real state flip — calling `agent_unhidden` on a
          # class that was never hidden is a no-op and shouldn't emit a banner
          # that trains operators to suppress the warning globally.
          if was_hidden && !(defined?(Parse::Agent) && Parse::Agent.respond_to?(:suppress_master_key_warning?) && Parse::Agent.suppress_master_key_warning?)
            warn "[Parse::Agent:SECURITY] #{name} (#{respond_to?(:parse_class) ? parse_class : name}) was marked agent_unhidden — " \
                 "this class is now reachable from every agent tool surface (query_class, aggregate, get_schema, etc.). " \
                 "Master-key agents bypass per-row ACL/CLP enforcement, so per-class agent_fields / agent_canonical_filter / " \
                 "tenant_id are the only remaining access boundary. Credential columns are still stripped by the " \
                 "INTERNAL_FIELDS_DENYLIST floor regardless of class visibility. Confirm this is intentional. " \
                 "Silence with Parse::Agent.suppress_master_key_warning = true."
          end
          was_hidden
        end

        # Check if this class is hidden from agent tools.
        # @return [Boolean]
        def agent_hidden?
          @agent_hidden == true
        end

        # The exception scope a previous `agent_hidden(except: ...)` declared,
        # or nil when the class is unconditionally hidden / not hidden at all.
        # Currently the only supported value is `:master_key`.
        # @return [Symbol, nil]
        def agent_hidden_except
          @agent_hidden_except
        end

        # Set or get the class-level description for agent context.
        # This description helps LLMs understand what this class represents.
        #
        # @example Set a description
        #   agent_description "A music track in the catalog"
        #
        # @example Get the description
        #   Song.agent_description # => "A music track in the catalog"
        #
        # @param text [String, nil] the description to set, or nil to get
        # @return [String, nil] the current description
        def agent_description(text = nil)
          if text
            @agent_description = text.to_s.freeze
          else
            @agent_description
          end
        end

        # Property descriptions are stored in Parse::Properties module.
        # This method is provided there via the `property` DSL with `_description:` option.
        # @see Parse::Properties::ClassMethods#property_descriptions

        # Declare which fields are surfaced to agent tools for this class.
        # When set, agent schema enrichment trims the field list down to this
        # allowlist (plus the always-on `objectId`/`createdAt`/`updatedAt`), and
        # agent query/fetch tools push the allowlist into the server-side `keys`
        # projection unless the caller passed an explicit `keys:` override.
        # Called without arguments, returns the current allowlist.
        #
        # @example Limit agent visibility to analytics-relevant fields
        #   class Workspace < Parse::Object
        #     agent_fields :name, :status, :member_count, :owner
        #   end
        #
        # @param names [Array<Symbol, String>] field names to allow
        # @return [Array<Symbol>] the resulting allowlist
        def agent_fields(*names)
          return @agent_field_allowlist ||= [] if names.empty?
          @agent_field_allowlist = names.flatten.map(&:to_sym).freeze
          # If agent_join_fields was declared earlier in the class body, the
          # subset invariant must still hold once agent_fields lands. Re-check
          # so declaration order doesn't matter.
          assert_agent_join_fields_subset!
          @agent_field_allowlist
        end

        # Read-only accessor for the agent field allowlist.
        # @return [Array<Symbol>] the allowlist (empty if not declared)
        def agent_field_allowlist
          @agent_field_allowlist || []
        end

        # Declare a narrower projection used when this class shows up as an
        # included pointer on another class's query (`query_class` /
        # `get_object` / `get_objects` / `get_sample_objects` /
        # `export_data` + `include:`). When the agent asks for
        # `keys: ["user", ...] + include: ["user"]`, the SDK auto-rewrites
        # `keys` to dotted paths (`user.firstName, user.email, ...`) so the
        # joined record is projected to exactly the fields listed here.
        #
        # This sits one tier tighter than `agent_fields`. The direct-query
        # allowlist is typically the full "what the agent may see" set;
        # the join-projection list is the narrower "what's interesting when
        # I'm a foreign key" set. Example: `_User` may surface 18 fields on
        # a direct query, but when it's joined onto a `Subscription` row the
        # agent usually only needs `firstName`, `lastName`, `email`,
        # `category` — not the `workspaces[]` pointer array or the
        # `iconImage` presigned URL.
        #
        # **Subset invariant**: when both `agent_fields` and
        # `agent_join_fields` are declared, every entry in
        # `agent_join_fields` MUST also appear in `agent_fields`. The
        # direct-query allowlist is the upper bound on what the agent ever
        # sees; the join list can only tighten that, never widen it.
        # Violations raise `ArgumentError` at class load time. Declaring
        # `agent_join_fields` without `agent_fields` is allowed — it means
        # "no direct-query allowlist, but on a join project to these only."
        #
        # When `agent_join_fields` is NOT declared, the auto-projection
        # falls back to `agent_fields - agent_large_fields` (or, when only
        # `agent_large_fields` is declared, to `field_map.keys -
        # agent_large_fields`). Callers can always opt out per call by
        # passing dotted-path keys (`keys: ["user.iconImage"]`), which
        # signals explicit intent and suppresses auto-expansion for that
        # pointer.
        #
        # @example
        #   class Subscription < Parse::Object
        #     belongs_to :user
        #     property :title, :string
        #     property :active, :boolean
        #     # …
        #   end
        #
        #   # In the _User reopen / customization:
        #   class Parse::User
        #     agent_fields :first_name, :last_name, :email, :icon_image,
        #                  :source_image, :workspaces, :tenants, :last_active_at,
        #                  :category
        #     agent_large_fields :icon_image, :source_image
        #     agent_join_fields :first_name, :last_name, :email,
        #                      :last_active_at, :category
        #   end
        #
        # @param names [Array<Symbol, String>] field names to project on join
        # @return [Array<Symbol>] the resulting join-projection list
        def agent_join_fields(*names)
          return @agent_join_field_list ||= [] if names.empty?
          @agent_join_field_list = names.flatten.map(&:to_sym).freeze
          assert_agent_join_fields_subset!
          @agent_join_field_list
        end

        # Read-only accessor for the agent join-projection list.
        # @return [Array<Symbol>] the list (empty if not declared)
        def agent_join_field_list
          @agent_join_field_list || []
        end

        # Declare fields known to carry large payloads (full text, embedded
        # documents, base64 blobs, long descriptions). Schema introspection
        # annotates these with `large_field: true` so an LLM client can
        # project them away proactively in its first `query_class` call
        # rather than discovering the size by hitting the dispatcher's
        # response cap. Has no effect on Pointer/Relation type fields —
        # the stored value is a small reference; size only materializes
        # via `include:` resolution, which is a query-time concern.
        # Called without arguments, returns the current list.
        #
        # @example Flag the long-text fields up-front
        #   class Article < Parse::Object
        #     property :title, :string
        #     property :body, :string
        #     property :raw_html, :string
        #     agent_large_fields :body, :raw_html
        #   end
        #
        # @param names [Array<Symbol, String>] field names known to be large
        # @return [Array<Symbol>] the resulting list
        def agent_large_fields(*names)
          return @agent_large_fields ||= [] if names.empty?
          @agent_large_fields = names.flatten.map(&:to_sym).freeze
        end

        # Read-only accessor for the large-field list.
        # @return [Array<Symbol>] the declared large fields (empty if none)
        def agent_large_field_list
          @agent_large_fields || []
        end

        # Declare a canonical "valid state" filter for this class that the
        # agent's read tools (`query_class`, `count_objects`, `aggregate`)
        # apply BY DEFAULT to every call. Closes the silently-suspect-
        # counts gap: when a class soft-deletes via `archived`, hides
        # rows via `published: false`, or has any other always-applied
        # validity predicate, the canonical filter ensures an LLM that
        # drops to raw aggregate doesn't accidentally include the
        # excluded rows.
        #
        # The filter is a MongoDB-style match expression (the same shape
        # `query_class`'s `where:` argument accepts). When applied:
        #   - `query_class` / `count_objects`: merged with the caller's
        #     `where:` via top-level `$and` so caller constraints
        #     compose rather than override.
        #   - `aggregate`: prepended as a `$match` stage at index 0
        #     (after tenant-scope injection).
        #
        # Callers opt out per call with `apply_canonical_filter: false`.
        # The filter is also surfaced via `get_schema` so an opt-out
        # caller can reproduce it manually.
        #
        # @example
        #   class Post < Parse::Object
        #     property :archived, :boolean
        #     property :published, :boolean
        #     agent_canonical_filter "archived" => { "$ne" => true },
        #                            "published" => true
        #   end
        #
        # @param filter [Hash, nil] a where-style hash. Pass nil to
        #   read the current value.
        # @return [Hash, nil] the filter, or nil when not declared.
        def agent_canonical_filter(filter = nil)
          return @agent_canonical_filter if filter.nil?
          raise ArgumentError, "agent_canonical_filter expects a Hash, got #{filter.class}" unless filter.is_a?(Hash)
          # Validate at registration time so a developer misconfiguration
          # (e.g. `$where`, `$function`, or an internal-field key) fails at
          # app boot rather than silently bypassing PipelineValidator at
          # request time. The filter is treated like a permissive pipeline
          # node: server-side JS operators and internal-field keys are refused;
          # normal Mongo query operators ($ne, $gt, $exists, etc.) are allowed.
          begin
            Parse::PipelineSecurity.validate_filter!(filter)
          rescue Parse::PipelineSecurity::Error => e
            raise ArgumentError, "agent_canonical_filter rejected: #{e.message}"
          end
          @agent_canonical_filter = filter.transform_keys(&:to_s).freeze
        end

        # Read-only accessor for the canonical filter.
        # @return [Hash, nil] the filter as String-keyed Hash, or nil
        def agent_canonical_filter_for_apply
          @agent_canonical_filter
        end

        # Opt this class out of the global COLLSCAN refusal check.
        # Intended for small lookup tables (Roles, Config) where full scans
        # are acceptable and an index is not needed.
        #
        # @example
        #   class AppConfig < Parse::Object
        #     agent_allow_collscan true
        #   end
        #
        # @param value [Boolean] true to allow COLLSCANs for this class
        # @return [Boolean] the current setting
        def agent_allow_collscan(value = nil)
          return @agent_allow_collscan if value.nil?
          @agent_allow_collscan = value == true
        end

        # Check whether COLLSCANs are explicitly permitted for this class.
        # @return [Boolean]
        def agent_allow_collscan?
          @agent_allow_collscan == true
        end

        # Class-level analytics usage hint, surfaced inside agent schema output.
        # Distinct from `agent_description` (a short human summary): use this for
        # specific guidance the LLM needs to query the class well — enum values,
        # denormalization caveats, recommended aggregations, etc.
        #
        # @example
        #   agent_usage <<~USAGE
        #     `status` values: "active" | "archived" | "frozen".
        #     `member_count` is denormalized; recompute via _User pointer.
        #   USAGE
        #
        # @param text [String, nil] the usage text to set, or nil to read
        # @return [String, nil] the current usage hint
        def agent_usage(text = nil)
          return @agent_usage unless text
          @agent_usage = text.to_s.strip.freeze
        end

        # Storage hash for agent-allowed methods.
        # Maps method names (symbols) to their metadata hashes.
        #
        # @return [Hash<Symbol, Hash>]
        def agent_methods
          @agent_methods ||= {}
        end

        # Permission levels for agent methods (matches Parse::Agent permission levels)
        AGENT_METHOD_PERMISSIONS = %i[readonly write admin].freeze

        # Patterns that suggest a method performs write operations
        # Used to warn developers who may have misclassified a method as readonly
        WRITE_METHOD_PATTERNS = [
          /save/i, /update/i, /delete/i, /destroy/i, /create/i, /remove/i,
          /insert/i, /upsert/i, /modify/i, /set/i, /clear/i, /reset/i,
          /add/i, /append/i, /push/i, /increment/i, /decrement/i,
        ].freeze

        # Mark a method as callable by the agent with an optional description.
        # Only methods marked with this DSL can be invoked via the `call_method` tool.
        #
        # @example Mark a readonly class method (default)
        #   agent_method :find_popular, "Find songs with over 1000 plays"
        #
        # @example Mark an instance method requiring write permission
        #   agent_method :update_play_count, "Increment play count", permission: :write
        #
        # @example Mark a method requiring admin permission
        #   agent_method :reset_all_counts, "Reset all play counts to zero", permission: :admin
        #
        # @example Mark a write method that explicitly supports dry-run preview
        #   agent_method :archive, "Archive this record", permission: :admin, supports_dry_run: true
        #   def archive(dry_run: false)
        #     return { would_archive: id } if dry_run
        #     self.status = "archived"; save!
        #   end
        #
        # @param method_name [Symbol, String] the name of the method to expose
        # @param description [String, nil] optional description for LLM context
        # @param permission [Symbol] required permission level (:readonly, :write, :admin)
        # @param supports_dry_run [Boolean] whether the method accepts dry_run: true for
        #   preview-only execution. When false (default), passing dry_run: true in
        #   arguments is refused at dispatch time with :invalid_argument.
        # @param permitted_keys [Array<Symbol,String>, nil] when provided,
        #   +call_method+ refuses any +arguments+ key not in this list.
        #   Without this, an LLM (or a prompt-injection payload) can
        #   pass arbitrary keys through a method that splats with +**+,
        #   reaching protected columns like +_hashed_password+ or +ACL+.
        #   Highly recommended on any +agent_write+/+agent_admin+ method
        #   that takes a kwargs splat.
        # @param parameters [Hash, nil] when provided, a JSON Schema (as a
        #   Ruby Hash) describing the +arguments+ object. Surfaced in
        #   +tools/list+ so the LLM submits properly-shaped inputs and
        #   stricter MCP clients can validate before dispatch.
        # @return [Hash] the method metadata
        def agent_method(method_name, description = nil, permission: :readonly,
                         supports_dry_run: false, permitted_keys: nil, parameters: nil)
          method_sym = method_name.to_sym

          unless AGENT_METHOD_PERMISSIONS.include?(permission)
            raise ArgumentError, "Invalid permission level: #{permission}. Must be one of: #{AGENT_METHOD_PERMISSIONS.join(", ")}"
          end

          if permitted_keys && !permitted_keys.is_a?(Array)
            raise ArgumentError, "permitted_keys must be an Array of Symbol/String, got #{permitted_keys.class}"
          end

          # Determine if this is an instance or class method
          # Note: method_defined? checks instance methods, respond_to? checks class methods
          method_type = if method_defined?(method_sym)
              :instance
            elsif respond_to?(method_sym) || singleton_methods.include?(method_sym)
              :class
            else
              # Method not yet defined - we'll check again at runtime
              :unknown
            end

          agent_methods[method_sym] = {
            description: description&.to_s&.freeze,
            type: method_type,
            permission: permission,
            supports_dry_run: supports_dry_run == true,
            permitted_keys: permitted_keys&.map(&:to_sym)&.freeze,
            parameters: parameters,
          }
        end

        # Convenience method: mark a method as readonly-accessible (default)
        #
        # WARNING: This method checks if the method name suggests write behavior
        # (save, update, delete, etc.) and emits a warning. This helps developers
        # catch potential security misconfigurations early.
        #
        # @example
        #   agent_readonly :find_popular, "Find songs with over 1000 plays"
        #
        # @param method_name [Symbol, String] the method to expose
        # @param description [String, nil] optional description
        # @return [Hash] the method metadata
        def agent_readonly(method_name, description = nil)
          method_str = method_name.to_s

          # Warn if method name suggests it performs write operations
          if WRITE_METHOD_PATTERNS.any? { |pattern| method_str.match?(pattern) }
            warn "[Parse::Agent::MetadataDSL] WARNING: Method '#{method_name}' on #{name} " \
                 "is marked as agent_readonly but its name suggests it may perform writes. " \
                 "Consider using agent_write or agent_admin if this method modifies data."
          end

          agent_method(method_name, description, permission: :readonly)
        end

        # Convenience method: mark a method as requiring write permission
        #
        # @example
        #   agent_write :update_play_count, "Increment the play count"
        #
        # @param method_name [Symbol, String] the method to expose
        # @param description [String, nil] optional description
        # @return [Hash] the method metadata
        def agent_write(method_name, description = nil)
          agent_method(method_name, description, permission: :write)
        end

        # Convenience method: mark a method as requiring admin permission
        #
        # @example
        #   agent_admin :reset_all_counts, "Reset all play counts to zero"
        #
        # @param method_name [Symbol, String] the method to expose
        # @param description [String, nil] optional description
        # @return [Hash] the method metadata
        def agent_admin(method_name, description = nil)
          agent_method(method_name, description, permission: :admin)
        end

        # Declare a tenant scope rule for this class.
        #
        # When declared, every agent read tool (query_class, count_objects,
        # get_sample_objects, export_data query-mode, aggregate, get_object,
        # get_objects) will enforce that data access is limited to the agent's
        # bound tenant. An agent with no tenant binding (tenant_id: nil) hitting
        # a scoped class is refused with :access_denied unless the bypass
        # condition is satisfied.
        #
        # @param field [Symbol, String] the Parse field to scope on (e.g. :org_id)
        # @param from [Proc] callable receiving the agent, returning the scope value
        #   (return nil to mean "this agent has no tenant binding")
        #
        # @example
        #   class Order < Parse::Object
        #     property :org_id, :string
        #     agent_tenant_scope :org_id, from: ->(agent) { agent.tenant_id }
        #   end
        #
        def agent_tenant_scope(field, from:)
          unless from.respond_to?(:call)
            raise ArgumentError, "agent_tenant_scope :from must be a callable (Proc/lambda)"
          end
          parse_class_name = respond_to?(:parse_class) ? parse_class : name
          Parse::Agent::MetadataRegistry.register_tenant_scope(parse_class_name, field, from: from)
        end

        # Declare a bypass condition for this class's tenant scope.
        #
        # When the block returns truthy for the given agent, tenant scope
        # enforcement is skipped entirely for that agent on this class.
        # A bypass block that raises is treated as not-bypassed (fail closed).
        #
        # Without a bypass declaration, any agent whose tenant_id is nil
        # hitting a scoped class is refused.
        #
        # @yield [agent] the agent instance
        # @yieldreturn [Boolean] truthy to bypass, falsy to enforce
        #
        # @example Allow admin agents to read across tenants
        #   class Order < Parse::Object
        #     agent_tenant_scope :org_id, from: ->(agent) { agent.tenant_id }
        #     agent_tenant_scope_bypass { |agent| agent.permissions == :admin }
        #   end
        #
        def agent_tenant_scope_bypass(&block)
          raise ArgumentError, "agent_tenant_scope_bypass requires a block" unless block_given?
          parse_class_name = respond_to?(:parse_class) ? parse_class : name
          Parse::Agent::MetadataRegistry.register_tenant_scope_bypass(parse_class_name, block)
        end

        # Opt a class in to the `semantic_search` agent tool.
        #
        # Declares which `:vector` property the tool searches and which
        # fields an LLM may constrain via the tool's `filter:` /
        # `vector_filter:` inputs. Per-field opt-in is required:
        # multimodal classes can carry several vector fields, and
        # `agent_searchable` opens exactly the one named.
        #
        # @example
        #   class KnowledgeArticle < Parse::Object
        #     property :title, :string
        #     property :body, :string
        #     property :embedding, :vector, dimensions: 1536, provider: :openai
        #     embed :title, :body, into: :embedding
        #     agent_searchable field: :embedding, filter_fields: %i[published category]
        #   end
        #
        #   # Two embed text sources, so semantic_search needs text_field: to
        #   # choose which one to chunk and return as content:
        #   #   semantic_search(class_name: "KnowledgeArticle", query: "...",
        #   #                   text_field: "body")
        #
        # @param field [Symbol] the `:vector` property the tool searches.
        # @param filter_fields [Array<Symbol>] fields the agent may pass
        #   in `filter:` / `vector_filter:`. Anything not listed is
        #   refused at the tool boundary. Defaults to `[]` — an empty
        #   allowlist, which is fail-closed by design: until you enumerate
        #   fields here the agent can run only an unfiltered query plus the
        #   enforced tenant scope. This is intentional (no field is
        #   filterable until explicitly opted in), not a silent off-switch.
        # @raise [ArgumentError] when `field` is not a declared `:vector`
        #   property on the class.
        def agent_searchable(field:, filter_fields: [])
          parse_class_name = respond_to?(:parse_class) ? parse_class : name
          field_sym = field.to_sym
          if respond_to?(:vector_properties) && !vector_properties.key?(field_sym)
            raise ArgumentError,
                  "agent_searchable field: :#{field_sym} is not a declared :vector property " \
                  "on #{parse_class_name} (declared: #{vector_properties.keys.inspect})."
          end
          filters = Array(filter_fields).map(&:to_sym)
          @agent_searchable_field = field_sym
          @agent_searchable_filter_fields = filters
          Parse::Agent::MetadataRegistry.register_searchable(
            parse_class_name, field: field_sym, filter_fields: filters,
          )
        end

        # @return [Symbol, nil] the vector field declared via {#agent_searchable}.
        def agent_searchable_field
          @agent_searchable_field
        end

        # @return [Array<Symbol>] filter fields declared via {#agent_searchable}.
        def agent_searchable_filter_fields
          @agent_searchable_filter_fields || []
        end

        # Check if this model has any agent metadata defined.
        #
        # @return [Boolean] true if any metadata is present
        def has_agent_metadata?
          !agent_description.nil? ||
            !agent_usage.nil? ||
            !property_descriptions.empty? ||
            !property_enum_descriptions.empty? ||
            !agent_methods.empty? ||
            !agent_field_allowlist.empty? ||
            !agent_join_field_list.empty?
        end

        # Get all agent metadata as a hash for serialization.
        #
        # @return [Hash] all agent metadata
        def agent_metadata
          {
            description: agent_description,
            usage: agent_usage,
            property_descriptions: property_descriptions.dup,
            property_enum_descriptions: property_enum_descriptions.dup,
            methods: agent_methods.dup,
            field_allowlist: agent_field_allowlist.dup,
            join_field_list: agent_join_field_list.dup,
          }
        end

        private

        # @api private
        # Subset invariant: agent_join_fields entries must all appear in
        # agent_fields when both are declared. The direct-query allowlist
        # is the upper bound on what the agent sees; the join list can only
        # tighten that, never widen it. Raises ArgumentError when violated,
        # at class-load time, so the error surfaces immediately rather than
        # at the first agent query.
        def assert_agent_join_fields_subset!
          return unless @agent_join_field_list&.any?
          return unless @agent_field_allowlist&.any?
          extras = @agent_join_field_list - @agent_field_allowlist
          return if extras.empty?
          raise ArgumentError,
                "agent_join_fields must be a subset of agent_fields on #{self}; " \
                "#{extras.inspect} appears in agent_join_fields but not in agent_fields. " \
                "The direct-query allowlist is the upper bound; the join-projection list " \
                "can only tighten it."
        end

        public

        # Check if a specific method is allowed for agent invocation.
        #
        # @param method_name [Symbol, String] the method name to check
        # @return [Boolean] true if the method is agent-allowed
        def agent_method_allowed?(method_name)
          agent_methods.key?(method_name.to_sym)
        end

        # Get metadata for a specific agent-allowed method.
        #
        # @param method_name [Symbol, String] the method name
        # @return [Hash, nil] the method metadata or nil if not allowed
        def agent_method_info(method_name)
          agent_methods[method_name.to_sym]
        end

        # Check if an agent with given permission can call a specific method.
        # Permission hierarchy: admin > write > readonly
        #
        # @param method_name [Symbol, String] the method to check
        # @param agent_permission [Symbol] the agent's permission level
        # @return [Boolean] true if the agent can call this method
        def agent_can_call?(method_name, agent_permission)
          method_info = agent_methods[method_name.to_sym]
          return false unless method_info

          required_permission = method_info[:permission] || :readonly
          permission_allows?(agent_permission, required_permission)
        end

        # Get all methods available to an agent with given permission level.
        #
        # @param agent_permission [Symbol] the agent's permission level
        # @return [Hash<Symbol, Hash>] methods the agent can call
        def agent_methods_for(agent_permission)
          agent_methods.select do |_name, info|
            permission_allows?(agent_permission, info[:permission] || :readonly)
          end
        end

        private

        # Check if agent_permission level can access required_permission level.
        # Permission hierarchy: admin > write > readonly
        #
        # @param agent_permission [Symbol] what the agent has
        # @param required_permission [Symbol] what the method requires
        # @return [Boolean]
        def permission_allows?(agent_permission, required_permission)
          hierarchy = { readonly: 0, write: 1, admin: 2 }
          agent_level = hierarchy[agent_permission] || 0
          required_level = hierarchy[required_permission] || 0
          agent_level >= required_level
        end
      end

      # Instance method to access class-level agent description
      #
      # @return [String, nil]
      def agent_description
        self.class.agent_description
      end

      # Instance method to access class-level property descriptions
      #
      # @return [Hash<Symbol, String>]
      def property_descriptions
        self.class.property_descriptions
      end

      # Instance method to access class-level per-value enum descriptions
      #
      # @return [Hash<Symbol, Hash{String => String}>]
      def property_enum_descriptions
        self.class.property_enum_descriptions
      end

      # Instance method to access class-level agent methods
      #
      # @return [Hash<Symbol, Hash>]
      def agent_methods
        self.class.agent_methods
      end
    end
  end
end
