# encoding: UTF-8
# frozen_string_literal: true

require "timeout"
require_relative "../pipeline_security"

module Parse
  class Agent
    # The Tools module contains all the executable tool implementations
    # for the Parse Agent. Each tool is a class method that takes an agent
    # instance and keyword arguments.
    #
    # Tools are divided into categories:
    # - **Schema tools**: get_all_schemas, get_schema
    # - **Query tools**: query_class, count_objects, get_object, get_sample_objects, get_objects
    # - **Analysis tools**: aggregate, explain_query
    #
    # == Custom Tool Registration
    #
    # Third-party apps may register additional tools:
    #
    #   Parse::Agent::Tools.register(
    #     name:        :breakdown_posts,
    #     description: "Count posts grouped by author/...",
    #     parameters:  { type: "object", properties: {...}, required: [...] },
    #     permission:  :readonly,
    #     timeout:     30,
    #     handler:     ->(agent, **args) { { result: "..." } }
    #   )
    #
    # Registering a name that matches an existing registration replaces it
    # (idempotent on name). Call reset_registry! to clear all registrations
    # (useful in test suites).
    #
    module Tools
      extend self

      # Methods that are dangerous and should never be invoked via tools.
      # Defined here (rather than MCPServer) so it's always available.
      BLOCKED_METHODS = %w[
        eval exec system ` send __send__ public_send
        instance_eval class_eval module_eval
        instance_exec class_exec module_exec
        define_method define_singleton_method remove_method undef_method
        singleton_class
        open fork spawn syscall load require require_relative
        const_get const_set remove_const method binding
        instance_variable_set instance_variable_get
      ].freeze

      # Default timeout for tool operations (seconds)
      DEFAULT_TIMEOUT = 30

      # Per-tool timeout overrides for long-running operations.
      # Frozen — do not mutate. Use Tools.timeout_for(name) to resolve
      # timeouts that overlay registered-tool values on top of this table.
      TOOL_TIMEOUTS = {
        aggregate: 60,
        query_class: 30,
        explain_query: 30,
        call_method: 60,
        get_all_schemas: 15,
        get_schema: 10,
        count_objects: 20,
        get_object: 10,
        get_objects: 20,
        get_sample_objects: 15,
        export_data: 60,
        group_by: 45,
        group_by_date: 45,
        distinct: 30,
        list_tools: 5,
        atlas_text_search: 30,
        atlas_autocomplete: 15,
        atlas_faceted_search: 45,
      }.freeze

      # Per-tool clamps for Atlas Search result counts. The hard cap
      # (+ATLAS_LIMIT_MAX+) keeps response sizes predictable when an
      # LLM agent asks for "everything"; the default keeps token
      # spend reasonable when an agent forgets to set +limit:+.
      ATLAS_LIMIT_DEFAULT = 10
      ATLAS_LIMIT_MAX = 20

      # Tool definitions in OpenAI function calling format
      # Optimized for token efficiency - LLMs understand from context
      TOOL_DEFINITIONS = {
        list_tools: {
          category: "discovery",
          name: "list_tools",
          description: "Return a lightweight catalog of tools available to this agent — name, category, and a " \
                       "one-line description per tool. Use this for discovery; call tools/list (or a specific " \
                       "tool's documentation) for full input schemas. Pass category: to narrow the catalog to a " \
                       "single category (e.g. 'schema', 'query', 'aggregate', 'mutation', 'export'). The " \
                       "response also includes a `categories` map summarizing what each built-in category covers.",
          parameters: {
            type: "object",
            properties: {
              category: {
                type: "string",
                description: "Optional. Restrict the catalog to tools in this category (case-insensitive). " \
                             "Built-in categories: schema, query, aggregate, mutation, export.",
              },
            },
            required: [],
          },
          output_schema: {
            type: "object",
            properties: {
              tools: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    name:        { type: "string" },
                    category:    { type: "string" },
                    description: { type: "string" },
                  },
                  required: %w[name category description],
                },
              },
              categories: {
                type: "object",
                additionalProperties: { type: "string" },
              },
            },
            required: %w[tools categories],
          },
        },

        get_all_schemas: {
          category: "schema",
          name: "get_all_schemas",
          description: "List every Parse class the agent can see, with field counts and optional descriptions. " \
                       "Call this first when exploring an unfamiliar database. Use get_schema next for a specific class. " \
                       "Pass names: to fetch only a known subset of classes, or prefix: to filter to class names starting " \
                       "with a given string — both reduce response size on large catalogs.",
          parameters: {
            type: "object",
            properties: {
              names:  { type: "array", items: { type: "string" },
                        description: "Optional. Restrict the output to these class names (exact match)." },
              prefix: { type: "string",
                        description: "Optional. Restrict the output to class names that start with this prefix (case-sensitive)." },
            },
            required: [],
          },
          output_schema: {
            type: "object",
            properties: {
              total:    { type: "integer", minimum: 0 },
              note:     { type: "string" },
              built_in: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    name:    { type: "string" },
                    fields:  { type: "integer", minimum: 0 },
                    desc:    { type: "string" },
                    methods: { type: "integer", minimum: 0 },
                  },
                  required: %w[name fields],
                  additionalProperties: true,
                },
              },
              custom: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    name:    { type: "string" },
                    fields:  { type: "integer", minimum: 0 },
                    desc:    { type: "string" },
                    methods: { type: "integer", minimum: 0 },
                  },
                  required: %w[name fields],
                  additionalProperties: true,
                },
              },
            },
            required: %w[total built_in custom],
          },
        },

        get_schema: {
          category: "schema",
          name: "get_schema",
          description: "Return the fields, types, indexes, permissions, and relations for a single Parse class. " \
                       "Inspect the `large_field: true` annotation on individual fields — those are known-heavy " \
                       "columns that should be projected away with `keys:` in subsequent query_class calls to " \
                       "stay under the response-size cap. " \
                       "When the response contains a top-level `agent_fields:` list, those are the only " \
                       "wire-format names accepted by query/aggregate tools for this class; storage-form " \
                       "columns (e.g. `_p_*` pointer columns) and other Parse-internal underscored fields " \
                       "are never addressable. A field's `allowed_values:` array, when present, enumerates " \
                       "the per-value documentation for an enum-shaped string column.",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
            },
            required: ["class_name"],
          },
          output_schema: {
            type: "object",
            properties: {
              class_name:  { type: "string" },
              type:        { type: "string" },
              description: { type: "string" },
              usage:       { type: "string" },
              fields:      { type: "array", items: { type: "object", additionalProperties: true } },
              indexes:     { type: "object", additionalProperties: true },
              permissions: { type: "object", additionalProperties: true },
              agent_methods:     { type: "array", items: { type: "object", additionalProperties: true } },
              canonical_filter:  { type: "object", additionalProperties: true },
              agent_fields:      { type: "array", items: { type: "string" } },
              agent_join_fields: { type: "array", items: { type: "string" } },
              relations:         { type: "object", additionalProperties: true },
            },
            required: %w[class_name type fields indexes permissions],
          },
        },

        query_class: {
          category: "query",
          name: "query_class",
          description: "Fetch records from a Parse class with optional where: constraints, ordering, and pagination. " \
                       "Use this when you actually need the record content. When to use a DIFFERENT tool instead: " \
                       "count_objects for cardinality only (cheaper, no row cost); get_object for a single known " \
                       "objectId (faster, no projection needed); aggregate for groupings, statistics, or cross-class " \
                       "$lookup joins; get_sample_objects to peek at the shape of data you have not seen before. " \
                       "Default limit 100, max 1000. Pass keys: to project specific fields and avoid the 4 MiB " \
                       "response-size cap on wide-schema classes. " \
                       "When a class declares an `agent_canonical_filter` (a per-class 'valid state' predicate, " \
                       "e.g. soft-delete exclusion), it is applied by default; pass `apply_canonical_filter: false` " \
                       "to opt out (use `get_schema(class_name)` to see the filter). " \
                       "Pass `format: \"csv\"|\"markdown\"|\"table\"` to receive a formatted text payload instead of " \
                       "the row envelope — useful when the caller wants to forward the output as-is to a human. " \
                       "For more advanced formatting (column aliasing, dotted paths, custom row caps) use export_data.",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              where: { type: "object" },
              limit: { type: "integer" },
              skip: { type: "integer" },
              order: { type: "string" },
              keys: { type: "array", items: { type: "string" } },
              include: { type: "array", items: { type: "string" } },
              apply_canonical_filter: { type: "boolean",
                                        description: "Default true. When true and the class declares an " \
                                                     "agent_canonical_filter, it is merged into the where via " \
                                                     "$and so the caller's constraints compose rather than override." },
              format: { type: "string", enum: %w[json csv markdown table],
                        description: "Output format. Defaults to 'json' (structured row envelope). When set to " \
                                     "csv/markdown/table the response carries {format:, headers:, row_count:, output:} " \
                                     "instead of the row envelope; columns are inferred from the first row." },
            },
            required: ["class_name"],
          },
          # Polymorphic envelope: the default `format: "json"` returns a row
          # envelope (class_name, result_count, pagination, results, ...);
          # `format: "csv"|"markdown"|"table"` returns a text envelope
          # (class_name, format, headers, row_count, output). Declared here as
          # a permissive superset (every key from either envelope is optional
          # except class_name) because MCP 2025-06-18 expects type:object at
          # the outputSchema root, which precludes a top-level oneOf. Clients
          # that need to disambiguate inspect `format` (absent for the json
          # envelope, present for text envelopes).
          output_schema: {
            type: "object",
            properties: {
              class_name:    { type: "string" },
              # json envelope
              result_count:  { type: "integer", minimum: 0 },
              pagination: {
                type: "object",
                properties: {
                  limit:    { type: "integer", minimum: 0 },
                  skip:     { type: "integer", minimum: 0 },
                  has_more: { type: "boolean" },
                },
                required: %w[limit skip has_more],
              },
              truncated:                { type: "boolean" },
              truncated_note:           { type: "string" },
              truncated_include_fields: { type: "object", additionalProperties: true },
              next_call: {
                type: "object",
                properties: {
                  tool:      { type: "string" },
                  arguments: { type: "object", additionalProperties: true },
                },
                required: %w[tool arguments],
              },
              results: { type: "array", items: { type: "object", additionalProperties: true } },
              # csv / markdown / table envelope
              format:    { type: "string", enum: %w[csv markdown table] },
              headers:   { type: "array", items: { type: "string" } },
              row_count: { type: "integer", minimum: 0 },
              output:    { type: "string" },
            },
            required: %w[class_name],
          },
        },

        count_objects: {
          category: "query",
          name: "count_objects",
          description: "Return the count of records matching a where: constraint, WITHOUT returning the records " \
                       "themselves. Always prefer this over query_class(...).length when you only need a number — " \
                       "it is dramatically cheaper for both latency and response size. Call this before a large " \
                       "query to decide whether to paginate or narrow the where:. " \
                       "When a class declares an `agent_canonical_filter` it is applied by default; pass " \
                       "`apply_canonical_filter: false` to count the full collection including soft-deleted rows.",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              where: { type: "object" },
              apply_canonical_filter: { type: "boolean",
                                        description: "Default true. Set to false to count ignoring the class's canonical filter." },
            },
            required: ["class_name"],
          },
          output_schema: {
            type: "object",
            properties: {
              class_name:  { type: "string" },
              count:       { type: "integer", minimum: 0 },
              constraints: { type: "object" },
            },
            required: %w[class_name count constraints],
          },
        },

        get_object: {
          category: "query",
          name: "get_object",
          description: "Fetch a single record by its objectId. Use this instead of query_class(where: {objectId: 'x'}) " \
                       "— it is faster and projects cleanly. For multiple known ids in one call, use get_objects instead. " \
                       "When the class declares an `agent_canonical_filter`, it is applied by default; pass " \
                       "`apply_canonical_filter: false` to fetch the row regardless of the 'valid state' predicate.",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              object_id: { type: "string" },
              include: { type: "array", items: { type: "string" } },
              apply_canonical_filter: { type: "boolean",
                                        description: "Default true. When true and the class declares an " \
                                                     "agent_canonical_filter, the fetch is rewritten as a " \
                                                     "find_objects with where: { objectId: id, ...filter } " \
                                                     "so a filtered-out row returns 'not found'. Set to false " \
                                                     "to bypass the predicate and fetch the row directly." },
            },
            required: ["class_name", "object_id"],
          },
          output_schema: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              object_id:  { type: "string" },
              created_at: { type: %w[string null] },
              updated_at: { type: %w[string null] },
              object:     { type: "object" },
              truncated_include_fields: { type: "object" },
            },
            required: %w[class_name object_id object],
          },
        },

        get_objects: {
          category: "query",
          name: "get_objects",
          description: "Batch-fetch multiple Parse records by objectId in a single round trip. Use instead of " \
                       "issuing N separate get_object calls when you already know the ids (e.g. after resolving a " \
                       "list of pointers). Hard cap: 50 ids per call (deduplicated). For larger sets call " \
                       "query_class with `where: { 'objectId' => { '$in' => [...] } }`. " \
                       "When the class declares an `agent_canonical_filter`, it is applied by default; pass " \
                       "`apply_canonical_filter: false` to fetch the rows regardless of the 'valid state' predicate.",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string", description: "Parse class name" },
              ids: { type: "array", items: { type: "string" }, description: "Array of objectId values (max 50, dedup'd)" },
              include: { type: "array", items: { type: "string" }, description: "Pointer fields to include/resolve" },
              apply_canonical_filter: { type: "boolean",
                                        description: "Default true. When true and the class declares an " \
                                                     "agent_canonical_filter, it composes with the objectId $in " \
                                                     "constraint via $and so 'invalid state' rows are filtered out " \
                                                     "(they appear in the :missing array). Set to false to bypass." },
            },
            required: ["class_name", "ids"],
          },
          output_schema: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              objects: {
                type: "object",
                additionalProperties: { type: "object" },
                description: "Map of objectId => fetched object. Empty when no ids resolved.",
              },
              missing:   { type: "array", items: { type: "string" } },
              requested: { type: "integer", minimum: 0 },
              found:     { type: "integer", minimum: 0 },
              truncated_include_fields: { type: "object" },
            },
            required: %w[class_name objects missing requested found],
          },
        },

        get_sample_objects: {
          category: "query",
          name: "get_sample_objects",
          description: "Return a small number (default 5, max 20) of the most recently created records from a class. " \
                       "Use this for schema exploration — 'what does the data in this class actually look like?'. " \
                       "Do NOT use this to retrieve specific records (use query_class with where:) or to count " \
                       "(use count_objects).",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              limit: { type: "integer" },
            },
            required: ["class_name"],
          },
          output_schema: {
            type: "object",
            properties: {
              class_name:   { type: "string" },
              sample_count: { type: "integer", minimum: 0 },
              samples:      { type: "array", items: { type: "object" } },
              note:         { type: "string" },
            },
            required: %w[class_name sample_count samples],
          },
        },

        aggregate: {
          category: "aggregate",
          name: "aggregate",
          description: "Run a MongoDB aggregation pipeline against a Parse class. Use this for operations " \
                       "query_class cannot express: grouping ($group), statistics ($sum/$avg/$min/$max), " \
                       "joins to other classes ($lookup), faceting ($facet), or any multi-stage transformation. " \
                       "Server-side JavaScript operators ($where, $function, $accumulator, $out, $merge) are " \
                       "always refused. The result is auto-bounded to 200 rows unless your pipeline ends with an " \
                       "explicit $limit or $count stage — append $count to get a single scalar instead of a row dump. " \
                       "Pointer columns are compressed by default: `_p_<field>: \"<Class>$<id>\"` rows are " \
                       "rewritten to `<field>: \"<id>\"` and the response envelope carries a " \
                       "`pointer_classes: { <field>: <Class> }` map. Pass `compact_pointers: false` to opt out " \
                       "and receive raw Parse-on-Mongo storage shapes.",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              pipeline:   { type: "array", items: { type: "object" } },
              compact_pointers: { type: "boolean",
                                  description: "Default true. When true, storage-form pointer columns (`_p_*`) are " \
                                               "rewritten and the envelope carries a `pointer_classes` map. Set to " \
                                               "false to receive raw Mongo shapes." },
              apply_canonical_filter: { type: "boolean",
                                        description: "Default true. When true and the class declares an " \
                                                     "agent_canonical_filter, it is prepended as a $match stage so " \
                                                     "the pipeline starts from the class's 'valid state' subset. " \
                                                     "Set to false to operate on the full collection." },
            },
            required: ["class_name", "pipeline"],
          },
          output_schema: {
            type: "object",
            properties: {
              class_name:      { type: "string" },
              pipeline_stages: { type: "integer", minimum: 0 },
              result_count:    { type: "integer", minimum: 0 },
              # `route` is :mongo_direct or :parse_server but serializes
              # to a Symbol-shaped String in JSON envelopes; declare it
              # permissively as string.
              route:           { type: "string", description: "Routing tag: 'mongo_direct' or 'parse_server'." },
              # Aggregation result rows are class-shape-dependent and may
              # be the output of arbitrary $project / $group / $lookup
              # stages. Object envelopes with open property sets are the
              # honest representation.
              results: {
                type: "array",
                items: { type: "object", additionalProperties: true },
              },
              pointer_classes: {
                type: "object",
                additionalProperties: { type: "string" },
                description: "Optional. Field-name → Parse-class-name map when compact_pointers is on.",
              },
              auto_limited: { type: "boolean" },
              auto_limit:   { type: "integer", minimum: 1 },
              hint:         { type: "string" },
            },
            required: %w[class_name pipeline_stages result_count route results],
          },
        },

        explain_query: {
          category: "query",
          name: "explain_query",
          description: "Return the MongoDB execution plan for a where: query WITHOUT running the query itself. " \
                       "Use this to debug an unexpectedly slow query or before issuing a potentially expensive one " \
                       "against a large class. May refuse the plan when the global refuse_collscan flag is set and " \
                       "the query would full-scan the collection — the refusal itself tells you the where: needs a " \
                       "filter on an indexed field.",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              where: { type: "object" },
            },
            required: ["class_name"],
          },
        },

        call_method: {
          category: "mutation",
          name: "call_method",
          description: "Invoke a developer-declared `agent_method` on a Parse::Object class (class-level) or " \
                       "instance (when object_id is supplied). Use this for domain actions the read tools cannot " \
                       "express — e.g. 'set_client_description', 'archive_user', 'recalculate_totals' — that the " \
                       "application has explicitly opted into by declaring the method with the agent_method DSL. " \
                       "The target class controls validation, normalization, and side effects (notifications, " \
                       "cron, cache invalidation). PREFER this over raw create_object / update_object whenever a " \
                       "purpose-built method exists. Permission is per-method (:readonly / :write / :admin); the " \
                       "tool itself is in :readonly because the per-method gate is the real boundary.",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              method_name: { type: "string" },
              object_id: { type: "string" },
              arguments: { type: "object" },
            },
            required: ["class_name", "method_name"],
          },
        },

        group_by: {
          category: "aggregate",
          name: "group_by",
          description: "Group records by a field and aggregate (count/sum/avg/min/max). " \
                       "Use this instead of hand-writing a $group pipeline through aggregate — " \
                       "the tool auto-detects pointer fields, surfaces the pointer class in an " \
                       "envelope key, optionally flattens array fields with $unwind, and supports " \
                       "sort=value_desc/value_asc/key_desc/key_asc for top-K queries. " \
                       "Default operation is 'count'; for sum/avg/min/max pass value_field. " \
                       "Bounded to 200 groups by default (top-K friendly when sort is set).",
          parameters: {
            type: "object",
            properties: {
              class_name:     { type: "string" },
              field:          { type: "string", description: "Field to group by (wire-format name; pointers auto-detected)" },
              operation:      {
                type: "string",
                enum: %w[count sum avg average min max],
                description: "Aggregation to apply per group. Default: count.",
              },
              value_field:    { type: "string", description: "Required for sum/avg/min/max — the field to aggregate within each group." },
              where:          { type: "object", description: "Optional constraints applied via $match before grouping." },
              flatten_arrays: { type: "boolean", description: "When true, $unwind the field before grouping so individual array elements are counted." },
              sort:           {
                type: "string",
                enum: %w[value_desc value_asc key_desc key_asc],
                description: "Sort the result. Use value_desc for top-K. Default: server-natural order.",
              },
              limit:          { type: "integer", description: "Cap the number of groups returned. Default: 200, max: 1000." },
              dry_run:        { type: "boolean", description: "When true, return the constructed MongoDB pipeline without executing it. Use to inspect / hand-modify before running via the aggregate tool." },
              apply_canonical_filter: { type: "boolean",
                                        description: "Default true. When true and the class declares an " \
                                                     "agent_canonical_filter, it is prepended as a $match stage " \
                                                     "so the group operates only on the class's 'valid state' " \
                                                     "subset. Set to false to group across the full collection." },
            },
            required: ["class_name", "field"],
          },
          output_schema: {
            type: "object",
            properties: {
              class_name:     { type: "string" },
              field:          { type: "string" },
              operation:      { type: "string" },
              group_count:    { type: "integer", minimum: 0 },
              groups: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    key:   {},
                    value: { type: %w[number null] },
                  },
                  required: %w[key value],
                },
              },
              value_field:    { type: "string" },
              pointer_class:  { type: "string" },
              flatten_arrays: { type: "boolean" },
              sort:           { type: "string" },
              truncated:      { type: "boolean" },
              limit:          { type: "integer" },
            },
            required: %w[class_name field operation group_count groups limit],
          },
        },

        group_by_date: {
          category: "aggregate",
          name: "group_by_date",
          description: "Group records by a date field bucketed at a specified interval " \
                       "(year/month/week/day/hour/minute/second), with count/sum/avg/min/max. " \
                       "Use this for any time-series breakdown — it builds the correct " \
                       "$year/$month/$day/$hour/$minute/$second expressions, honors an optional " \
                       "timezone (e.g. 'America/New_York'), formats the keys as ISO date strings " \
                       "(YYYY, YYYY-MM, YYYY-MM-DD, etc.), and defaults to chronological order. " \
                       "Bounded to 200 buckets by default.",
          parameters: {
            type: "object",
            properties: {
              class_name:  { type: "string" },
              field:       { type: "string", description: "Date field to bucket on (e.g. 'createdAt', 'updatedAt', or a custom Date column)." },
              interval:    {
                type: "string",
                enum: %w[year month week day hour minute second],
                description: "Bucket size.",
              },
              operation:   {
                type: "string",
                enum: %w[count sum avg average min max],
                description: "Aggregation per bucket. Default: count.",
              },
              value_field: { type: "string", description: "Required for sum/avg/min/max — the field to aggregate within each bucket." },
              where:       { type: "object", description: "Optional constraints applied via $match before grouping." },
              timezone:    { type: "string", description: "IANA tz name (e.g. 'America/New_York') or fixed offset ('+05:00'). Default: UTC." },
              sort:        {
                type: "string",
                enum: %w[key_asc key_desc value_asc value_desc],
                description: "Sort the result. Default: key_asc (chronological).",
              },
              limit:       { type: "integer", description: "Cap the number of buckets returned. Default: 200, max: 1000." },
              dry_run:     { type: "boolean", description: "When true, return the constructed MongoDB pipeline without executing it." },
              apply_canonical_filter: { type: "boolean",
                                        description: "Default true. When true and the class declares an " \
                                                     "agent_canonical_filter, it is prepended as a $match stage " \
                                                     "so the buckets reflect only the class's 'valid state' " \
                                                     "subset. Set to false to bucket the full collection." },
            },
            required: ["class_name", "field", "interval"],
          },
          output_schema: {
            type: "object",
            properties: {
              class_name:   { type: "string" },
              field:        { type: "string" },
              interval:     { type: "string" },
              operation:    { type: "string" },
              group_count:  { type: "integer", minimum: 0 },
              groups: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    key:   { type: %w[string null] },
                    value: { type: %w[number null] },
                  },
                  required: %w[key value],
                },
              },
              value_field:  { type: "string" },
              timezone:     { type: "string" },
              sort:         { type: "string" },
              truncated:    { type: "boolean" },
              limit:        { type: "integer" },
            },
            required: %w[class_name field interval operation group_count groups sort limit],
          },
        },

        distinct: {
          category: "aggregate",
          name: "distinct",
          description: "Return the distinct values of a field, optionally filtered by where:. " \
                       "When the field is a pointer, the response strips the 'ClassName$' prefix " \
                       "from each value and surfaces the class once in the pointer_class envelope " \
                       "key — call get_objects with the returned ids if you need full records. " \
                       "Bounded to 1000 distinct values by default.",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              field:      { type: "string", description: "Field to extract distinct values from (wire-format name; pointers auto-detected)." },
              where:      { type: "object", description: "Optional constraints applied via $match before distinct." },
              sort:       {
                type: "string",
                enum: %w[asc desc],
                description: "Sort the returned values alphanumerically. Default: server-natural order.",
              },
              limit:      { type: "integer", description: "Cap the number of distinct values returned. Default: 1000, max: 5000." },
              dry_run:    { type: "boolean", description: "When true, return the constructed MongoDB pipeline without executing it." },
              apply_canonical_filter: { type: "boolean",
                                        description: "Default true. When true and the class declares an " \
                                                     "agent_canonical_filter, it is prepended as a $match stage " \
                                                     "so values are extracted only from the class's 'valid state' " \
                                                     "subset. Set to false to extract across the full collection." },
            },
            required: ["class_name", "field"],
          },
          output_schema: {
            type: "object",
            properties: {
              class_name:    { type: "string" },
              field:         { type: "string" },
              count:         { type: "integer", minimum: 0 },
              values:        { type: "array",
                               items: { type: %w[string number boolean null] } },
              pointer_class: { type: "string" },
              sort:          { type: "string" },
              truncated:     { type: "boolean" },
              limit:         { type: "integer" },
            },
            required: %w[class_name field count values limit],
          },
        },

        export_data: {
          category: "export",
          name: "export_data",
          description: "Export Parse data as CSV (default), Markdown table, or fixed-width text table. " \
                       "Use 'query' mode for simple class fetches (where/keys/order/limit) or 'aggregate' " \
                       "mode for grouped/joined queries via a MongoDB pipeline. " \
                       "Supports column aliasing via columns: — pass a string to use the field as-is, " \
                       "or {field: 'Header Name'} to rename. Dotted paths (e.g. 'subject.name') extract " \
                       "nested values when used with include:. " \
                       "IMPORTANT: hard-capped at 1000 rows by default. For large exports, first call " \
                       "count_objects to size the result, then either narrow with where:/filter pipeline " \
                       "stages or call export_data multiple times with explicit limit: and skip:. The " \
                       "tool returns truncated:true when the cap fires.",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              # query mode
              where:    { type: "object" },
              keys:     { type: "array", items: { type: "string" } },
              include:  { type: "array", items: { type: "string" } },
              order:    { type: "string" },
              limit:    { type: "integer" },
              skip:     { type: "integer" },
              # aggregate mode (mutually exclusive with where/keys/order/limit)
              pipeline: { type: "array", items: { type: "object" } },
              # output control
              columns:  {
                type: "array",
                # Each entry is either a string (used as both path and header) or a
                # single-entry { "<field>" => "<Header>" } object for renaming.
                # OpenAI rejects array properties without an `items` schema
                # (`invalid_function_parameters`: "array schema missing items.").
                items: {
                  oneOf: [
                    { type: "string" },
                    { type: "object", additionalProperties: { type: "string" } },
                  ],
                },
                description: "Column spec. Each entry is either a string (field name, used as header) " \
                             "or an object {field => header} to rename. Dotted paths supported.",
              },
              format:   {
                type: "string",
                enum: %w[csv markdown table],
                description: "Output format. Defaults to 'csv'.",
              },
              row_cap: {
                type: "integer",
                description: "Maximum rows in the formatted output. Defaults to 1000. " \
                             "When the underlying query/pipeline yields more, the result is truncated " \
                             "AND the response carries truncated:true plus available_rows:N.",
              },
            },
            required: ["class_name"],
          },
          output_schema: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              # `format` is one of csv|markdown|table; same shape as the
              # input enum.
              format:  { type: "string", enum: %w[csv markdown table] },
              headers: { type: "array", items: { type: "string" } },
              row_count: { type: "integer", minimum: 0 },
              # The serialized output is the formatted CSV / Markdown /
              # text-table string itself — clients render it as-is.
              output:  { type: "string" },
              truncated:      { type: "boolean" },
              available_rows: { type: "integer", minimum: 0 },
              row_cap:        { type: "integer", minimum: 1 },
              hint:           { type: "string" },
            },
            required: %w[class_name format headers row_count output],
          },
        },

        atlas_text_search: {
          category: "query",
          name: "atlas_text_search",
          description: "Run a MongoDB Atlas Search $search aggregation against a Parse class — full-text search " \
                       "with relevance scoring across one or more indexed fields. Use this instead of query_class " \
                       "when the user input is natural language, typo-prone, or when you need a relevance " \
                       "ranking that simple where: constraints cannot produce. Per-row ACL is enforced by an " \
                       "automatic _rperm $match injected after $search whenever the agent carries a session_token, " \
                       "acl_user, or acl_role scope; master-key agents skip the filter (intentional). " \
                       "Default limit 10, max 20. Results carry a score:; pass highlight_field: to also receive " \
                       "highlight snippets. Note: Atlas Search runs out-of-process from mongod and has " \
                       "sub-second indexing lag — do not use for read-your-own-writes.",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              query:      { type: "string", description: "Search query text. Non-empty." },
              fields:     {
                type: "array",
                items: { type: "string" },
                description: "Optional. Restrict search to these fields. When omitted, all indexed fields are " \
                             "searched. Subject to the class's agent_fields allowlist when one is declared.",
              },
              limit:      {
                type: "integer",
                description: "Optional. Max results, default 10, hard cap 20.",
              },
              highlight_field: {
                type: "string",
                description: "Optional. Field to return highlight snippets for. Subject to agent_fields allowlist.",
              },
              filter:     {
                type: "object",
                description: "Optional. Additional MongoDB filter applied after the $search stage. Same security " \
                             "validation as aggregate's pipeline: no $where / $function / $accumulator.",
              },
              apply_canonical_filter: { type: "boolean",
                                        description: "Default true. When true and the class declares an " \
                                                     "agent_canonical_filter, it is AND-merged into the " \
                                                     "post-$search $match (alongside any caller filter:) " \
                                                     "so search results come from the 'valid state' subset only." },
            },
            required: %w[class_name query],
          },
          output_schema: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              count:      { type: "integer", minimum: 0 },
              # Each row is a Parse object projected through the class's
              # agent_fields allowlist, with an Atlas-supplied `score`
              # numeric and an optional `highlights` array when the
              # caller passes highlight_field:. The row shape is class-
              # dependent so additionalProperties is open.
              results: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    score: { type: "number" },
                    highlights: {
                      type: "array",
                      items: {
                        type: "object",
                        properties: {
                          path: { type: "string" },
                          texts: {
                            type: "array",
                            items: {
                              type: "object",
                              properties: {
                                value: { type: "string" },
                                type:  { type: "string", description: "'hit' or 'text' per Atlas spec." },
                              },
                              required: %w[value],
                            },
                          },
                        },
                        required: %w[path],
                      },
                    },
                  },
                  additionalProperties: true,
                },
              },
            },
            required: %w[class_name count results],
          },
        },

        atlas_autocomplete: {
          category: "query",
          name: "atlas_autocomplete",
          description: "Atlas Search autocomplete operator — search-as-you-type prefix matching against a single " \
                       "indexed field. Use when resolving partial user input to known entity names (e.g., " \
                       "song title, artist name) for disambiguation. Requires the autocomplete analyzer to be " \
                       "configured on the named field in the search index. Per-row ACL is enforced by an " \
                       "automatic _rperm $match whenever the agent carries a session_token, acl_user, or " \
                       "acl_role scope; master-key agents skip the filter (intentional). " \
                       "Default limit 10, max 20. Returns a list of distinct suggested field values plus the " \
                       "full matching Parse objects.",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              query:      { type: "string", description: "Prefix to autocomplete against. Non-empty." },
              field:      {
                type: "string",
                description: "Field name configured for autocomplete in the search index. Must be in " \
                             "agent_fields allowlist when one is declared.",
              },
              limit:      {
                type: "integer",
                description: "Optional. Max suggestions, default 10, hard cap 20.",
              },
              fuzzy:      {
                type: "boolean",
                description: "Optional. Enable single-edit fuzzy matching. Default false.",
              },
              apply_canonical_filter: { type: "boolean",
                                        description: "Default true. When true and the class declares an " \
                                                     "agent_canonical_filter, it is applied as a post-$search " \
                                                     "$match so autocomplete suggestions exclude 'invalid state' " \
                                                     "rows that the rest of the read-tool surface hides." },
            },
            required: %w[class_name query field],
          },
          output_schema: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              field:      { type: "string" },
              # `suggestions` is the list of distinct field values that
              # matched the autocomplete query (deduped, ordered by Atlas
              # ranking). Strings only — autocomplete operates on text.
              suggestions: { type: "array", items: { type: "string" } },
              count:       { type: "integer", minimum: 0 },
              # Full matching Parse objects, projected through the class
              # agent_fields allowlist.
              results: {
                type: "array",
                items: { type: "object", additionalProperties: true },
              },
            },
            required: %w[class_name field suggestions count results],
          },
        },

        atlas_faceted_search: {
          category: "query",
          name: "atlas_faceted_search",
          description: "Atlas Search faceted query — returns bucket counts per facet alongside a list of " \
                       "matching documents. Use for UI-style faceted browsers or summary breakdowns of an " \
                       "indexed corpus. NOTE: $searchMeta cannot enforce per-row ACL at the bucket-count " \
                       "level; this tool refuses session-scoped calls. The agent must be constructed with " \
                       "master_atlas: true to use it. Default limit 10, max 20 for the result list. " \
                       "NOTE: this tool ALSO refuses when the class declares an `agent_canonical_filter` " \
                       "or when the agent has a per-class `filters:` entry for the class — bucket counts " \
                       "would leak the filtered rows. Use atlas_text_search instead (which applies both " \
                       "filters via $match), or pass `apply_canonical_filter: false` to acknowledge the " \
                       "leak risk for the canonical declaration (the per-agent filter cannot be opted out).",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              query:      { type: "string", description: "Optional. Search query text; pass empty for match-all." },
              facets:     {
                type: "object",
                description: "Facet definitions keyed by facet name. Each value is " \
                             "{ type: 'string'|'number'|'date', path: <field>, boundaries?: [...] }. " \
                             "Paths must be in agent_fields allowlist when one is declared.",
              },
              limit:      {
                type: "integer",
                description: "Optional. Max documents in the result list (NOT bucket counts), default 10, max 20.",
              },
              apply_canonical_filter: { type: "boolean",
                                        description: "Default true. When the class declares an " \
                                                     "agent_canonical_filter, this tool refuses by default. " \
                                                     "Pass false to acknowledge that $searchMeta bucket counts " \
                                                     "WILL include rows the canonical filter normally hides." },
            },
            required: %w[class_name facets],
          },
          output_schema: {
            type: "object",
            properties: {
              class_name:  { type: "string" },
              # $searchMeta lower-bound count. May be approximate for very
              # large corpora — Atlas documents this; downstream clients
              # should treat it as informative, not a precise total.
              total_count: { type: "integer", minimum: 0 },
              # Facets is a Map<facet_name, { buckets: [{_id, count}] }>.
              # Bucket _id is heterogeneous (String for string facets,
              # Number/Date for numeric/date facets), so additionalProperties:true
              # on the bucket entry keeps the contract honest without
              # bloating the schema with per-type variants.
              facets: {
                type: "object",
                additionalProperties: {
                  type: "object",
                  properties: {
                    buckets: {
                      type: "array",
                      items: { type: "object", additionalProperties: true },
                    },
                  },
                  required: %w[buckets],
                },
              },
              count:   { type: "integer", minimum: 0 },
              results: {
                type: "array",
                items: { type: "object", additionalProperties: true },
              },
            },
            required: %w[class_name total_count facets count results],
          },
        },
      }.freeze

      # Human-readable one-liners for the built-in tool categories. Used
      # by the `list_tools` discovery tool to summarize what an agent can
      # do with each category. Application-registered tools use a custom
      # `category:` value via `Tools.register(category: "...")`; the
      # default for un-categorized registrations is "custom".
      BUILTIN_CATEGORIES = {
        "schema"    => "Class introspection — discover available classes, fields, indexes, and permissions.",
        "query"     => "Read-only data access — fetch records, counts, samples, and execution plans.",
        "aggregate" => "MongoDB aggregation pipelines for grouping, statistics, and joins.",
        "mutation"  => "Domain-action methods declared via agent_method.",
        "export"    => "Bulk data export in CSV, Markdown, or fixed-width text.",
        "custom"    => "Application-registered tools not assigned to a built-in category.",
      }.freeze

      # ============================================================
      # CUSTOM TOOL REGISTRY (Feature 1)
      # ============================================================

      # Thread-safety for the mutable registry. Private constant to
      # avoid leaking mutex into public API surface.
      REGISTRY_MUTEX = Mutex.new
      private_constant :REGISTRY_MUTEX

      # Mutable registry of custom tools: Symbol name => registration Hash
      # Each entry: { definition:, permission:, timeout:, handler: }
      @registry = {}

      # Subscribers notified when the registry changes (register or
      # reset_registry!). Each entry is a callable invoked with no
      # arguments. Used by Parse::Agent::MCPRackApp::SSEBody to push
      # `notifications/tools/list_changed` MCP events onto its SSE wire.
      # Iterated under a snapshot copy outside the mutex so a
      # misbehaving subscriber cannot block subsequent register calls.
      @subscribers = []

      class << self
        # Register a custom tool. Thread-safe. Idempotent on name (replaces).
        #
        # @param name [Symbol] unique tool name (required)
        # @param description [String] human-readable description (required)
        # @param parameters [Hash] JSON Schema object definition (required)
        # @param permission [Symbol] :readonly, :write, or :admin (required)
        # @param timeout [Integer] positive seconds before ToolTimeoutError
        #   (default: 30). Enforced by Tools.invoke, which wraps the handler in
        #   Timeout.timeout. Must be >= 1 (a non-positive value raises
        #   ArgumentError, since Timeout.timeout(0) would disable the bound).
        # @param handler [Proc] lambda(agent, **args) -> Hash (required)
        # @param client_safe [Boolean] when +true+, the tool is dispatchable
        #   from a client-mode agent (one whose client has no master_key).
        #   Default +false+ — registered tools are master-key-only unless
        #   the author explicitly declares them safe for session-token
        #   contexts. The handler is responsible for routing through
        #   +agent.client+ with +agent.session_token+ rather than touching
        #   the master key directly.
        # @raise [ArgumentError] when required kwargs are missing or permission is invalid
        #
        # @note SECURITY: Registered tool handlers run as trusted code inside the
        #   gem's process. Specifically, handlers:
        #
        #   - Receive the bare Parse::Agent (can read session_token, can call
        #     internal methods, can mutate class-level metadata like
        #     agent_allow_collscan).
        #   - Bypass the COLLSCAN preflight check enforced by built-in tools
        #     when they query Parse directly (via .results_direct, Parse::MongoDB,
        #     or Parse::Object#query). Implement your own indexing discipline.
        #   - Bypass the agent_fields allowlist enforced by built-in tools when
        #     they return raw Parse::Object instances. Project fields manually
        #     in the handler.
        #   - Be wrapped by Tools.invoke in a Timeout.timeout budget equal to the
        #     handler's declared :timeout kwarg (default 30s) — so a blocking or
        #     looping handler is bounded and raises ToolTimeoutError. (Built-in
        #     tools derive their budget from TOOL_TIMEOUTS; a registered handler
        #     uses its own :timeout.) Note that Parse Server's REST surface does
        #     not accept maxTimeMS — the only timeout is this Ruby-level one, so
        #     a handler that ignores `agent.cancelled?` is interrupted only when
        #     the Timeout fires.
        #
        #   Treat the handler list as part of your application's trust boundary:
        #   register at boot from code you control; never accept registrations
        #   from configuration files at runtime.
        def register(name:, description:, parameters:, handler:,
                     permission: nil, permissions: nil,
                     timeout: DEFAULT_TIMEOUT, output_schema: nil, category: "custom",
                     client_safe: false)
          # Accept `permissions:` as an alias for the canonical `permission:`
          # (Agent.new uses the plural, so callers mix them up). `permission:`
          # remains effectively required — just no longer a hard keyword so the
          # alias can satisfy it.
          permission ||= permissions
          if permission.nil?
            raise ArgumentError, "permission: is required (:readonly, :write, or :admin)"
          end
          unless %i[readonly write admin].include?(permission)
            raise ArgumentError, "permission must be :readonly, :write, or :admin (got #{permission.inspect})"
          end
          raise ArgumentError, "handler must be a callable (Proc/lambda)" unless handler.respond_to?(:call)
          raise ArgumentError, "name is required" if name.nil?
          raise ArgumentError, "description is required" if description.nil? || description.to_s.empty?
          raise ArgumentError, "parameters is required" if parameters.nil?
          if output_schema && !output_schema.is_a?(Hash)
            raise ArgumentError, "output_schema must be a Hash (JSON Schema), got #{output_schema.class}"
          end
          category_str = category.to_s
          raise ArgumentError, "category must be a non-empty string" if category_str.empty?
          # Guarantee an enforceable wall-clock bound: Tools.invoke wraps the
          # handler in Timeout.timeout(timeout), and Timeout.timeout(0) means
          # "no timeout" — so a 0 (or fractional value that floors to 0) would
          # silently leave the handler unbounded. Require a positive integer of
          # seconds. Operators who genuinely need a long-running tool pass a
          # large value, not 0.
          if timeout.to_i < 1
            raise ArgumentError,
                  "timeout must be a positive integer number of seconds (got #{timeout.inspect}); " \
                  "Timeout.timeout(0) would disable the bound"
          end

          sym = name.to_sym
          # NEW-TOOLS-6: refuse names that collide with a builtin tool. The
          # dispatcher checks the per-process registry FIRST and only falls
          # through to the builtin when no entry is present, so a silently-
          # accepted registration named :query_class would entirely replace
          # the gated builtin — skipping assert_class_accessible!, the
          # COLLSCAN preflight, validate_keys!, the field allowlist, etc.
          # Refusing the registration at the boundary keeps the trust
          # boundary on the side where the gates already live.
          if TOOL_DEFINITIONS.key?(sym)
            raise ArgumentError,
                  "tool name #{sym.inspect} collides with a built-in tool. " \
                  "Built-in names: #{TOOL_DEFINITIONS.keys.sort.join(", ")}. " \
                  "Pick a non-colliding name; built-ins enforce security gates " \
                  "(class accessibility, field allowlist, COLLSCAN preflight) " \
                  "that a custom registration would otherwise bypass."
          end
          definition = {
            category: category_str,
            name: sym.to_s,
            description: description.to_s,
            parameters: parameters,
          }
          # When the caller declares an output_schema we attach it to
          # the definition so it surfaces in the MCP `tools/list`
          # response as `outputSchema`. Per MCP 2025-06-18, a tool
          # carrying `outputSchema` SHOULD also emit `structuredContent`
          # on the result — the dispatcher does this automatically by
          # mirroring the handler's data Hash.
          definition[:output_schema] = output_schema if output_schema

          REGISTRY_MUTEX.synchronize do
            @registry[sym] = {
              definition:    definition,
              permission:    permission,
              timeout:       timeout.to_i,
              handler:       handler,
              output_schema: output_schema,
              client_safe:   client_safe == true,
            }
          end
          notify_subscribers
          nil
        end

        # Clear all custom registrations, restoring builtins-only state.
        # Intended for test suites.
        def reset_registry!
          REGISTRY_MUTEX.synchronize { @registry.clear }
          notify_subscribers
          nil
        end

        # Subscribe to registry-changed events. The block is invoked
        # with no arguments after every {register} or {reset_registry!}
        # call. Returns a Proc that, when called, deregisters the
        # subscriber. Use to drive MCP `notifications/tools/list_changed`
        # broadcasts from the transport layer.
        #
        # The subscriber callback runs on the thread that triggered the
        # mutation. Callbacks must be fast and non-blocking; long work
        # belongs in a thread or queue that the callback posts to.
        # Exceptions raised by a subscriber are caught and logged via
        # `Kernel#warn` — one bad subscriber cannot break the registry
        # or prevent other subscribers from firing.
        #
        # @yield no arguments
        # @return [Proc] call with no arguments to deregister.
        def subscribe(&block)
          raise ArgumentError, "block required" unless block

          REGISTRY_MUTEX.synchronize { @subscribers << block }
          -> { REGISTRY_MUTEX.synchronize { @subscribers.delete(block) } }
        end

        # Remove all subscribers. Intended for test suites; do not call
        # in application code because it will silently disable
        # list-changed notifications for every connected stream.
        def reset_subscribers!
          REGISTRY_MUTEX.synchronize { @subscribers.clear }
          nil
        end

        # Dispatch a tool call. Registered tools take precedence over builtins
        # only when both share a name; otherwise each path is exclusive.
        #
        # A registered handler is wrapped in `with_timeout(sym)` so its declared
        # `timeout:` (default DEFAULT_TIMEOUT, 30s) is actually enforced —
        # without this, a custom handler that blocks or loops forever has no
        # wall-clock bound and (over the MCP streaming transport) can hold a
        # dispatcher slot indefinitely after a client disconnect. Built-in tools
        # are NOT wrapped here: each built-in already applies `with_timeout`
        # inside its own body, so wrapping the `else` branch would double-wrap.
        # `register` rejects a non-positive `timeout:`, so the budget here is
        # always >= 1s (Timeout.timeout(0) would otherwise mean "no timeout").
        #
        # @param agent [Parse::Agent] the agent instance
        # @param name [Symbol, String] tool name
        # @param kwargs [Hash] keyword arguments forwarded to handler or builtin
        # @raise [Parse::Agent::ToolTimeoutError] if a registered handler exceeds
        #   its declared timeout (handled by Agent#execute and the approval
        #   preview, which both rescue it).
        def invoke(agent, name, **kwargs)
          sym = name.to_sym
          entry = REGISTRY_MUTEX.synchronize { @registry[sym] }

          if entry
            with_timeout(sym) { entry[:handler].call(agent, **kwargs) }
          else
            Tools.send(sym, agent, **kwargs)
          end
        end

        # Resolve the permission level for a tool (builtin or registered).
        #
        # @param name [Symbol, String] tool name
        # @return [Symbol] :readonly, :write, :admin, or :unknown
        def permission_for(name)
          sym = name.to_sym
          entry = REGISTRY_MUTEX.synchronize { @registry[sym] }
          return entry[:permission] if entry

          Parse::Agent::PERMISSION_LEVELS.each do |level, tools|
            return level if tools.include?(sym)
          end
          :unknown
        end

        # Resolve the timeout for a tool (registered overlay wins over builtin table).
        #
        # @param name [Symbol, String] tool name
        # @return [Integer] seconds
        def timeout_for(name)
          sym = name.to_sym
          entry = REGISTRY_MUTEX.synchronize { @registry[sym] }
          return entry[:timeout] if entry
          TOOL_TIMEOUTS[sym] || DEFAULT_TIMEOUT
        end

        # Resolve the MCP outputSchema for a tool, if any. Checks
        # registered tools first (override path), then falls through to
        # the built-in TOOL_DEFINITIONS table. The dispatcher uses this
        # to decide whether to mirror the result data as
        # `structuredContent` in the `tools/call` response envelope.
        #
        # @param name [Symbol, String] tool name
        # @return [Hash, nil] JSON Schema Hash, or nil if not declared.
        def output_schema_for(name)
          sym = name.to_sym
          entry = REGISTRY_MUTEX.synchronize { @registry[sym] }
          return entry[:output_schema] if entry && entry[:output_schema]
          TOOL_DEFINITIONS.dig(sym, :output_schema)
        end

        # Resolve the category for a tool. Registered tools always carry
        # a category (defaulting to "custom" via {register}); built-in
        # tools have a category baked into TOOL_DEFINITIONS. Returns nil
        # only when the named tool is unknown.
        #
        # @param name [Symbol, String] tool name
        # @return [String, nil]
        def category_for(name)
          sym = name.to_sym
          entry = REGISTRY_MUTEX.synchronize { @registry[sym] }
          return entry[:definition][:category] if entry
          TOOL_DEFINITIONS.dig(sym, :category)
        end

        # Whether a tool is safe to dispatch from a client-mode agent
        # (one whose client has no master_key). Returns true for:
        #
        #   * Built-in read tools listed in CLIENT_SAFE_READ_TOOLS — these
        #     route through session-token REST endpoints that Parse Server
        #     natively authorizes (ACL + CLP + protectedFields).
        #   * Built-in mutation tools listed in CLIENT_SAFE_MUTATION_TOOLS —
        #     same REST-native authorization. The caller is responsible for
        #     additionally checking the per-agent +allow_mutations+ gate;
        #     this predicate reports REST-safety only.
        #   * Custom tools registered with +client_safe: true+ — the
        #     registering author has declared the handler safe for
        #     client-mode dispatch.
        #
        # Anything else (call_method, aggregate, atlas_*, schema tools,
        # custom tools registered without the flag) returns false.
        #
        # @param name [Symbol, String] tool name
        # @return [Boolean]
        def client_safe?(name)
          sym = name.to_sym
          return true if Parse::Agent::CLIENT_SAFE_READ_TOOLS.include?(sym)
          return true if Parse::Agent::CLIENT_SAFE_MUTATION_TOOLS.include?(sym)
          entry = REGISTRY_MUTEX.synchronize { @registry[sym] }
          entry ? entry[:client_safe] == true : false
        end

        # Returns all tool names: builtins + registered.
        #
        # @return [Array<Symbol>]
        def all_tool_names
          builtin = TOOL_DEFINITIONS.keys
          registered = REGISTRY_MUTEX.synchronize { @registry.keys }
          (builtin + registered).uniq
        end

        # Returns registered tool names that are accessible at the given permission level.
        #
        # @param permission [Symbol] :readonly, :write, or :admin
        # @return [Array<Symbol>]
        def registered_tools_for(permission)
          hierarchy = { readonly: 0, write: 1, admin: 2 }
          agent_level = hierarchy[permission] || 0
          REGISTRY_MUTEX.synchronize do
            @registry.select { |_name, entry|
              required = hierarchy[entry[:permission]] || 0
              agent_level >= required
            }.keys
          end
        end

        # Invoke every registered subscriber outside the registry mutex
        # so callback work cannot deadlock against a concurrent register
        # or reset_registry! call. Snapshot under the mutex; iterate
        # over the snapshot without it.
        #
        # @api private
        def notify_subscribers
          snapshot = REGISTRY_MUTEX.synchronize { @subscribers.dup }
          snapshot.each do |callback|
            begin
              callback.call
            rescue StandardError => e
              warn "[Parse::Agent::Tools] subscriber raised: #{e.class}: #{e.message}"
            end
          end
        end
      end

      # Get tool definitions for allowed tools, merging registered definitions.
      #
      # @param allowed_tools [Array<Symbol>] list of tool names to include
      # @param format [Symbol] output format (:openai or :mcp)
      # @param category [String, Symbol, nil] optional category filter
      #   applied AFTER the permission-based allowlist. Case-insensitive.
      #   When nil, no category filtering is applied (current behavior).
      # @return [Array<Hash>] tool definitions
      def definitions(allowed_tools, format: :openai, category: nil)
        # Build a merged definition map: builtins first, registered on top
        registered_defs = REGISTRY_MUTEX.synchronize do
          @registry.transform_values { |entry| entry[:definition] }
        end

        defs = allowed_tools.filter_map do |tool_name|
          sym = tool_name.to_sym
          registered_defs[sym] || TOOL_DEFINITIONS[sym]
        end

        if category
          want = category.to_s.downcase
          defs = defs.select { |d| d[:category].to_s.downcase == want }
        end

        case format
        when :mcp
          defs.map { |d| to_mcp_format(d) }
        else
          defs.map { |d| { type: "function", function: d } }
        end
      end

      # Convert OpenAI format to MCP format. Includes `outputSchema`
      # when the source definition carried one (registered tools that
      # opted into structured output via `Tools.register(..., output_schema:)`).
      def to_mcp_format(definition)
        mcp = {
          name: definition[:name],
          description: definition[:description],
          inputSchema: definition[:parameters],
        }
        mcp[:outputSchema] = definition[:output_schema] if definition[:output_schema]
        # Surface the tool's category as MCP `_meta`. The 2025-06-18 spec
        # allows `_meta` on tool descriptors for server-specific
        # extensions; older clients ignore unknown fields. Lets
        # spec-compliant consumers filter locally without server-side
        # support, in addition to the non-standard `params.category`
        # accepted by `tools/list`.
        mcp[:_meta] = { category: definition[:category] } if definition[:category]
        mcp
      end

      # ============================================================
      # SCHEMA TOOLS
      # ============================================================

      # Get all schemas from the Parse server
      #
      # @param agent [Parse::Agent] the agent instance
      # @return [Hash] formatted schema information
      def get_all_schemas(agent, names: nil, prefix: nil, **_kwargs)
        response = agent.client.schemas(agent.request_opts)

        unless response.success?
          raise "Failed to fetch schemas: #{response.error}"
        end

        # response.result is already the results array (Parse::Response extracts it)
        schemas = response.results

        # Filter out classes marked agent_hidden — those are denied at every
        # tool surface (see Parse::Agent::MetadataDSL#agent_hidden). This is
        # the catalog filter; the per-call denial happens in
        # assert_class_accessible! below.
        hidden = Parse::Agent::MetadataRegistry.hidden_class_names
        schemas = schemas.reject { |s| hidden.include?(s["className"]) } unless hidden.empty?

        # Per-agent `classes:` allowlist — omit catalog entries the agent
        # would be refused on. Without this, an agent constructed with
        # `classes: { only: [Post, Topic] }` would still see _User, _Role,
        # etc. in get_all_schemas and waste a tool call discovering that
        # those classes are gated. The agent's class-filter predicate
        # canonicalizes both directions (Ruby class constants in the
        # operator's only/except set vs `className` Strings from the
        # server response) so the comparison is symmetric.
        if agent && !agent.class_filter_only.nil?
          schemas = schemas.select { |s| agent.class_filter_permits?(s["className"]) }
        elsif agent && !agent.class_filter_except.nil?
          schemas = schemas.reject { |s| !agent.class_filter_permits?(s["className"]) }
        end

        # Caller-supplied filters (NEW-TOOLS-9). Applied AFTER hidden-class
        # filtering so an attacker cannot probe for hidden classes via
        # `names: ["_HiddenAdmin"]` — the entry has already been stripped.
        # `names:` is an exact-match set; `prefix:` is a case-sensitive
        # leading-substring filter. Both nil/empty means no filter.
        if names.respond_to?(:any?) && names.any?
          name_set = names.map(&:to_s)
          schemas  = schemas.select { |s| name_set.include?(s["className"]) }
        end
        if prefix.is_a?(String) && !prefix.empty?
          schemas = schemas.select { |s| s["className"].to_s.start_with?(prefix) }
        end

        # Enrich with local model metadata (descriptions, agent methods)
        enriched = MetadataRegistry.enriched_schemas(schemas, agent_permission: agent.permissions)
        enriched = enriched.map { |s| Parse::Agent::PromptHardening.sanitize_schema_for_llm(s) } if enriched.is_a?(Array)

        ResultFormatter.format_schemas(enriched)
      end

      # Parse class-name regex. Parse Server requires class names to start with
      # a letter or underscore (system classes like `_User`, `_Role`,
      # `_Session`, `_Installation`) and contain only ASCII alphanumeric plus
      # underscore. Cap at 128 chars to match the dispatcher's resource-URI
      # validator. Same shape as MCPDispatcher::IDENTIFIER_RE plus support
      # for a leading underscore to allow system classes.
      CLASS_NAME_RE = /\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/.freeze

      # Parse objectId: 10-char alphanumeric per the JS/iOS SDKs' offline-mode
      # format and Parse Server's own server-generated shape. Accept length
      # 1-32 to tolerate custom-id schemes some apps use.
      OBJECT_ID_RE = /\A[A-Za-z0-9_-]{1,32}\z/.freeze

      # agent_method names. Same shape as Ruby method names with a length cap.
      METHOD_NAME_RE = /\A[A-Za-z_][A-Za-z0-9_]{0,127}[!?=]?\z/.freeze

      # Keys that are NEVER permitted as +arguments+ to +call_method+,
      # regardless of the method's declared +permitted_keys+. These
      # reference Parse-internal columns (auth/credential state, ACL,
      # identifiers managed by Parse Server) and have no legitimate
      # use case being set by an LLM through a wrapper method that
      # splats its arguments with +**+.
      CALL_METHOD_DENIED_KEYS = %i[
        _hashed_password _password_history
        authData auth_data _auth_data
        sessionToken session_token _session_token
        ACL acl _rperm _wperm
        _perishable_token _email_verify_token
        objectId id
        createdAt created_at updatedAt updated_at
        className __type
      ].freeze

      # Framework-reserved keys that are always permitted in +arguments+
      # regardless of the method's +permitted_keys+ list. +dry_run+ is
      # gated separately by +supports_dry_run+ on the method definition.
      # Reserved kwargs the agent dispatcher may inject into an
      # +agent_method+ body. +dry_run+ is forwarded when the method
      # declared +supports_dry_run: true+. +agent+ is injected
      # whenever the method's signature declares the keyword (so the
      # author can read +agent.acl_scope_kwargs+ / +agent.acl_scope+
      # and apply the agent's identity to internal queries the method
      # runs). Neither key counts against +permitted_keys:+.
      AGENT_METHOD_RESERVED_ARG_KEYS = %i[dry_run agent].freeze

      # Refuse access to a class marked `agent_hidden`, AND validate that the
      # supplied class_name has a well-formed identifier shape. Raised at
      # every tool entry that accepts a class_name argument so an LLM cannot
      # bypass the catalog filter by naming a hidden class directly OR
      # smuggle malformed identifiers ("_User?foo=bar", "Foo; DROP TABLE")
      # through to Parse Server's URL path. The exception is caught by
      # Parse::Agent#execute and translated to a sanitized error_response.
      # @param agent [Parse::Agent, nil] when present, the agent's auth context
      #   is consulted to honor `agent_hidden(except: :master_key)` declarations.
      #   A class declared with `agent_hidden(except: :master_key)` is reachable
      #   by master-key agents (no session_token binding) but refused for
      #   session-bound ones. Passing nil falls back to the strict "every hidden
      #   class is denied" behavior, used at sites where no agent is in scope
      #   (e.g. registry introspection). Callers must propagate `agent:` to
      #   preserve the except-scope; the field-level INTERNAL_FIELDS_DENYLIST
      #   floor applies regardless of this gate.
      def assert_class_accessible!(class_name, agent: nil, op: nil)
        return if class_name.nil? || class_name.to_s.empty?

        # NEW-TOOLS-9: identifier-format check at the boundary.
        unless CLASS_NAME_RE.match?(class_name.to_s)
          raise Parse::Agent::ValidationError,
                "class_name #{class_name.inspect} is not a valid identifier. " \
                "Must start with a letter or underscore and contain only " \
                "letters, digits, and underscores (max 128 chars)."
        end

        if Parse::Agent::MetadataRegistry.hidden?(class_name)
          # `agent_hidden(except: :master_key)` — permit only when this agent
          # actually runs under master key. A session-bound agent is refused
          # regardless of operator intent; this is the "user-facing MCP never
          # sees Session, dev-MCP can" axis. The gate keys on
          # auth_context[:using_master_key], NOT on session_token emptiness —
          # an acl_user / acl_role agent also has an empty session_token but
          # is NOT master-key; using the old empty-string test would have
          # silently elevated those scoped agents past the gate.
          except = Parse::Agent::MetadataRegistry.hidden_exception_for(class_name)
          using_master_key = agent && agent.respond_to?(:auth_context) &&
                             agent.auth_context[:using_master_key] == true
          unless except == :master_key && using_master_key
            raise Parse::Agent::AccessDenied.new(class_name)
          end
        end

        # Per-agent `classes:` allowlist — deny wins, allowlist is the ceiling
        # not the floor. The global hidden gate above has already been
        # consulted (including the master-key-except bypass). This check
        # additionally enforces the operator's per-agent narrowing — a class
        # the global registry would permit is still refused if outside the
        # agent's `only:` set or inside its `except:` set. The carved-out
        # `kind: :class_filter` lets SOC tooling distinguish operator
        # narrowing from policy-level denials.
        if agent && !agent.class_filter_permits?(class_name)
          raise Parse::Agent::AccessDenied.new(
            class_name,
            "Class '#{class_name}' is outside this agent's classes: allowlist",
            kind: :class_filter
          )
        end

        # Class-Level Permissions (CLP) gate. When the agent declares a
        # scope (session_token / acl_user / acl_role) and the tool
        # specifies which CLP operation it represents, refuse at the
        # boundary if the class's CLP doesn't grant that op to any
        # entry in the agent's claim set. Master-key posture
        # (`acl_permission_strings` is nil) bypasses — same contract
        # as Parse::ACLScope. Lookup failures fail-open (Parse Server
        # still enforces CLP on its own REST surface).
        if op && agent && agent.respond_to?(:acl_permission_strings)
          perms = agent.acl_permission_strings
          unless Parse::CLPScope.permits?(class_name.to_s, op, perms)
            raise Parse::Agent::AccessDenied.new(
              class_name,
              "Class '#{class_name}' CLP refuses #{op} for the agent's scope.",
              kind: :clp_denied,
            )
          end
        end
      end
      module_function :assert_class_accessible!

      # NEW-TOOLS-9: validate an object_id argument format. objectIds in Parse
      # are usually 10-char alphanumeric; some apps use custom-id schemes
      # so we accept up to 32 chars with the broader URL-safe character set.
      def assert_object_id!(object_id)
        return if object_id.nil?
        s = object_id.to_s
        return if s.empty?  # downstream tools enforce required-ness separately
        unless OBJECT_ID_RE.match?(s)
          raise Parse::Agent::ValidationError,
                "object_id #{object_id.inspect} is not a valid identifier. " \
                "Must be 1-32 characters of letters, digits, hyphens, or underscores."
        end
      end
      module_function :assert_object_id!

      # NEW-TOOLS-9: validate a method_name argument format.
      def assert_method_name!(method_name)
        return if method_name.nil?
        s = method_name.to_s
        return if s.empty?
        unless METHOD_NAME_RE.match?(s)
          raise Parse::Agent::ValidationError,
                "method_name #{method_name.inspect} is not a valid identifier. " \
                "Must start with a letter or underscore and contain only " \
                "letters, digits, and underscores (max 128 chars, optional !/?/= suffix)."
        end
      end
      module_function :assert_method_name!

      # Resolve the effective tenant scope for a class and agent.
      #
      # Returns nil when no agent_tenant_scope is declared (back-compat) or the
      # bypass condition is satisfied. Returns { field: Symbol, value: Object }
      # when a scope should be enforced. Raises Parse::Agent::AccessDenied when
      # the agent has no tenant binding (from: returns nil) on a scoped class.
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @return [Hash, nil]
      # @raise [Parse::Agent::AccessDenied]
      def resolve_tenant_scope!(agent, class_name)
        Parse::Agent::MetadataRegistry.resolve_tenant_scope(class_name, agent)
      end
      module_function :resolve_tenant_scope!

      # Merge tenant scope into a caller-supplied `where:` hash (or nil).
      #
      # Three outcomes:
      # 1. Scope field not present in caller where → inject { field => value }.
      # 2. Scope field present with matching value (string or symbol key) → pass through.
      # 3. Scope field present with any other value → refuse with AccessDenied
      #    (caller is attempting to spoof the tenant filter).
      #
      # Returns the effective merged where hash (or nil if no scope and no where).
      #
      # @param where [Hash, nil] caller-supplied constraints
      # @param scope [Hash, nil] { field: Symbol, value: Object } from resolve_tenant_scope!
      # @param class_name [String] for the AccessDenied message
      # @return [Hash, nil]
      # @raise [Parse::Agent::AccessDenied]
      def apply_tenant_scope_to_where(where, scope, class_name)
        return where unless scope
        field     = scope[:field]
        value     = scope[:value]
        field_str = field.to_s
        field_sym = field.to_sym
        # Also check the camelCase wire form (e.g. org_id -> orgId) because an LLM
        # may pass the field using the Parse Server wire-format key rather than the
        # Ruby snake_case name.  Without this check a caller could pass
        # where: {"orgId" => "evil"} which would be silently treated as case-1
        # (absent) and the injected snake_case key would allow both keys to reach
        # ConstraintTranslator, potentially letting the camelCase value win.
        camel_str = field_str.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }
        camel_sym = camel_str.to_sym

        where_h = (where || {})
        # Collect candidate values from all four key forms (snake str/sym, camel str/sym).
        candidate_keys   = [field_str, field_sym, camel_str, camel_sym]
        present_keys     = candidate_keys.select { |k| where_h.key?(k) }
        caller_value     = present_keys.any? ? where_h[present_keys.first] : nil
        field_present    = present_keys.any?

        if !field_present
          # Case 1: field absent in any form — inject using snake_case string key.
          (where_h.dup).tap { |h| h[field_str] = value }
        elsif caller_value == value
          # Case 2: field present with the correct tenant value — pass through.
          where_h
        else
          # Case 3: field present with different value (or operator hash) — refuse.
          raise Parse::Agent::AccessDenied.new(
            class_name,
            "Tenant scope conflict: cannot override '#{field_str}' constraint for class '#{class_name}'",
          )
        end
      end
      module_function :apply_tenant_scope_to_where

      # Prepend a $match tenant scope stage at index 0 of an aggregation pipeline.
      # Always prepends unconditionally — pipeline-level interaction with existing
      # $match stages is safe because any later stage with the wrong tenant
      # produces empty results, not cross-tenant leak.
      #
      # @param pipeline [Array<Hash>]
      # @param scope [Hash, nil] { field: Symbol, value: Object }
      # @return [Array<Hash>]
      def apply_tenant_scope_to_pipeline(pipeline, scope)
        return pipeline unless scope
        # MongoDB aggregation pipelines use camelCase field names (same wire format
        # as Parse Server's stored field names). Camelize the scope field so the
        # prepended $match stage is structurally equivalent to what the LLM would
        # write when querying by the field directly.
        field     = scope[:field].to_s
        wire_key  = field.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }
        [{ "$match" => { wire_key => scope[:value] } }] + pipeline
      end
      module_function :apply_tenant_scope_to_pipeline

      # === Per-agent filter and canonical filter helpers ===
      #
      # Historically a SINGLE helper merged BOTH the class-level
      # `agent_canonical_filter` declaration AND the per-agent
      # `filters: { Class => {...} }` operator scoping, and the LLM-
      # facing `apply_canonical_filter: false` kwarg could disable
      # the combined helper — which let an adversarial LLM also drop
      # the operator's per-agent scoping (a security boundary, NOT a
      # user-facing convenience). TRACK-AGENT-7 splits the helpers
      # so the per-agent filter is UNCONDITIONAL (inviolable operator
      # scoping) while the canonical-filter remains LLM-controllable
      # via the existing kwarg (preserved semantic for that half).
      #
      # Canonical pattern at every call site:
      #
      #   effective_where = apply_tenant_scope_to_where(where, scope, class_name)
      #   effective_where = apply_per_agent_filter_to_where(effective_where, class_name, agent: agent)        # UNCONDITIONAL
      #   effective_where = apply_canonical_filter_to_where(effective_where, class_name, agent: agent) if apply_canonical_filter
      #
      # All five filter helpers use the same composition contract:
      # nil-or-empty inputs short-circuit, a single extra filter is
      # unwrapped, multiple filters wrap in $and. Wire-format shape
      # is preserved across this refactor (tests comparing hash
      # structure continue to pass).

      # Merge the per-agent per-class filter (declared via
      # `Parse::Agent.new(filters: { Class => {...} })`) into the
      # caller's where expression. This is the OPERATOR's per-agent
      # scoping and is UNCONDITIONAL — no LLM-controllable kwarg can
      # disable it. The caller's constraints compose with the
      # per-agent filter via a top-level `$and`.
      #
      # Returns the where unchanged when no per-agent filter applies.
      def apply_per_agent_filter_to_where(where, class_name, agent: nil)
        per_agent = agent && agent.respond_to?(:filter_for) ? agent.filter_for(class_name) : nil
        compose_filter_into_where(where, per_agent, class_name, helper_name: "apply_per_agent_filter_to_where")
      end
      module_function :apply_per_agent_filter_to_where

      # Merge the class's canonical "valid state" filter (declared via
      # `agent_canonical_filter`) into the caller's where expression.
      # This is per-CLASS metadata — the LLM-facing kwarg
      # `apply_canonical_filter:` (default true) controls whether
      # this helper runs.
      #
      # IMPORTANT: TRACK-AGENT-7 split — historically this helper
      # ALSO applied the per-agent filter, and a passed
      # `apply_canonical_filter: false` would silently drop both.
      # The per-agent half now lives in
      # {.apply_per_agent_filter_to_where} which is called
      # UNCONDITIONALLY by every tool. Do not re-collapse them.
      def apply_canonical_filter_to_where(where, class_name, agent: nil)
        canonical = Parse::Agent::MetadataRegistry.canonical_filter(class_name)
        compose_filter_into_where(where, canonical, class_name, helper_name: "apply_canonical_filter_to_where")
      end
      module_function :apply_canonical_filter_to_where

      # @api private
      # Shared composition primitive for the per-agent/canonical
      # where-merge helpers. Extracted so the wire-format shape
      # (nil/empty → return where unchanged, single extra unwrapped,
      # multiple extras under $and) stays identical regardless of
      # which helper assembled the filters.
      def compose_filter_into_where(where, extra, class_name, helper_name:)
        return where if extra.nil? || (extra.respond_to?(:empty?) && extra.empty?)

        if where.is_a?(Hash) && !where.empty?
          { "$and" => [extra.dup, where] }
        elsif where.nil? || (where.is_a?(Hash) && where.empty?)
          extra.dup
        else
          # Silently dropping the filter when `where` is not a Hash
          # would allow the "valid state" / per-agent restriction to
          # be bypassed by passing a non-Hash value. Raise so callers
          # discover the contract violation immediately rather than
          # receiving silently unfiltered results.
          raise ArgumentError,
                "#{helper_name}: where must be a Hash or nil/empty " \
                "when a filter is declared for #{class_name}, " \
                "got #{where.class}"
        end
      end
      module_function :compose_filter_into_where

      # Prepend the per-agent per-class filter (declared via
      # `Parse::Agent.new(filters: { Class => {...} })`) as a
      # `$match` stage. UNCONDITIONAL — no LLM kwarg can disable it.
      # Inserts AFTER any leading tenant-scope `$match` so tenant
      # isolation stays at index 0 for auditability.
      def apply_per_agent_filter_to_pipeline(pipeline, class_name, agent: nil)
        per_agent = agent && agent.respond_to?(:filter_for) ? agent.filter_for(class_name) : nil
        compose_filter_into_pipeline(pipeline, per_agent)
      end
      module_function :apply_per_agent_filter_to_pipeline

      # Prepend the class's canonical filter as a `$match` stage.
      # Inserts AFTER any leading tenant-scope `$match` so tenant
      # isolation stays at index 0 for auditability.
      # TRACK-AGENT-7 split — the per-agent half now lives in
      # {.apply_per_agent_filter_to_pipeline}.
      def apply_canonical_filter_to_pipeline(pipeline, class_name, agent: nil)
        canonical = Parse::Agent::MetadataRegistry.canonical_filter(class_name)
        compose_filter_into_pipeline(pipeline, canonical)
      end
      module_function :apply_canonical_filter_to_pipeline

      # @api private
      # Shared composition primitive for the per-agent/canonical
      # pipeline-prepend helpers.
      def compose_filter_into_pipeline(pipeline, extra)
        return pipeline if extra.nil? || (extra.respond_to?(:empty?) && extra.empty?)

        match_stage = { "$match" => extra.dup }
        if pipeline.first.is_a?(Hash) && pipeline.first.key?("$match")
          [pipeline.first, match_stage] + pipeline.drop(1)
        else
          [match_stage] + pipeline
        end
      end
      module_function :compose_filter_into_pipeline

      # Verify that a fetched record's scope field matches the bound scope value.
      # A missing field is treated as a mismatch — not a pass-through.
      #
      # @param record [Hash] a raw result hash from Parse
      # @param scope [Hash, nil] { field: Symbol, value: Object }
      # @param class_name [String] for the AccessDenied message
      # @raise [Parse::Agent::AccessDenied]
      def assert_record_in_tenant_scope!(record, scope, class_name)
        return unless scope
        field     = scope[:field].to_s
        value     = scope[:value]
        # Parse Server returns camelCase field names on the wire (e.g. orgId for
        # the Ruby field org_id). A mongo-direct hit (semantic_search's raw
        # $vectorSearch path) instead carries the field under its STORAGE column
        # — which is the class's explicit `field_map` alias when one is declared,
        # NOT the camelized form. Check all three forms (snake, naive-camel, and
        # the field_map alias) so this gate resolves the scope column the SAME way
        # the pre-search filter (Parse::Retrieval.wire_name) did. Otherwise a
        # field_map'd scope field reads as nil here and fails closed on records
        # that legitimately belong to the tenant. field_map values may be symbols,
        # so stringify; an unregistered/system class (find_class -> nil) falls
        # back to the snake/camel pair.
        camel_field = field.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }
        # Assign unconditionally (the modifier-if is the RHS, yielding nil when
        # false) so neither local is ever read before initialization.
        klass       = (Parse::Model.find_class(class_name) if defined?(Parse::Model))
        mapped      = (klass.field_map[field.to_sym].to_s if klass.respond_to?(:field_map))
        rec_value   = if record.is_a?(Hash)
            keys = [field, camel_field]
            keys << mapped if mapped && !mapped.empty?
            found = keys.find { |k| record.key?(k) }
            record[found] if found
          end
        unless rec_value == value
          raise Parse::Agent::AccessDenied.new(
            class_name,
            "Object does not belong to the agent's tenant scope for class '#{class_name}'",
          )
        end
      end
      module_function :assert_record_in_tenant_scope!

      # Walk an aggregation pipeline and enforce two boundaries that
      # `assert_class_accessible!` (top-level class only) and
      # `PipelineValidator` (operator denylist) cannot enforce:
      #
      #   1. Refuse cross-class reads into a hidden class via the `from:`
      #      or `coll:` field of `$lookup`, `$graphLookup`, `$unionWith`.
      #      Sub-pipelines inside those stages are walked recursively.
      #   2. When the top-level class has an `agent_fields` allowlist,
      #      refuse projection-shape stages (`$project`, `$addFields`,
      #      `$set`, `$unset`, `$replaceRoot`, `$replaceWith`) that name or
      #      reference fields outside the allowlist. `$facet` sub-pipelines
      #      are walked carrying the same allowlist.
      #
      # Forward-pass field tracking: each stage's allowlist check uses
      # the effective set `(source ∪ available_so_far)`, where
      # `available_so_far` accumulates fields introduced by upstream
      # stages (`$group._id` and accumulator keys, `$addFields` outputs,
      # `$lookup.as`, etc.). Schema-replacing stages (`$project`,
      # `$group`, `$bucket`, `$replaceRoot`, `$replaceWith`, `$facet`)
      # drop the source set so downstream stages can ONLY reference
      # newly-introduced fields. This unblocks the canonical "group →
      # filter → sort → limit" pattern that previously failed because
      # synthetic accumulator outputs were treated as source-class
      # references against the allowlist.
      #
      # Raises `Parse::Agent::AccessDenied` on any breach. The `Agent#execute`
      # rescue chain translates that to `error_code: :access_denied`.
      def enforce_pipeline_access_policy!(class_name, pipeline, agent: nil)
        return unless pipeline.is_a?(Array)
        source_permitted = compute_source_allowlist_for(class_name)
        walk_pipeline_with_state!(
          pipeline,
          source_permitted: source_permitted,
          available: [],
          source_addressable: true,
          agent: agent,
        )
      end
      module_function :enforce_pipeline_access_policy!

      # @api private
      # Materialize the source-class allowlist into the form the walker
      # expects (source fields ∪ ALWAYS_KEEP_FIELDS), or nil if the
      # class has no `agent_fields` declared (in which case the walker
      # short-circuits and applies no field-level enforcement).
      def compute_source_allowlist_for(class_name)
        allowlist = Parse::Agent::MetadataRegistry.field_allowlist(class_name)
        return nil unless allowlist && allowlist.any?
        allowlist.map(&:to_s) | Parse::Agent::MetadataRegistry::ALWAYS_KEEP_FIELDS
      end
      module_function :compute_source_allowlist_for

      # @api private
      # Forward-pass walker. Maintains two pieces of state across stages:
      #   * `available` — fields introduced by upstream stages (Array<String>)
      #   * `source_addressable` — whether the source-class allowlist
      #     still applies. Flipped false by schema-replacing stages
      #     ($project, $group, $bucket*, $replaceRoot, $replaceWith,
      #     $facet, $sortByCount, $count).
      # Each stage is walked with the effective permitted set computed
      # at its position; afterward, the field-delta for that stage
      # updates the state for downstream stages.
      def walk_pipeline_with_state!(pipeline, source_permitted:, available:, source_addressable:, agent:)
        return unless pipeline.is_a?(Array)
        pipeline.each do |stage|
          effective = effective_permitted_set(source_permitted, available, source_addressable)
          walk_pipeline_stage!(
            stage,
            permitted_fields: effective,
            agent: agent,
            source_permitted: source_permitted,
            available: available,
            source_addressable: source_addressable,
          )
          introduced, replaces = stage_field_delta(stage)
          if replaces
            available = introduced.dup
            source_addressable = false
          else
            available = (available | introduced)
          end
        end
      end
      module_function :walk_pipeline_with_state!

      # @api private
      # Effective permitted set at the entry of a single stage. nil
      # means "no enforcement" (source class has no `agent_fields`).
      # When the source allowlist no longer applies (a schema-replacing
      # stage flipped `source_addressable` false), the effective set
      # is just the synthetic-field accumulator.
      def effective_permitted_set(source_permitted, available, source_addressable)
        return nil if source_permitted.nil?
        set = []
        set |= source_permitted if source_addressable
        set |= available
        set
      end
      module_function :effective_permitted_set

      # @api private
      # Compute `[introduced_fields, replaces_schema]` for a single
      # pipeline stage. The forward-pass walker uses this to evolve
      # the available-fields state across stages.
      #
      # `replaces_schema: true` means downstream stages can ONLY see
      # the introduced fields (the source-class schema is gone); false
      # means the introduced fields are added on top of whatever was
      # already addressable.
      def stage_field_delta(stage)
        return [[], false] unless stage.is_a?(Hash) && !stage.empty?
        op, value = stage.first
        case op.to_s
        when "$project"
          return [[], false] unless value.is_a?(Hash)
          # Exclusion-only form (`{x: 0, y: 0}`, or `{_id: 0}` alone)
          # keeps every other source field — schema is NOT replaced.
          # Anything else (any inclusion or compute) is schema-replacing
          # to the named keys. `_id` exclusion paired with other
          # inclusions stays inclusion-mode (the canonical
          # `{name: 1, _id: 0}` shape).
          if project_is_exclusion_only?(value)
            [[], false]
          else
            [project_introduced_roots(value), true]
          end
        when "$group"
          return [["_id"], true] unless value.is_a?(Hash)
          [(["_id"] | keys_excluding_operators(value)).uniq, true]
        when "$bucket", "$bucketAuto"
          return [["_id"], true] unless value.is_a?(Hash)
          keys = ["_id"]
          output = value["output"] || value[:output]
          if output.is_a?(Hash)
            keys |= keys_excluding_operators(output)
          else
            # Both $bucket and $bucketAuto default to outputting a
            # `count` field when no explicit `output` is supplied.
            keys << "count"
          end
          [keys, true]
        when "$replaceRoot", "$replaceWith"
          # The new shape comes from an arbitrary expression. We can't
          # statically know its top-level keys without resolving
          # `$user`-style dereferences. Mark schema-replaced with no
          # known introduced fields — downstream stages can only
          # reference ALWAYS_KEEP_FIELDS via the source check if it's
          # still alive, which it isn't post-replace. Practical effect:
          # field references after $replaceRoot in an allowlisted class
          # will fail. Acceptable; replaceRoot is rarely followed by
          # further restricted reads.
          [[], true]
        when "$addFields", "$set"
          # Root-normalize the introduced names: `$addFields { "user.x": ... }`
          # should register `user` (the root the downstream walker
          # looks up via split(".").first), not the literal dotted path.
          # Mirrors the $project root-normalization.
          return [[], false] unless value.is_a?(Hash)
          [root_keys_excluding_operators(value), false]
        when "$lookup", "$graphLookup", "$unionWith"
          # $unionWith concatenates rather than embedding, so it has no
          # `as`; the safe-default `[]` from a nil as_name is correct
          # for that variant. $lookup and $graphLookup add the `as`
          # field as a new array on each existing doc.
          as_name = value.is_a?(Hash) ? (value["as"] || value[:as]) : nil
          [as_name ? [as_name.to_s] : [], false]
        when "$facet"
          [value.is_a?(Hash) ? value.keys.map(&:to_s) : [], true]
        when "$sortByCount"
          [%w[_id count], true]
        when "$count"
          # `$count: ""` is rejected by MongoDB server-side but we
          # don't want the empty string registered as an available
          # field — downstream `$match { "": ... }` would then short-
          # circuit on the empty-root guard rather than failing the
          # allowlist check cleanly. Treat as a no-op.
          [value.is_a?(String) && !value.empty? ? [value] : [], true]
        when "$unwind"
          # $unwind's `includeArrayIndex: "idx"` adds a new top-level
          # field. The unwound path itself is preserved (as scalars),
          # so this is schema-extending.
          if value.is_a?(Hash) && (idx = value["includeArrayIndex"] || value[:includeArrayIndex])
            [[idx.to_s], false]
          else
            [[], false]
          end
        when "$setWindowFields", "$fill"
          # Both stages declare new fields via an `output:` map
          # (`{output: { newField: {...} }}`). Root-normalize same as
          # $project and $addFields.
          out = value.is_a?(Hash) ? (value["output"] || value[:output]) : nil
          out.is_a?(Hash) ? [root_keys_excluding_operators(out), false] : [[], false]
        else
          [[], false]
        end
      end
      module_function :stage_field_delta

      # @api private
      # Top-level keys of a stage operand, dropping operator-prefixed
      # entries (which name aggregation expressions, not output fields).
      def keys_excluding_operators(hash)
        hash.keys.map(&:to_s).reject { |k| k.empty? || k.start_with?("$") }
      end
      module_function :keys_excluding_operators

      # @api private
      # Like {#keys_excluding_operators} but returns the ROOT segment
      # of each dotted key (`"user.name"` -> `"user"`), deduplicated.
      # Used by stages whose introduced names are addressed by the
      # downstream walker via `split(".").first` lookup.
      def root_keys_excluding_operators(hash)
        keys_excluding_operators(hash).map { |k| k.split(".").first }.uniq
      end
      module_function :root_keys_excluding_operators

      # @api private
      def projection_is_inclusion?(expr)
        expr == 1 || expr == true
      end
      module_function :projection_is_inclusion?

      # @api private
      def projection_is_exclusion?(expr)
        expr == 0 || expr == false
      end
      module_function :projection_is_exclusion?

      # @api private
      # True when every value in the $project hash is an exclusion
      # (`0` or `false`). Such a projection KEEPS every non-named
      # source field, so the forward-pass walker must not treat it
      # as schema-replacing.
      def project_is_exclusion_only?(value)
        value.any? && value.values.all? { |v| projection_is_exclusion?(v) }
      end
      module_function :project_is_exclusion_only?

      # @api private
      # Top-level field names introduced by a non-exclusion $project,
      # root-normalized. Skips exclusion entries (`x: 0`) so an
      # `{name: 1, _id: 0}` spec doesn't accidentally register `_id`
      # as the only available downstream field.
      def project_introduced_roots(value)
        included = value.reject { |_, v| projection_is_exclusion?(v) }
        root_keys_excluding_operators(included)
      end
      module_function :project_introduced_roots

      # @api private
      # Refuse output keys mirroring internal Parse Server columns.
      # Sources the superset denylist from PipelineSecurity (which
      # already covers ConstraintTranslator's where-key denylist plus
      # the extra `_tombstone`/`sessionToken`/`session_token` shapes).
      def assert_output_key_not_internal!(field_name, stage)
        fname = field_name.to_s
        if Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST.include?(fname) ||
           Parse::PipelineSecurity::INTERNAL_FIELDS_PREFIX_DENYLIST.any? { |p| fname.start_with?(p) }
          raise Parse::Agent::AccessDenied.new(
            nil,
            "#{stage} output key '#{fname}' mirrors an internal Parse Server column",
            kind: :denied_field_key,
            denied_field: fname,
          )
        end
      end
      module_function :assert_output_key_not_internal!

      # @api private
      # Per-stage policy check. `permitted_fields` is the effective set
      # at this stage's position (source ∪ available so far, or just
      # `available` after a schema-replacing upstream stage). The
      # `source_permitted` / `available` / `source_addressable` kwargs
      # are forwarded from {#walk_pipeline_with_state!} so that
      # sub-pipeline recursion ($facet branches, $lookup.pipeline) can
      # spawn their own forward-passes with the right starting state.
      # Defaults preserve backward compatibility for direct callers
      # that pass only `permitted_fields:` (the existing single-stage
      # test surface).
      def walk_pipeline_stage!(stage, permitted_fields:, agent: nil,
                               source_permitted: nil, available: [],
                               source_addressable: true)
        return unless stage.is_a?(Hash)
        stage.each do |op, value|
          case op.to_s
          when "$lookup", "$graphLookup", "$unionWith"
            target = value.is_a?(Hash) ?
              (value["from"] || value[:from] || value["coll"] || value[:coll]) : nil
            target_str = nil
            if target
              target_str = target.to_s
              # Hard structural denylist: underscore-prefixed collections
              # outside the four SDK system classes (_User/_Role/_Installation/
              # _Session) are Parse Server administrative state and never
              # reachable from an Agent pipeline, regardless of per-Agent
              # MetadataRegistry policy. Catches `from: "_Hooks"`,
              # `from: "_SCHEMA"`, `from: "_GraphQLConfig"`, etc.
              if target_str.start_with?("_") &&
                 !Parse::PipelineSecurity::ALLOWED_UNDERSCORE_COLLECTIONS.include?(target_str)
                raise Parse::Agent::AccessDenied.new(target_str)
              end
              if Parse::Agent::MetadataRegistry.hidden?(target_str)
                raise Parse::Agent::AccessDenied.new(target_str)
              end
              # Per-agent class filter — refuse $lookup.from / $unionWith.coll /
              # $graphLookup.from targets outside the agent's allowlist. Without
              # this gate, an agent with `classes: { only: [Post] }` could write
              # `$lookup: { from: "_User" }` from inside an allowed Post pipeline
              # and pull cross-class data the operator deliberately excluded.
              if agent && !agent.class_filter_permits?(target_str)
                raise Parse::Agent::AccessDenied.new(
                  target_str,
                  "Pipeline target '#{target_str}' is outside this agent's classes: allowlist",
                  kind: :class_filter
                )
              end
              # CLP gate for joined classes. A $lookup / $graphLookup /
              # $unionWith into a class whose CLP refuses `find` for the
              # agent's scope must be refused — the join would otherwise
              # surface rows the agent can't read independently. Master-
              # key bypasses (acl_permission_strings nil).
              if agent && agent.respond_to?(:acl_permission_strings)
                perms = agent.acl_permission_strings
                unless Parse::CLPScope.permits?(target_str, :find, perms)
                  raise Parse::Agent::AccessDenied.new(
                    target_str,
                    "Pipeline target '#{target_str}' CLP refuses find for the agent's scope.",
                    kind: :clp_denied,
                  )
                end
              end
            end
            # NEW-TOOLS-4: re-derive permitted_fields for the JOINED class
            # so its agent_fields allowlist applies to sub-pipeline stages.
            # The previous behavior passed `permitted_fields: nil`, which
            # meant a class with a tight allowlist (e.g. `Patient`
            # declaring `agent_fields :name, :id`) silently leaked
            # `Patient.ssn` through `$lookup.pipeline: [{ $project: { ssn: 1 } }]`.
            # MetadataRegistry.field_allowlist already merges in
            # ALWAYS_KEEP_FIELDS (objectId / createdAt / updatedAt), so a
            # join can carry the standard envelope without further work.
            sub = value.is_a?(Hash) ? (value["pipeline"] || value[:pipeline]) : nil
            if sub
              # The lookup sub-pipeline runs against the FOREIGN class's
              # documents — fresh forward-pass state, foreign allowlist.
              # ALWAYS_KEEP_FIELDS gets merged into the foreign source
              # set via compute_source_allowlist_for, so a join can
              # carry the standard envelope without further work.
              sub_source = target_str ? compute_source_allowlist_for(target_str) : nil
              walk_pipeline_with_state!(
                Array(sub),
                source_permitted: sub_source,
                available: [],
                source_addressable: true,
                agent: agent,
              )
            end
          when "$facet"
            next unless value.is_a?(Hash)
            # Each $facet branch processes the SAME input docs that
            # arrived at the $facet stage — so each branch starts with
            # the pre-facet state and evolves independently. Without
            # the state pass, a branch that did $group → $match on the
            # synthetic accumulator would have failed the way the
            # top-level pipeline used to.
            value.each_value do |sub_pipeline|
              walk_pipeline_with_state!(
                Array(sub_pipeline),
                source_permitted: source_permitted,
                available: available.dup,
                source_addressable: source_addressable,
                agent: agent,
              )
            end
          when "$project"
            # Inclusion keys (`name: 1`) reference source fields →
            # check the key against the effective allowlist. Exclusion
            # keys (`x: 0`) are NOT reads — skip the check (the field
            # is being dropped on output, not accessed). Compute/rename
            # (`x: <expr>`) introduces a new key; walk the expression
            # for source references AND screen the key against the
            # internal-column denylist so a downstream `$match { x: ... }`
            # cannot be lured into reading a column whose name mirrors
            # an internal Parse Server field.
            next unless permitted_fields && value.is_a?(Hash)
            value.each do |field, expr|
              fname = field.to_s
              next if fname.empty? || fname.start_with?("$")
              if projection_is_inclusion?(expr)
                root = fname.split(".").first
                unless permitted_fields.include?(root)
                  raise_allowlist_refusal!("field", fname, root, permitted_fields)
                end
              elsif projection_is_exclusion?(expr)
                next
              else
                assert_output_key_not_internal!(fname, "$project")
                check_expression_for_restricted_fields!(expr, permitted_fields)
              end
            end
          when "$addFields", "$set"
            # Output keys are new names — don't gate against the source
            # allowlist (they're not references). The expression VALUES
            # may reference source fields; walk those. Defense-in-depth:
            # refuse output names mirroring internal Parse Server columns
            # so a downstream stage cannot surface a misleading key.
            next unless permitted_fields && value.is_a?(Hash)
            value.each do |field, expr|
              assert_output_key_not_internal!(field.to_s, op.to_s)
              check_expression_for_restricted_fields!(expr, permitted_fields)
            end
          when "$unset"
            # Server-side unset cannot leak data, but the named field is
            # still part of the projection contract. Allow.
            next
          when "$replaceRoot", "$replaceWith"
            next unless permitted_fields && value.is_a?(Hash)
            source = value["newRoot"] || value[:newRoot] || value
            check_expression_for_restricted_fields!(source, permitted_fields)
          when "$group"
            # $group with a custom _id formula can read any field. When an
            # allowlist is in force we treat referenced fields the same as
            # projection inputs.
            next unless permitted_fields
            check_expression_for_restricted_fields!(value, permitted_fields)
          when "$match"
            # $match expressions can reference any field. Without the
            # field-name check, an attacker can run a boolean oracle on
            # +_hashed_password+ or any other +agent_hidden+ /
            # non-allowlisted column by bisecting via +$regex+ and
            # reading the row count delta. Apply the same field-name
            # restriction as projection stages.
            next unless permitted_fields && value.is_a?(Hash)
            check_match_keys_for_restricted_fields!(value, permitted_fields)
          when "$sort"
            next unless permitted_fields && value.is_a?(Hash)
            value.each_key do |field|
              fname = field.to_s
              next if fname.empty? || fname.start_with?("$")
              root = fname.split(".").first
              unless permitted_fields.include?(root)
                raise_allowlist_refusal!("sort field", fname, root, permitted_fields)
              end
            end
          when "$sortByCount"
            # $sortByCount's value is an expression (typically a
            # $-prefixed field reference like "$status", or a computed
            # expression Hash). Route it through the expression walker
            # so the grouping target is allowlist-checked — the prior
            # `value.is_a?(Hash)` guard silently skipped string values,
            # letting `$sortByCount: "$ssn"` bypass enforcement entirely.
            next unless permitted_fields
            check_expression_for_restricted_fields!(value, permitted_fields)
          when "$bucket", "$bucketAuto"
            next unless permitted_fields && value.is_a?(Hash)
            check_expression_for_restricted_fields!(value["groupBy"] || value[:groupBy], permitted_fields)
            output = value["output"] || value[:output]
            check_expression_for_restricted_fields!(output, permitted_fields) if output
          when "$unwind"
            # $unwind operates on a path. When an allowlist is in force,
            # the path's root segment must be permitted.
            next unless permitted_fields
            path = value.is_a?(Hash) ? (value["path"] || value[:path]) : value
            if path.is_a?(String) && path.start_with?("$")
              ref = path.sub(/\A\$/, "").split(".").first
              if ref && !ref.empty? && !permitted_fields.include?(ref)
                raise_allowlist_refusal!("unwind path", path, ref, permitted_fields)
              end
            end
          when "$redact"
            # $redact lets the pipeline reference arbitrary fields via
            # $$KEEP/$$PRUNE expressions. Defense-in-depth: walk it.
            next unless permitted_fields
            check_expression_for_restricted_fields!(value, permitted_fields)
          end
        end
      end
      module_function :walk_pipeline_stage!

      # @api private
      # Walk a $match hash refusing field keys outside the allowlist.
      # Logical operators ($and/$or/$nor/$not) recurse. $expr expressions
      # use the field-reference walker (which understands +$fieldName+
      # strings) and are also blocked at the +PipelineSecurity+ layer
      # for forensic operators inside +$expr+.
      def check_match_keys_for_restricted_fields!(node, permitted_fields)
        return unless node.is_a?(Hash)
        node.each do |k, v|
          ks = k.to_s
          if %w[$and $or $nor].include?(ks)
            Array(v).each { |sub| check_match_keys_for_restricted_fields!(sub, permitted_fields) }
          elsif ks == "$not"
            check_match_keys_for_restricted_fields!(v, permitted_fields)
          elsif ks == "$expr"
            check_expression_for_restricted_fields!(v, permitted_fields)
          elsif ks.start_with?("$")
            # Top-level $ operator without a field — pass; depth limit
            # and denylist already cover dangerous shapes elsewhere.
            next
          else
            root = ks.split(".").first
            next if root.nil? || root.empty?
            unless permitted_fields.include?(root)
              raise_allowlist_refusal!("match field", ks, root, permitted_fields)
            end
          end
        end
      end
      module_function :check_match_keys_for_restricted_fields!

      # @api private
      # Recursively scan a Mongo-style expression for `$field` references
      # outside the allowlist. Reused by $replaceRoot/$group enforcement.
      def check_expression_for_restricted_fields!(expr, permitted_fields)
        case expr
        when String
          if expr.start_with?("$") && !expr.start_with?("$$")
            ref = expr.sub(/\A\$/, "").split(".").first
            return if ref.empty? || ref.start_with?("$")
            unless permitted_fields.include?(ref)
              raise_allowlist_refusal!("field reference", expr, ref, permitted_fields)
            end
          end
        when Array
          expr.each { |e| check_expression_for_restricted_fields!(e, permitted_fields) }
        when Hash
          expr.each_value { |v| check_expression_for_restricted_fields!(v, permitted_fields) }
        end
      end
      module_function :check_expression_for_restricted_fields!

      # @api private
      # Build a structured refusal message for an allowlist violation. The
      # message includes:
      #   - the stage context (e.g., "field", "sort field", "match field")
      #   - the offending name and its first path segment
      #   - the actual allowlist for the class (capped at 20 names so the
      #     message stays compact on wide schemas)
      #   - a one-shot rewrite hint when the violation looks like a
      #     Parse-on-Mongo storage-form reference ($_p_foo). The mongo
      #     storage column is the implementation detail; the bare pointer
      #     field name (`$foo`) is what the agent should reference.
      ALLOWLIST_PREVIEW_CAP = 20

      # @api private
      # Build the prose refusal message AND the structured fields the
      # exception carries (kind, denied_field, allowed_fields,
      # suggested_rewrite). The structured fields land in the response
      # envelope under `details:` so MCP consumers can branch on the
      # specific subcode without parsing prose.
      def build_allowlist_refusal(context, fname, root, permitted_fields)
        msg = +"#{context} '#{fname}' (#{root.inspect}) outside agent_fields allowlist"
        if permitted_fields.is_a?(Array) && permitted_fields.any?
          preview = permitted_fields.first(ALLOWLIST_PREVIEW_CAP)
          suffix  = permitted_fields.size > ALLOWLIST_PREVIEW_CAP ?
            " (+#{permitted_fields.size - ALLOWLIST_PREVIEW_CAP} more)" : ""
          msg << ". Allowed: #{preview.join(", ")}#{suffix}"
        end
        kind = :field_denied
        suggested = nil
        if root.is_a?(String) && root.start_with?("_p_")
          kind = :storage_form_field_ref
          bare = root.sub(/\A_p_/, "")
          if !bare.empty? && permitted_fields.is_a?(Array) && permitted_fields.include?(bare)
            suggested = "$#{bare}"
            msg << ". Hint: '#{root}' is the Parse-on-Mongo storage column for the '#{bare}' pointer field — reference '#{bare}' directly (e.g. '#{suggested}')"
          else
            msg << ". Hint: '#{root}' is the Parse-on-Mongo storage column form; reference the bare pointer field name without the '_p_' prefix"
          end
        end
        {
          message:           msg,
          kind:              kind,
          denied_field:      root.is_a?(String) ? root : root.to_s,
          allowed_fields:    permitted_fields.is_a?(Array) ? permitted_fields.first(ALLOWLIST_PREVIEW_CAP).map(&:to_s) : nil,
          suggested_rewrite: suggested,
        }
      end
      module_function :build_allowlist_refusal

      # @api private
      # Helper: raise AccessDenied with the structured payload from
      # build_allowlist_refusal. Used by every pipeline-walker refusal
      # site so they all emit the same shape.
      def raise_allowlist_refusal!(context, fname, root, permitted_fields)
        info = build_allowlist_refusal(context, fname, root, permitted_fields)
        raise Parse::Agent::AccessDenied.new(
          nil, info[:message],
          kind:              info[:kind],
          denied_field:      info[:denied_field],
          allowed_fields:    info[:allowed_fields],
          suggested_rewrite: info[:suggested_rewrite],
        )
      end
      module_function :raise_allowlist_refusal!

      # Resolve each dotted `include:` path through belongs_to / has_one
      # reflections starting from `class_name` and refuse any path whose
      # terminal target is a hidden class. Best-effort: paths that don't
      # resolve through declared references (e.g., free-form server-side
      # names) fall through; the post-fetch `redact_hidden_classes!` walker
      # provides defense-in-depth for those.
      def assert_include_paths_accessible!(class_name, include_paths, agent: nil)
        return if include_paths.nil? || include_paths.empty?
        return unless class_name
        klass = begin
            Parse::Model.find_class(class_name.to_s)
          rescue StandardError
            nil
          end
        return unless klass.respond_to?(:references)

        include_paths.each do |path|
          walk_pointer_path!(klass, path.to_s.split("."), agent: agent)
        end
      end
      module_function :assert_include_paths_accessible!

      # Auto-projection for `keys: + include:`. When the caller passed a
      # `keys:` projection AND named a bare pointer field in both `keys:`
      # and `include:`, expand `keys` to dotted-path projections of the
      # joined class so Parse Server returns only the projected subfields
      # of the included record instead of the entire row.
      #
      # The expansion is suppressed when the caller passed any `<pointer>.*`
      # dotted path of their own — that's the explicit "I named exactly
      # what I want" signal. It's also suppressed when no `keys:` was
      # passed at all (caller chose full-row mode) and when the include is
      # multi-hop (`author.workspace`); auto-projection is one-hop only.
      #
      # Pointer-to-joined-class resolution uses the parent class's
      # `references` reflection (same source `walk_pointer_path!` uses),
      # accepting both snake_case Ruby names and camelCase wire names so
      # callers can pass either form in `include:`.
      #
      # @param class_name [String] the parent Parse class name
      # @param keys [Array<String>, nil] caller-supplied keys (post-validation)
      # @param include_arr [Array<String>, nil] caller-supplied include (post-validation)
      # @return [Hash] {effective_keys: Array<String> or nil, truncated: Hash}
      #   `effective_keys` is the rewritten keys array (or the input
      #   verbatim if no expansion fired). `truncated` is a hash keyed by
      #   pointer wire-name with metadata `{dropped:, source:}` per
      #   expanded pointer — used to populate the response envelope's
      #   `truncated_include_fields` so the LLM can see which joins were
      #   auto-projected and re-ask via dotted paths if it needs more.
      def apply_include_projection(class_name, keys, include_arr)
        result = { effective_keys: keys, truncated: {} }
        return result if keys.nil? || keys.empty?
        return result if include_arr.nil? || include_arr.empty?

        parent_klass = begin
            Parse::Model.find_class(class_name.to_s)
          rescue StandardError
            nil
          end
        return result unless parent_klass.respond_to?(:references)

        keys_str = keys.map(&:to_s)
        # Index dotted paths per top-level segment so we can detect
        # caller-explicit per-pointer projection ("user.iconImage" suppresses
        # auto-expansion for `user`).
        caller_dotted = keys_str.each_with_object(Hash.new { |h, k| h[k] = [] }) do |k, h|
          next unless k.include?(".")
          root, = k.split(".", 2)
          h[root] << k
        end

        # Only consider one-hop includes; multi-hop (`author.workspace`) leaves
        # the author projection alone and lets the deeper hop materialize
        # fully — keeps the auto-expansion bounded and avoids walking the
        # full relation graph at query time.
        single_hop_includes = include_arr.map(&:to_s).reject { |p| p.include?(".") }
        return result if single_hop_includes.empty?

        appended = []
        truncated = {}

        single_hop_includes.each do |pointer_field|
          ptr_str = pointer_field.to_s
          # Caller named the pointer in `keys:` — otherwise the auto-projection
          # has nothing to attach to. (`include: ["user"]` without `keys:
          # ["user"]` is caller error; Parse Server wouldn't return the
          # pointer column at all in that case.)
          next unless keys_str.include?(ptr_str)
          # Caller passed `<pointer>.something` — explicit projection mode,
          # leave their dotted paths alone, do not auto-expand.
          next if caller_dotted[ptr_str].any?

          target_class = resolve_pointer_target(parent_klass, ptr_str)
          next unless target_class

          projection = Parse::Agent::MetadataRegistry.join_projection_fields(target_class)
          next unless projection

          # Build dotted-path projections; dedupe to avoid wire bloat if the
          # caller already named some of these (e.g. they passed `user.email`
          # earlier but we just rejected the auto-expansion — defensive
          # belt-and-suspenders since the rejection branch above also short-
          # circuits).
          new_paths = projection[:project].map { |field| "#{ptr_str}.#{field}" }
          appended.concat(new_paths)
          truncated[ptr_str] = {
            dropped: projection[:dropped],
            source: projection[:source],
          }
        end

        return result if appended.empty?

        effective = (keys_str | appended)
        { effective_keys: effective, truncated: truncated }
      end
      module_function :apply_include_projection

      # @api private
      # Resolve a one-hop pointer field name on `parent_klass` to its
      # target Parse class name. Accepts both snake_case Ruby names and
      # camelCase wire names (mirrors `walk_pointer_path!`).
      def resolve_pointer_target(parent_klass, pointer_field)
        refs = parent_klass.references
        return nil unless refs
        seg_str   = pointer_field.to_s
        camel_str = seg_str.include?("_") ? seg_str.gsub(/_([a-z])/) { Regexp.last_match(1).upcase } : seg_str
        target = refs[seg_str.to_sym] || refs[seg_str] || refs[camel_str.to_sym] || refs[camel_str]
        target&.to_s
      end
      module_function :resolve_pointer_target

      # @api private
      def walk_pointer_path!(klass, segments, agent: nil)
        current = klass
        segments.each do |seg|
          refs = current.respond_to?(:references) ? current.references : nil
          return unless refs
          # `references` is keyed by the Parse field name (camelCase). Accept
          # both forms: snake_case as Ruby methods are usually named, and
          # camelCase as it appears on the wire and in the schema.
          seg_str   = seg.to_s
          camel_str = seg_str.include?("_") ? seg_str.gsub(/_([a-z])/) { Regexp.last_match(1).upcase } : seg_str
          target = refs[seg_str.to_sym] || refs[seg_str] || refs[camel_str.to_sym] || refs[camel_str]
          return unless target
          # target is the Parse class name as a String
          target_name = target.to_s
          if Parse::Agent::MetadataRegistry.hidden?(target_name)
            raise Parse::Agent::AccessDenied.new(target_name)
          end
          # Per-agent allowlist: refuse pointer-include resolution that
          # crosses into a class outside the agent's `classes:` set. Without
          # this check, an agent with `classes: { only: [Post] }` could
          # follow `include: ["author.session"]` and pull `_User` + `_Session`
          # rows into the response — defeating the narrowing the operator
          # declared. Strict-hidden master-key-except classes still apply
          # the registry gate above; this is the per-agent overlay.
          if agent && !agent.class_filter_permits?(target_name)
            raise Parse::Agent::AccessDenied.new(
              target_name,
              "Pointer-include target '#{target_name}' is outside this agent's classes: allowlist",
              kind: :class_filter
            )
          end
          current = begin
              Parse::Model.find_class(target_name)
            rescue StandardError
              nil
            end
          return unless current
        end
      end
      module_function :walk_pointer_path!

      # Post-fetch defense-in-depth: walk the result data and replace any
      # nested object whose `className` matches a hidden class with a
      # redacted placeholder. Catches paths that bypass
      # `assert_include_paths_accessible!` (free-form `include:` names,
      # server-side $lookup output, anything we can't resolve via belongs_to
      # reflection at request time).
      def redact_hidden_classes!(data, agent: nil)
        hidden = Parse::Agent::MetadataRegistry.hidden_class_names
        # Always walk for internal-field stripping even when the hidden-class
        # set is empty — `walk_and_redact` does double duty as the per-process
        # floor that drops `INTERNAL_FIELDS_DENYLIST` keys (sessionToken,
        # _hashed_password, etc.) from every nested document in the response.
        # The denylist must apply regardless of class-visibility state: a
        # deliberate `agent_unhidden` on `_Session` exposes the class to the
        # agent surface but the bearer token still gets stripped here.
        #
        # When an `agent:` is propagated, the walker ALSO redacts nested
        # objects whose className is outside the agent's per-agent allowlist.
        # This is the defense-in-depth complement to walk_pointer_path! and
        # walk_pipeline_stage!: those gates refuse the join up-front, but a
        # server-side $lookup we couldn't statically resolve (free-form
        # `from:` value, raw pipeline path) can still produce off-allowlist
        # rows. The walker scrubs them post-fetch.
        walk_and_redact(data, hidden, agent: agent)
      end
      module_function :redact_hidden_classes!

      # Parse-on-Mongo pointer column shape: a string value paired with a
      # `_p_<field>` column whose value matches `<ClassName>$<objectId>`.
      # Raw aggregate results expose this storage form unchanged. The
      # standard `walk_and_redact` matches hash shapes with `className`,
      # so the string form bypasses redaction unless we look for it
      # explicitly.
      POINTER_STORAGE_VALUE_RE = /\A([A-Za-z_][A-Za-z0-9_]*)\$(.+)\z/.freeze

      # @api private
      def walk_and_redact(obj, hidden, agent: nil)
        case obj
        when Hash
          cn = obj["className"] || obj[:className]
          if cn
            cn_str = cn.to_s
            if hidden.include?(cn_str) ||
               (agent && !agent.class_filter_permits?(cn_str))
              if obj["className"]
                return { "className" => cn_str, "__redacted" => true }
              else
                return { className: cn_str, __redacted: true }
              end
            end
          end
          obj.each_with_object({}) do |(k, v), acc|
            # Process-level field floor: drop INTERNAL_FIELDS_DENYLIST keys
            # (sessionToken, _hashed_password, _session_token, _auth_data*,
            # _rperm/_wperm, etc.) from every hash node, regardless of class.
            # This is the credential-stripping layer that must hold even when
            # an operator has deliberately unhidden the containing class.
            # Refused at this depth-walking pass so nested includes / $lookup
            # results / pointer subdocuments are all covered uniformly.
            k_str = k.to_s
            next if Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST.include?(k_str)
            next if Parse::PipelineSecurity::INTERNAL_FIELDS_PREFIX_DENYLIST.any? { |prefix| k_str.start_with?(prefix) }

            # Pointer-storage string values (`"<ClassName>$<objectId>"`) that
            # reference a hidden class are scrubbed by replacing the value
            # with a redacted placeholder regardless of the key name.
            #
            # The original guard only fired when the key started with `_p_`,
            # which is the Parse-on-Mongo storage column convention. A
            # pipeline that re-projects or groups such a column under an
            # arbitrary output key (e.g. `$project { "leak" => "$_p_secret" }`
            # or `$group { "_id" => "$_p_secret" }`) produces rows like
            # `{"leak" => "HiddenClass$abc123"}` where the key is NOT `_p_*`.
            # The fix: check EVERY string value against the regex and scrub
            # whenever the extracted class name is in the hidden set. Visible
            # class pointer strings are unaffected because `hidden.include?`
            # only fires for registered-hidden classes.
            if v.is_a?(String) &&
               (m = POINTER_STORAGE_VALUE_RE.match(v)) &&
               (hidden.include?(m[1]) ||
                (agent && !agent.class_filter_permits?(m[1])))
              acc[k] = if k.is_a?(String)
                  { "className" => m[1], "__redacted" => true }
                else
                  { className: m[1], __redacted: true }
                end
            else
              acc[k] = walk_and_redact(v, hidden, agent: agent)
            end
          end
        when Array
          obj.map { |v| walk_and_redact(v, hidden, agent: agent) }
        else
          obj
        end
      end
      module_function :walk_and_redact

      # Compact Parse-on-Mongo storage-form pointer columns.
      #
      # Raw aggregate results expose pointer fields as
      # `_p_<field>: "<ClassName>$<objectId>"`. For result sets with many
      # rows that share a few distinct pointer columns, the repeated
      # `_p_` column-name prefix and the per-value `<ClassName>$` prefix
      # together account for substantial wasted bytes — e.g., 130 rows of
      # `_p_author: "_User$xxxxx"` repeats the `_User$` prefix 130 times
      # for a value the schema already encodes.
      #
      # This pass:
      #   1. Walks the result set once to identify every `_p_<field>`
      #      column and the set of class names observed in its values.
      #   2. For any column whose class name is INVARIANT across all rows
      #      (the common case, since pointer columns are typed at schema
      #      level), strips the `_p_` prefix from the column name and the
      #      `<ClassName>$` prefix from each value.
      #   3. Returns the `{ <field> => <class_name>, ... }` map so the
      #      caller can attach it to the response envelope as
      #      `pointer_classes:`. The map preserves the type information
      #      that was stripped from individual values.
      #
      # Columns with mixed class names (anomaly — possible via custom
      # `$project` or bad data) are LEFT UNCOMPRESSED to avoid losing
      # disambiguating data. Columns that already have a non-prefixed
      # collision (e.g., row contains BOTH `_p_author` AND `author`) are
      # also left uncompressed — renaming would shadow the existing
      # value.
      #
      # MUTATES `data` in place. The hidden-class string scrub in
      # `walk_and_redact` runs BEFORE this pass, so any `_p_*` columns
      # referencing a hidden class have already been replaced with a
      # redacted placeholder hash and are skipped by this walker.
      #
      # @param data [Array, Hash] aggregate result(s)
      # @return [Hash] `{ "<field>" => "<className>" }` for every column
      #   that was compressed. Empty hash when nothing qualified.
      def compact_pointers!(data)
        # Pass 1: scan. For every key that starts with `_p_`, observe
        # the className portion of each string value across the entire
        # result set. Also note any naming collisions per nesting scope.
        observations = {}  # { "field" => Set[className] | :mixed | :collision }
        scan_for_pointer_columns(data, observations)

        # Decide which columns are safe to compress: exactly one
        # observed className, no collision detected.
        compressible = observations.each_with_object({}) do |(field, observed), acc|
          next if observed == :collision
          next unless observed.is_a?(Hash) && observed.size == 1
          acc[field] = observed.keys.first
        end
        return {} if compressible.empty?

        # Pass 2: rewrite. Walk again and replace `_p_<field>` keys with
        # `<field>` and strip the `<class>$` prefix from each value.
        rewrite_pointer_columns!(data, compressible)
        compressible
      end
      module_function :compact_pointers!

      # @api private
      # Walk `obj` collecting className observations into `acc` keyed by
      # the bare field name (the `_p_` prefix stripped). When a key has
      # both `_p_foo` and `foo` shapes in the same hash, marks it as a
      # collision so the rewrite pass skips it.
      def scan_for_pointer_columns(obj, acc)
        case obj
        when Hash
          # Identify in-hash collisions: both _p_foo and foo present.
          bare_keys = {}
          obj.each_key do |k|
            ks = k.to_s
            if ks.start_with?("_p_")
              bare = ks.sub(/\A_p_/, "")
              bare_keys[bare] ||= []
              bare_keys[bare] << :prefixed
            else
              bare_keys[ks] ||= []
              bare_keys[ks] << :bare
            end
          end
          obj.each do |k, v|
            ks = k.to_s
            if ks.start_with?("_p_") && v.is_a?(String) &&
               (m = POINTER_STORAGE_VALUE_RE.match(v))
              field = ks.sub(/\A_p_/, "")
              if bare_keys[field]&.include?(:bare)
                acc[field] = :collision
              else
                cur = acc[field]
                if cur == :collision
                  # already poisoned
                elsif cur.is_a?(Hash)
                  cur[m[1]] = true
                else
                  acc[field] = { m[1] => true }
                end
              end
            else
              scan_for_pointer_columns(v, acc)
            end
          end
        when Array
          obj.each { |v| scan_for_pointer_columns(v, acc) }
        end
      end
      module_function :scan_for_pointer_columns

      # @api private
      # Mutates `obj` in place: rewrites every `_p_<field>` key whose
      # bare form is in `compressible` to the bare key, stripping the
      # `<ClassName>$` prefix from the value.
      def rewrite_pointer_columns!(obj, compressible)
        case obj
        when Hash
          rename_pairs = []
          obj.each do |k, v|
            ks = k.to_s
            if ks.start_with?("_p_") && v.is_a?(String)
              field = ks.sub(/\A_p_/, "")
              if compressible.key?(field) &&
                 (m = POINTER_STORAGE_VALUE_RE.match(v)) &&
                 m[1] == compressible[field]
                rename_pairs << [k, field, m[2]]
                next
              end
            end
            rewrite_pointer_columns!(v, compressible)
          end
          rename_pairs.each do |old_k, new_k, new_v|
            obj.delete(old_k)
            # Match the new key's type to the original to keep the
            # caller's expectations consistent (Symbol-keyed hashes
            # stay Symbol-keyed; String-keyed stay String-keyed).
            new_key = old_k.is_a?(Symbol) ? new_k.to_sym : new_k
            obj[new_key] = new_v
          end
        when Array
          obj.each { |v| rewrite_pointer_columns!(v, compressible) }
        end
      end
      module_function :rewrite_pointer_columns!

      # Discovery: return a lightweight catalog of every tool this agent
      # can execute, optionally filtered by category. Returns
      # `{ tools: [{name, category, description}, ...], categories: {...} }`.
      # No input schemas, no permission tier — just enough to let an LLM
      # decide which tool to drill into next via `tools/list` (which
      # carries the full schemas).
      #
      # The agent's `allowed_tools` allowlist is honored — `list_tools`
      # never reveals a tool the caller's permission tier or `tools:`
      # filter blocks.
      def list_tools(agent, category: nil, **_kwargs)
        defs = definitions(agent.allowed_tools, format: :openai, category: category)
        rows = defs.map do |entry|
          fn = entry[:function] || entry
          {
            name:        fn[:name],
            category:    fn[:category] || "custom",
            description: fn[:description],
          }
        end
        {
          tools:      rows,
          categories: BUILTIN_CATEGORIES,
        }
      end

      # Get schema for a specific class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @return [Hash] formatted schema information
      def get_schema(agent, class_name:, **_kwargs)
        assert_class_accessible!(class_name, agent: agent)
        response = agent.client.schema(class_name)

        unless response.success?
          # Raise a ValidationError (not a bare RuntimeError) so the message
          # — including the did-you-mean hint — reaches the LLM via
          # error_response instead of being collapsed to a generic
          # "internal error" by the sanitizing StandardError rescue. A
          # mistyped class name is the common cause; suggesting near matches
          # lets the model self-correct in one retry instead of falling back
          # to a full get_all_schemas sweep.
          suggestions = suggest_class_names(class_name, agent: agent)
          hint = suggestions.empty? ? "" : " Did you mean: #{suggestions.join(", ")}?"
          raise Parse::Agent::ValidationError,
                "Could not fetch schema for '#{class_name}'.#{hint}"
        end

        # Enrich with local model metadata (descriptions, agent methods)
        enriched = MetadataRegistry.enriched_schema(class_name, response.result, agent_permission: agent.permissions)
        enriched = Parse::Agent::PromptHardening.sanitize_schema_for_llm(enriched)

        ResultFormatter.format_schema(enriched)
      end

      # Locally-known Parse class names usable as did-you-mean candidates:
      # MetadataRegistry-visible classes plus every loaded Parse::Object
      # subclass, minus agent_hidden classes. Cheap; only called on the
      # get_schema error path.
      def known_class_names_for_suggestions(agent = nil)
        names = []
        reg = Parse::Agent::MetadataRegistry
        names.concat(Array(reg.visible_class_names)) if reg.respond_to?(:visible_class_names)
        if defined?(Parse::Object) && Parse::Object.respond_to?(:descendants)
          Parse::Object.descendants.each do |klass|
            names << klass.parse_class if klass.respond_to?(:parse_class)
          end
        end
        hidden = reg.respond_to?(:hidden_class_names) ? Array(reg.hidden_class_names) : []
        names.compact.map(&:to_s).uniq - hidden.map(&:to_s)
      end
      module_function :known_class_names_for_suggestions

      # Up to `limit` known class names within a small edit distance of the
      # (likely mistyped) `class_name`. Bounded threshold keeps unrelated
      # names out of the suggestion list.
      def suggest_class_names(class_name, agent: nil, limit: 3)
        target = class_name.to_s.downcase
        return [] if target.empty?
        threshold = [3, (target.length / 2.0).ceil].max
        known_class_names_for_suggestions(agent)
          .map { |name| [name, name_edit_distance(target, name.downcase)] }
          .select { |(_, dist)| dist <= threshold }
          .sort_by { |(name, dist)| [dist, name] }
          .first(limit)
          .map(&:first)
      end
      module_function :suggest_class_names

      # Compact iterative Levenshtein distance.
      def name_edit_distance(a, b)
        return b.length if a.empty?
        return a.length if b.empty?
        prev = (0..b.length).to_a
        a.each_char.with_index do |ca, i|
          cur = [i + 1]
          b.each_char.with_index do |cb, j|
            cost = ca == cb ? 0 : 1
            cur << [cur[j] + 1, prev[j + 1] + 1, prev[j] + cost].min
          end
          prev = cur
        end
        prev[b.length]
      end
      module_function :name_edit_distance

      # ============================================================
      # QUERY TOOLS
      # ============================================================

      # Query objects from a Parse class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param where [Hash] query constraints
      # @param limit [Integer] max results (default 100)
      # @param skip [Integer] pagination offset
      # @param order [String] sort field (prefix with '-' for desc)
      # @param keys [Array<String>] fields to select
      # @param include [Array<String>] pointer fields to include
      # @return [Hash] query results, or a refusal hash if COLLSCAN detected
      # @raise [ConstraintTranslator::ConstraintSecurityError] if blocked operators are used
      # Valid formats for the +format:+ kwarg on query_class. "json" is
      # the default and returns the structured row envelope; the others
      # delegate to the export_data formatters so the conversational
      # query path can produce a CSV/Markdown/text-table dump without
      # round-tripping through a separate tool.
      QUERY_CLASS_FORMATS = %w[json csv markdown table].freeze

      def query_class(agent, class_name:, where: nil, limit: nil, skip: nil,
                             order: nil, keys: nil, include: nil,
                             apply_canonical_filter: true, format: nil, **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :find)
        limit = [limit || Agent::DEFAULT_LIMIT, Agent::MAX_LIMIT].min

        # Tenant scope enforcement: resolve before any query building so that
        # the effective where (with scope injected) is what everything else sees.
        # TRACK-AGENT-7 split: per-agent filter is UNCONDITIONAL; canonical
        # filter remains LLM-controllable via apply_canonical_filter:.
        scope        = resolve_tenant_scope!(agent, class_name)
        effective_where = apply_tenant_scope_to_where(where, scope, class_name)
        effective_where = apply_per_agent_filter_to_where(effective_where, class_name, agent: agent)
        effective_where = apply_canonical_filter_to_where(effective_where, class_name, agent: agent) if apply_canonical_filter

        # COLLSCAN pre-flight check (Feature 3):
        # Only runs when refuse_collscan is enabled globally AND the class has
        # not opted out via agent_allow_collscan, AND where is non-empty.
        if effective_where && !effective_where.empty? &&
           Parse::Agent.refuse_collscan? &&
           !MetadataRegistry.allow_collscan?(class_name)

          refusal = collscan_preflight(agent, class_name, effective_where)
          return refusal if refusal
        end

        # Build query hash
        query = {}
        query[:limit] = limit
        query[:skip] = skip if skip && skip > 0
        query[:order] = order if order
        # Reconcile caller-supplied `keys:` with the model's agent_fields
        # allowlist. When an allowlist is declared, it is a security boundary
        # (not a hint) and caller-supplied keys must be intersected with it,
        # not replace it. Without this, the LLM passing
        # `keys: ["ssn", "name"]` against an allowlisted class bypasses the
        # field redaction. ALWAYS_KEEP_FIELDS (objectId / createdAt /
        # updatedAt) is always included so pointer dereferencing still works.
        # NEW-TOOLS-5: validate keys: against identifier regex before
        # the allowlist intersection. This refuses leading-underscore
        # names (_hashed_password, _session_token, _rperm, _wperm, etc.)
        # at the boundary, so they cannot leak through even on classes
        # WITHOUT an agent_fields allowlist.
        validated_keys = validate_keys!(keys)
        allowlist = MetadataRegistry.field_allowlist(class_name)
        caller_keys = validated_keys&.any? ? validated_keys : nil
        effective_keys =
          if allowlist && allowlist.any?
            permitted = allowlist.map(&:to_s) | MetadataRegistry::ALWAYS_KEEP_FIELDS
            caller_keys ? (caller_keys & permitted) : allowlist.map(&:to_s)
          else
            caller_keys
          end
        include = validate_include!(include)
        # Refuse include paths that resolve into a hidden class via
        # belongs_to / has_one reflection. Best-effort; the post-fetch
        # redact_hidden_classes! walker (below) catches anything we can't
        # resolve at request time.
        assert_include_paths_accessible!(class_name, include, agent: agent)
        # keys-on-include auto-projection. When the caller passed
        # `keys: ["user", ...] + include: ["user"]`, expand `keys` to
        # dotted-path projections of the joined class so Parse Server
        # narrows the included record to its agent_join_fields (or
        # agent_fields - agent_large_fields) instead of serializing the
        # entire row. Suppressed when the caller passes any `<pointer>.*`
        # dotted path themselves or when no `keys:` was passed.
        projection = apply_include_projection(class_name, effective_keys, include)
        effective_keys = projection[:effective_keys]
        truncated_includes = projection[:truncated]
        query[:keys] = effective_keys.join(",") if effective_keys&.any?
        query[:include] = include.join(",") if include&.any?

        # SECURITY: Constraint validation happens in ConstraintTranslator.translate
        # This blocks dangerous operators like $where, $function
        translated_where = nil
        if effective_where && !effective_where.empty?
          translated_where = ConstraintTranslator.translate(effective_where, agent)
          query[:where] = translated_where.to_json
        end

        # Validate `format:` early so a bad value fails at the boundary
        # before we round-trip to Parse Server. nil and "json" both mean
        # the default structured envelope.
        normalized_format = format&.to_s&.downcase
        if normalized_format && !QUERY_CLASS_FORMATS.include?(normalized_format)
          raise Parse::Agent::ValidationError,
                "format: must be one of #{QUERY_CLASS_FORMATS.inspect}, got #{format.inspect}"
        end

        with_timeout(:query_class) do
          results =
            if agent.respond_to?(:acl_scope_requires_direct?) && agent.acl_scope_requires_direct?
              # Auto-route through Parse::MongoDB.aggregate so ACLScope's
              # `_rperm` $match injection runs — REST find_objects has
              # no "act as role" affordance for acl_user/acl_role agents.
              execute_find_via_direct(
                agent, class_name,
                where: translated_where, limit: limit, skip: skip,
                order: order, keys: effective_keys, include: include,
              )
            else
              response = agent.client.find_objects(class_name, query, **agent.request_opts)
              unless response.success?
                raise "Query failed: #{response.error}"
              end
              response.results
            end
          # Defense-in-depth: scrub any embedded objects whose className
          # matches a hidden class, regardless of how they got into the
          # result (e.g., server-side $lookup output via raw include paths
          # we couldn't resolve through belongs_to reflection at request
          # time).
          results = redact_hidden_classes!(results, agent: agent)

          if normalized_format && normalized_format != "json"
            format_query_results_as(normalized_format, class_name, results)
          else
            formatted = ResultFormatter.format_query_results(class_name, results,
                                                             limit: limit, skip: skip || 0,
                                                             where: where, keys: keys,
                                                             order: order, include: include,
                                                             truncated_include_fields: truncated_includes)
            if formatted.is_a?(Hash) && formatted[:results].is_a?(Array)
              stamp_source!(formatted[:results], class_name: class_name, tool: :query_class)
            end
            formatted
          end
        end
      end

      # @api private
      # Format query results as CSV / Markdown / text-table using the
      # same helpers export_data uses. Columns are inferred from the
      # first row (skipping Parse-internal envelope keys). Returns the
      # standard text-export envelope shape.
      def format_query_results_as(format, class_name, results)
        col_specs = results.any? ? infer_export_columns_from(results.first) : []
        headers   = col_specs.map { |s| s[:header] }
        rows      = results.map do |obj|
          col_specs.map { |s| stringify_export_value(extract_export_value(obj, s[:path])) }
        end
        output = case format
          when "csv"      then format_export_csv(headers, rows)
          when "markdown" then format_export_markdown(headers, rows)
          when "table"    then format_export_text_table(headers, rows)
          end
        {
          class_name: class_name,
          format:     format,
          headers:    headers,
          row_count:  rows.size,
          output:     output,
        }
      end
      module_function :format_query_results_as

      # Count objects in a Parse class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param where [Hash] query constraints
      # @return [Hash] count result
      def count_objects(agent, class_name:, where: nil, apply_canonical_filter: true, **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :count)
        # Tenant scope enforcement. TRACK-AGENT-7 split: per-agent filter is
        # UNCONDITIONAL, canonical filter is LLM-controllable.
        scope           = resolve_tenant_scope!(agent, class_name)
        effective_where = apply_tenant_scope_to_where(where, scope, class_name)
        effective_where = apply_per_agent_filter_to_where(effective_where, class_name, agent: agent)
        effective_where = apply_canonical_filter_to_where(effective_where, class_name, agent: agent) if apply_canonical_filter

        query = { limit: 0, count: 1 }

        translated_where = nil
        if effective_where && !effective_where.empty?
          translated_where = ConstraintTranslator.translate(effective_where, agent)
          query[:where] = translated_where.to_json
        end

        count =
          if agent.respond_to?(:acl_scope_requires_direct?) && agent.acl_scope_requires_direct?
            execute_count_via_direct(agent, class_name, where: translated_where)
          else
            response = agent.client.find_objects(class_name, query, **agent.request_opts)
            unless response.success?
              raise "Count failed: #{response.error}"
            end
            response.count
          end

        {
          class_name: class_name,
          count: count,
          constraints: effective_where || {},
        }
      end

      # Get a single object by ID
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param object_id [String] the objectId
      # @param include [Array<String>] pointer fields to include
      # @return [Hash] the object data
      # @raise [Parse::Agent::ValidationError] for invalid class_name or object_id
      def get_object(agent, class_name:, object_id:, include: nil,
                     apply_canonical_filter: true, **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :get)
        assert_object_id!(object_id)
        # Resolve tenant scope early so we can verify after fetch.
        # We do NOT inject it into the query (there is no where: on a fetch-by-id)
        # — instead we verify the returned record post-fetch to avoid becoming
        # an oracle for "does this id exist in another tenant".
        scope = resolve_tenant_scope!(agent, class_name)

        # TRACK-AGENT-6 / TRACK-AGENT-7 split: per-agent filter is
        # UNCONDITIONAL (operator scoping cannot be dropped via the
        # LLM kwarg). Canonical filter is LLM-controllable via
        # `apply_canonical_filter:`; default true so the same
        # "valid state" subset query_class returns is honored on
        # direct fetch-by-id. A caller that legitimately needs to
        # fetch a soft-deleted / hidden row can pass
        # apply_canonical_filter: false.
        #
        # When ANY filter applies, the call is rewritten to a
        # find_objects with `where: { objectId: id, ...filter }` so
        # enforcement is server-side; the "not found" envelope covers
        # both "doesn't exist" and "filtered out", consistent with the
        # existing tenant-scope refusal pattern that prefers fail-
        # closed over an existence oracle.
        composed = nil
        composed = apply_per_agent_filter_to_where(composed, class_name, agent: agent)
        composed = apply_canonical_filter_to_where(composed, class_name, agent: agent) if apply_canonical_filter
        composed_filter = composed && !composed.empty? ? composed : nil

        query = {}
        include = validate_include!(include)
        assert_include_paths_accessible!(class_name, include, agent: agent)
        query[:include] = include.join(",") if include&.any?

        # Project to the agent_fields allowlist when one is declared
        allowlist = MetadataRegistry.field_allowlist(class_name)
        effective_keys = allowlist&.any? ? allowlist.dup : nil
        # keys-on-include auto-projection: when the parent's allowlist
        # includes a pointer field that the caller is dereferencing via
        # `include:`, narrow the included record to its agent_join_fields
        # (or agent_fields - agent_large_fields) so the LLM doesn't pay
        # for the entire row on the join.
        include_projection = apply_include_projection(class_name, effective_keys, include)
        effective_keys = include_projection[:effective_keys]
        truncated_includes = include_projection[:truncated]
        query[:keys] = effective_keys.join(",") if effective_keys&.any?

        if composed_filter
          # Compose the objectId match into the filter; a hit returns exactly
          # one row, a filtered-out match returns zero rows (treated as not-
          # found below, identical to the genuine missing-row case).
          combined_where =
            if composed_filter.is_a?(Hash) && composed_filter.key?("$and")
              { "$and" => composed_filter["$and"] + [{ "objectId" => object_id }] }
            else
              { "$and" => [composed_filter, { "objectId" => object_id }] }
            end
          translated_combined = ConstraintTranslator.translate(combined_where, agent)
          rows =
            if agent.respond_to?(:acl_scope_requires_direct?) && agent.acl_scope_requires_direct?
              execute_find_via_direct(
                agent, class_name,
                where: translated_combined, limit: 1,
                keys: effective_keys, include: include,
              )
            else
              find_query = query.merge(where: translated_combined.to_json, limit: 1)
              response = agent.client.find_objects(class_name, find_query, **agent.request_opts)
              unless response.success?
                raise Parse::Error, "Fetch failed: #{response.error}"
              end
              response.results
            end
          if rows.nil? || rows.empty?
            raise Parse::Error, "Object not found: #{class_name}##{object_id}"
          end
          response_result = rows.first
        elsif agent.respond_to?(:acl_scope_requires_direct?) && agent.acl_scope_requires_direct?
          # No per-agent filter, but acl_user/acl_role scope: route the
          # fetch through mongo-direct with a `where: {objectId: id}`.
          # The three-layer ACL simulation in Parse::MongoDB.aggregate
          # ensures the row is only returned when the agent's scope
          # permits it.
          where_id = ConstraintTranslator.translate({ "objectId" => object_id }, agent)
          rows = execute_find_via_direct(
            agent, class_name,
            where: where_id, limit: 1,
            keys: effective_keys, include: include,
          )
          if rows.nil? || rows.empty?
            raise Parse::Error, "Object not found: #{class_name}##{object_id}"
          end
          response_result = rows.first
        else
          response = agent.client.fetch_object(class_name, object_id, query: query, **agent.request_opts)

          unless response.success?
            # Raise structured Parse::Error so the agent's error dispatch
            # preserves the "not found" message on the wire. A bare
            # RuntimeError falls into the generic StandardError catch-all and
            # gets sanitized to "internal error" — hiding a documented
            # user-error condition behind the internal-error mask.
            if response.object_not_found?
              raise Parse::Error, "Object not found: #{class_name}##{object_id}"
            end
            raise Parse::Error, "Fetch failed: #{response.error}"
          end
          response_result = response.result
        end

        result = redact_hidden_classes!(response_result, agent: agent)

        # Post-fetch tenant scope verification. Raises AccessDenied rather than
        # "not found" to avoid being an oracle for cross-tenant id existence.
        assert_record_in_tenant_scope!(result, scope, class_name)

        ResultFormatter.format_object(class_name, result,
                                       truncated_include_fields: truncated_includes)
      end

      # Batch-fetch multiple Parse objects by id in a single query.
      # Prefer this over multiple get_object calls when dereferencing pointers.
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param ids [Array<String>] objectId values to fetch (max 50, dedup'd)
      # @param include [Array<String>] pointer fields to include/resolve
      # @return [Hash] { class_name:, objects:, missing:, requested:, found: }
      # @raise [Parse::Agent::ValidationError] if class_name invalid, ids not an Array,
      #   any id has invalid format, or more than 50 unique ids are requested
      def get_objects(agent, class_name:, ids: nil, include: [],
                      apply_canonical_filter: true, **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :get)
        # Resolve tenant scope early — verified post-fetch (oracle-prevention).
        # TRACK-AGENT-1 / TRACK-AGENT-6 / TRACK-AGENT-7 fix: per-agent
        # filter is UNCONDITIONALLY applied here (the operator's
        # per-agent scoping must not be bypassable via batch fetch-by-
        # id), and the canonical filter is LLM-controllable via
        # `apply_canonical_filter:` (default true) to mirror
        # get_object's semantics. Previously this tool silently
        # ignored BOTH filters, letting an LLM enumerate hidden /
        # archived rows by feeding harvested objectIds.
        scope = resolve_tenant_scope!(agent, class_name)

        # nil ids is an error (required parameter); empty array is a valid empty result
        if ids.nil?
          raise Parse::Agent::ValidationError, "ids is required"
        end

        unless ids.is_a?(Array)
          raise Parse::Agent::ValidationError, "ids must be an Array of Strings"
        end

        # Short-circuit on empty array — no query needed
        if ids.empty?
          return {
            class_name: class_name,
            objects: {},
            missing: [],
            requested: 0,
            found: 0,
          }
        end

        unique_ids = ids.uniq

        if unique_ids.size > 50
          raise Parse::Agent::ValidationError,
                "ids exceeds the 50-object limit (#{unique_ids.size} unique ids). " \
                "For larger sets use query_class with an $in constraint."
        end

        # Validate each id format using the shared OBJECT_ID_RE so
        # +get_objects+ accepts the same set of identifiers as
        # +get_object+ — apps with custom-id schemes that use hyphens or
        # underscores should not see one entry point accept the id and
        # another reject it.
        unique_ids.each do |id|
          unless id.is_a?(String) && OBJECT_ID_RE.match?(id)
            raise Parse::Agent::ValidationError,
                  "each id must match #{OBJECT_ID_RE.source} (got: #{id.inspect})"
          end
        end

        # Compose where: { objectId: { $in: ids } } AND per-agent filter
        # AND (optionally) class-level canonical filter via $and so all
        # three layers reach the server in one query. Then route through
        # ConstraintTranslator so snake_case keys are camelized to Parse
        # Server wire format (mirrors count_objects / query_class).
        base_in_where    = { "objectId" => { "$in" => unique_ids } }
        composed         = apply_per_agent_filter_to_where(base_in_where, class_name, agent: agent)
        composed         = apply_canonical_filter_to_where(composed, class_name, agent: agent) if apply_canonical_filter
        translated_where = ConstraintTranslator.translate(composed, agent)

        # Build query
        query = {
          where: translated_where.to_json,
          limit: unique_ids.size,
        }
        include = validate_include!(include)
        assert_include_paths_accessible!(class_name, include, agent: agent)
        query[:include] = include.join(",") if include&.any?

        # Apply agent_fields allowlist as keys projection
        allowlist = MetadataRegistry.field_allowlist(class_name)
        effective_keys = allowlist&.any? ? allowlist.dup : nil
        # keys-on-include auto-projection: narrow included records to the
        # joined class's agent_join_fields (or agent_fields - large) when
        # the parent's allowlist surfaces a pointer the caller is
        # dereferencing via `include:`.
        include_projection = apply_include_projection(class_name, effective_keys, include)
        effective_keys = include_projection[:effective_keys]
        truncated_includes = include_projection[:truncated]
        query[:keys] = effective_keys.join(",") if effective_keys&.any?

        with_timeout(:get_objects) do
          rows =
            if agent.respond_to?(:acl_scope_requires_direct?) && agent.acl_scope_requires_direct?
              # Feed the translated (already-composed) where into the
              # direct-route helper. The $in constraint composes with
              # the per-agent / canonical filter via the same $and the
              # REST path emits, so the ACL scope's ALSO-applied _rperm
              # $match continues to layer on top correctly.
              execute_find_via_direct(
                agent, class_name,
                where: translated_where, limit: unique_ids.size,
                keys: effective_keys, include: include,
              )
            else
              response = agent.client.find_objects(class_name, query, **agent.request_opts)
              unless response.success?
                raise "Batch fetch failed: #{response.error}"
              end
              response.results
            end

          results = redact_hidden_classes!(rows, agent: agent)

          # Post-fetch tenant scope verification: refuse the whole call if ANY
          # returned record is outside this agent's tenant scope. This prevents
          # an oracle where partial results could confirm cross-tenant id existence.
          if scope
            results.each { |rec| assert_record_in_tenant_scope!(rec, scope, class_name) }
          end

          objects_by_id = results.each_with_object({}) do |obj, h|
            oid = obj.is_a?(Hash) ? (obj["objectId"] || obj[:objectId]) : obj.id
            h[oid] = obj
          end
          stamp_source!(objects_by_id.values, class_name: class_name, tool: :get_objects)

          missing = unique_ids.reject { |id| objects_by_id.key?(id) }

          # Normalize each row to the same LLM-friendly form query_class
          # emits (Pointers -> {_type,class,id}, Dates -> ISO, ACL stripped)
          # instead of shipping raw wire-form. Done after stamp_source! so
          # the `_source` citation survives.
          simplified = objects_by_id.transform_values { |obj| ResultFormatter.simplify_object(obj) }

          envelope = {
            class_name: class_name,
            objects: simplified,
            missing: missing,
            requested: unique_ids.size,
            found: objects_by_id.size,
          }
          if truncated_includes && !truncated_includes.empty?
            envelope[:truncated_include_fields] =
              truncated_includes.transform_values { |meta| meta[:dropped] }
          end
          envelope
        end
      end

      # Get sample objects from a class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param limit [Integer] number of samples (default 5, max 20)
      # @return [Hash] sample objects
      def get_sample_objects(agent, class_name:, limit: nil, **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :find)
        # Tenant scope enforcement: inject scope into where so samples are
        # always from the agent's tenant.
        scope = resolve_tenant_scope!(agent, class_name)

        limit = [limit || 5, 20].min

        query = {
          limit: limit,
          order: "-createdAt",
        }

        # Build effective where: combining tenant scope, per-agent filter, and
        # canonical filter.
        # H3: apply the class's canonical filter so sample rows are from the
        # same "valid state" subset that query_class returns by default.
        # Without this, get_sample_objects would surface soft-deleted / hidden
        # rows that every other read tool excludes.
        # TRACK-AGENT-7 split: per-agent filter is UNCONDITIONAL.
        effective_where = scope ? { scope[:field].to_s => scope[:value] } : nil
        effective_where = apply_per_agent_filter_to_where(effective_where, class_name, agent: agent)
        effective_where = apply_canonical_filter_to_where(effective_where, class_name, agent: agent)
        translated_where = nil
        if effective_where && !effective_where.empty?
          translated_where = ConstraintTranslator.translate(effective_where, agent)
          query[:where] = translated_where.to_json
        end

        # Project to the agent_fields allowlist when one is declared
        allowlist = MetadataRegistry.field_allowlist(class_name)
        query[:keys] = allowlist.join(",") if allowlist&.any?

        rows =
          if agent.respond_to?(:acl_scope_requires_direct?) && agent.acl_scope_requires_direct?
            execute_find_via_direct(
              agent, class_name,
              where: translated_where, limit: limit, order: "-createdAt",
              keys: allowlist&.any? ? allowlist : nil,
            )
          else
            response = agent.client.find_objects(class_name, query, **agent.request_opts)
            unless response.success?
              raise "Sample query failed: #{response.error}"
            end
            response.results
          end

        # Redact nested objects whose className is hidden — catches
        # anything the catalog filter and include-path resolver missed.
        results = redact_hidden_classes!(rows, agent: agent)
        {
          class_name: class_name,
          sample_count: results.size,
          samples: results.map { |obj| ResultFormatter.format_object(class_name, obj)[:object] },
          note: "These are the #{results.size} most recently created objects",
        }
      end

      # ============================================================
      # ANALYSIS TOOLS
      # ============================================================

      # Run an aggregation pipeline
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param pipeline [Array<Hash>] MongoDB aggregation pipeline
      # @return [Hash] aggregation results, or a refusal hash if COLLSCAN detected
      # @raise [PipelineValidator::PipelineSecurityError] if pipeline contains blocked stages
      # Default safety cap for aggregation result rows when the caller's
      # pipeline doesn't already terminate in a `$limit` or `$count` stage.
      # `aggregate` injects an auto-`$limit` at this size so a `$group` over
      # a high-cardinality field can't fire back tens of thousands of rows
      # to the LLM. Conservatively sized for chat-context safety.
      AGGREGATE_DEFAULT_LIMIT = 200

      # Default routing for {.aggregate}: when true, the agent tool sends
      # the assembled pipeline through {Parse::MongoDB.aggregate} (direct
      # MongoDB) and applies the direct-MongoDB field-reference rewriter so
      # `$author` reaches `$_p_author`. When false, the pipeline goes to
      # the Parse Server REST aggregate endpoint and field translation is
      # whatever the server provides. The toggle is plumbed per-call via
      # the `mongo_direct:` kwarg; the default lives here so a deployment
      # without {Parse::MongoDB} configured still has a single switch to
      # flip back.
      AGGREGATE_DEFAULT_MONGO_DIRECT = true

      def aggregate(agent, class_name:, pipeline:, rewrite_lookups: nil, compact_pointers: true,
                    apply_canonical_filter: true, mongo_direct: AGGREGATE_DEFAULT_MONGO_DIRECT,
                    **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :find)
        # SECURITY: Validate pipeline BEFORE execution.
        # This blocks dangerous stages like $out, $merge, $function.
        PipelineValidator.validate!(pipeline)
        # And refuse any cross-class reference into a hidden class via
        # $lookup / $graphLookup / $unionWith.from, plus enforce the
        # class's agent_fields allowlist on projection-style stages
        # ($project, $addFields, $set, $unset, $replaceRoot). Without this
        # the top-level assert_class_accessible! check is bypassable.
        enforce_pipeline_access_policy!(class_name, pipeline, agent: agent)

        # Auto-rewrite LLM-style $lookup stages into Parse-on-Mongo column
        # form AFTER access policy has run on the LLM's original (logical)
        # names. MetadataRegistry.hidden? canonicalizes `User` -> `_User`
        # so the access check is correct regardless, but running the
        # rewrite after keeps the audit-log shape identical to the LLM's
        # submission. Uses fallback: :preserve, so stages without a
        # parse_reference-equipped target pass through unchanged.
        pipeline = Parse::LookupRewriter.auto_rewrite(
          pipeline, class_name: class_name, enabled: rewrite_lookups,
        )

        # Tenant scope enforcement: prepend a $match stage at index 0.
        # Done after pipeline validation so the injected stage doesn't
        # interfere with the validator's denylist walk.
        scope              = resolve_tenant_scope!(agent, class_name)
        scoped_pipeline    = apply_tenant_scope_to_pipeline(pipeline, scope)

        # Per-agent filter (declared via Parse::Agent.new(filters: ...)) is
        # UNCONDITIONAL — TRACK-AGENT-7 split. No LLM kwarg can drop it.
        scoped_pipeline = apply_per_agent_filter_to_pipeline(scoped_pipeline, class_name, agent: agent)

        # Canonical filter (per-class, declared via agent_canonical_filter).
        # Prepended as a $match stage so the pipeline starts from the
        # "valid state" subset of the class — closes the silently-suspect
        # counts gap where an LLM dropping to aggregate would otherwise
        # include soft-deleted / hidden rows that query_class excludes.
        # LLM-controllable via apply_canonical_filter:.
        if apply_canonical_filter
          scoped_pipeline = apply_canonical_filter_to_pipeline(scoped_pipeline, class_name, agent: agent)
        end

        # Auto-inject a terminal $limit so the LLM cannot accidentally pull
        # a high-cardinality group result into context. If the caller's
        # pipeline already ends with $limit / $count, we trust their bound.
        effective_pipeline, auto_limited = ensure_aggregate_terminal_limit(scoped_pipeline)

        # COLLSCAN pre-flight check (Feature 3):
        # Extract a leading $match stage as the implicit "where" for aggregations.
        # If the pipeline doesn't begin with $match, skip pre-flight — the caller
        # is doing a deliberate scan-then-reduce and refusing would be hostile.
        if Parse::Agent.refuse_collscan? &&
           !MetadataRegistry.allow_collscan?(class_name) &&
           (match_stage = effective_pipeline.first&.dig("$match"))&.any?

          refusal = collscan_preflight(agent, class_name, match_stage)
          return refusal if refusal
        end

        # Route either through direct MongoDB (default) or the Parse Server
        # REST aggregate endpoint. The direct path additionally runs the
        # pipeline through the SDK's field-reference rewriter, which is
        # what closes the `$cond` / `$expr` / `$switch` rewrite holes that
        # the server route would otherwise inherit from Parse Server.
        use_mongo_direct = mongo_direct &&
                           defined?(Parse::MongoDB) &&
                           Parse::MongoDB.enabled?

        # Parse Server's REST aggregate endpoint does NOT enforce per-row
        # ACL — only the SDK's mongo-direct path applies the `_rperm`
        # `$match` injection via Parse::ACLScope. For any non-master
        # identity (session_token / acl_user / acl_role, including a
        # runtime #impersonate that cleared @acl_scope), the caller's
        # `mongo_direct: false` would silently bypass the agent's
        # declared scope; auto-promote to mongo-direct so the ACLScope
        # enforcement runs. Master-key agents keep their REST path
        # (no ACL enforcement was claimed in the first place).
        if !use_mongo_direct && agent.respond_to?(:requires_mongo_direct?) && agent.requires_mongo_direct? &&
           defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
          use_mongo_direct = true
        end

        with_timeout(:aggregate) do
          results = if use_mongo_direct
              translated = Parse::Query.new(class_name).send(
                :translate_pipeline_for_direct_mongodb, effective_pipeline,
              )
              # Forward the agent's auth posture into Parse::MongoDB.aggregate
              # so its ACLScope layer runs in the right mode. Without this,
              # ACLScope's public-fallback would emit a SECURITY banner on
              # every agent call AND inject an `_rperm`-only `$match` —
              # masking rows that the agent's own class/field/tenant/canonical
              # gates already authorize the agent to see. LLM-supplied auth
              # kwargs are NOT forwarded here (the tool signature swallows
              # unknown kwargs into `**_kwargs` which never propagate); the
              # posture comes entirely from the agent instance.
              raw_rows = Parse::MongoDB.aggregate(
                class_name, translated, **mongo_direct_auth_kwargs(agent),
              )
              # Parse Server REST aggregate returns docs with BSON-native
              # types already converted to Parse/JSON-friendly shapes. The
              # direct driver returns raw BSON, so run each row through the
              # same converter so the downstream code (redact, compact)
              # sees identical shapes regardless of route.
              raw_rows.map { |raw| Parse::MongoDB.convert_aggregation_document(raw) }
            else
              response = agent.client.aggregate_pipeline(
                class_name, effective_pipeline, **agent.request_opts,
              )
              unless response.success?
                raise "Aggregation failed: #{response.error}"
              end
              response.results
            end

          # Defense-in-depth: scrub nested objects whose className is hidden.
          # Catches server-side $lookup output that leaked through despite
          # enforce_pipeline_access_policy! (e.g., dynamic `from:` values).
          # This MUST run before compact_pointers! so that hidden-class
          # `_p_*` strings are scrubbed (to a `{className:, __redacted:}`
          # placeholder) and not silently surfaced into the pointer_classes
          # envelope map.
          results = redact_hidden_classes!(results, agent: agent)

          # Pointer-column compaction. Default-on: a typical aggregate over
          # a class with a high-cardinality pointer (e.g. author per row)
          # repeats the `_User$` className prefix on every value. Stripping
          # it and hoisting the class to a single envelope-level
          # `pointer_classes` map saves meaningful bytes per call without
          # losing information. Opt-out via `compact_pointers: false` when
          # the caller specifically needs the raw Parse-on-Mongo shape.
          pointer_map = compact_pointers ? compact_pointers!(results) : {}
          # Stamp provenance AFTER compaction/redaction. Grouped rows have
          # no objectId — `_source.object_id` is nil for those (documented).
          stamp_source!(results, class_name: class_name, tool: :aggregate)

          result = {
            class_name: class_name,
            pipeline_stages: pipeline.size,
            result_count: results.size,
            # Coerce to String here so the value lands in
            # `structuredContent` as a String (matching the
            # advertised output_schema `type: "string"`). Without the
            # `.to_s`, MCP clients validating structuredContent see a
            # Ruby Symbol pre-serialization and fail the type check;
            # downstream JSON serialization would convert it but the
            # client-side validator runs before that.
            route: (use_mongo_direct ? :mongo_direct : :parse_server).to_s,
            results: results,
          }
          result[:pointer_classes] = pointer_map if pointer_map.any?
          # Only surface the auto-limit hint when the cap actually fired
          # (the result hit the cap). A 1-row aggregation that happened to
          # not declare a terminal $limit doesn't benefit from the warning
          # and the hint text is ~200 bytes on every call.
          if auto_limited && results.size >= AGGREGATE_DEFAULT_LIMIT
            result[:auto_limited] = true
            result[:auto_limit]   = AGGREGATE_DEFAULT_LIMIT
            result[:hint]         = "Pipeline auto-bounded with $limit:#{AGGREGATE_DEFAULT_LIMIT} (no terminal $limit/$count supplied). " \
                                    "Add an explicit { \"$limit\": N } stage at the end of your pipeline to control the cap, " \
                                    "or call count_objects first to size the result before fetching rows."
          end
          result
        end
      end

      # @api private
      # Returns [pipeline_to_run, auto_limited?]. When the caller's last
      # stage is $limit or $count, the pipeline is returned unchanged. The
      # check walks forward to find the last stage, ignoring $sort/$project/
      # $addFields/$unset trailers because those don't bound cardinality.
      def ensure_aggregate_terminal_limit(pipeline)
        return [pipeline, false] unless pipeline.is_a?(Array) && pipeline.any?
        last = pipeline.last
        return [pipeline, false] unless last.is_a?(Hash)
        op = last.keys.first.to_s
        return [pipeline, false] if op == "$limit" || op == "$count"
        [pipeline + [{ "$limit" => AGGREGATE_DEFAULT_LIMIT }], true]
      end
      module_function :ensure_aggregate_terminal_limit

      # ============================================================
      # GROUP/DISTINCT TOOLS
      # ============================================================

      # Per-tool result caps. Distinct often spans more values than a
      # grouped count (think tags, statuses, customer ids), so it gets
      # a larger ceiling while group_by/group_by_date stay aligned with
      # AGGREGATE_DEFAULT_LIMIT for context-safety.
      GROUP_DEFAULT_LIMIT    = 200
      GROUP_MAX_LIMIT        = 1000
      DISTINCT_DEFAULT_LIMIT = 1000
      DISTINCT_MAX_LIMIT     = 5000

      # Supported aggregation operations for group_by / group_by_date.
      # Maps the LLM-facing name to the MongoDB accumulator operator.
      GROUP_OPERATIONS = {
        "count"   => "$sum",   # value_field is ignored; accumulator is { $sum: 1 }
        "sum"     => "$sum",
        "avg"     => "$avg",
        "average" => "$avg",
        "min"     => "$min",
        "max"     => "$max",
      }.freeze

      GROUP_DATE_INTERVALS = %w[year month week day hour minute second].freeze

      # Group records by a field and aggregate. See TOOL_DEFINITIONS[:group_by].
      def group_by(agent, class_name:, field:, operation: nil, value_field: nil,
                   where: nil, flatten_arrays: false, sort: nil, limit: nil,
                   dry_run: false, apply_canonical_filter: true, **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :find)
        validated_field = validate_group_field!(field, name: :field)
        op_key, accumulator = resolve_group_operation!(operation, value_field)
        cap = clamp_group_limit(limit, default: GROUP_DEFAULT_LIMIT, max: GROUP_MAX_LIMIT)
        sort_choice = normalize_group_sort(sort)

        # Field-allowlist enforcement: the group field, the value field
        # (when present), and every key in `where:` must be within
        # agent_fields when an allowlist is declared. The aggregate
        # delegate's walker doesn't cover the where-keys here because
        # we translate them into $match ourselves.
        referenced = [validated_field]
        referenced << validate_group_field!(value_field, name: :value_field) if value_field
        assert_fields_in_allowlist!(class_name, referenced)
        assert_where_fields_in_allowlist!(class_name, where)

        formatted_group = resolve_aggregation_field(class_name, validated_field)
        formatted_value = value_field ? resolve_aggregation_field(class_name, validate_group_field!(value_field, name: :value_field)) : nil

        pipeline = build_group_pipeline(
          where: where,
          group_field: formatted_group,
          flatten_arrays: flatten_arrays,
          accumulator_op: accumulator,
          value_field: formatted_value,
          operation: op_key,
          agent: agent,
        )
        append_sort_limit!(pipeline, sort_choice: sort_choice, cap: cap, default_sort: nil)

        return dry_run_envelope(class_name: class_name, pipeline: pipeline, params: {
          field: validated_field, operation: op_key, value_field: value_field,
          flatten_arrays: flatten_arrays, sort: sort_choice, limit: cap,
        }) if dry_run

        result = run_aggregation_for_group_tool!(
          agent,
          class_name: class_name,
          pipeline: pipeline,
          tool: :group_by,
          apply_canonical_filter: apply_canonical_filter,
        )
        return result if result.is_a?(Hash) && result[:refused]

        # Parse Server's REST aggregate endpoint renames the $group _id field
        # to "objectId" in the response envelope, even when the value is a
        # plain string ("ios"), a pointer-storage string ("Class$id"), or a
        # document (date buckets). Read from "objectId"; nil there is a
        # legitimate "missing grouped value" and normalize_group_key handles it.
        groups = result[:rows].map { |row| [row["objectId"], row["value"]] }
        pointer_class, groups = extract_pointer_class!(groups)
        # H2: if the extracted pointer class is agent_hidden, redact the keys
        # so objectIds from the hidden class are not surfaced, and suppress
        # the pointer_class name from the envelope.
        pointer_class, groups = redact_hidden_pointer_groups!(pointer_class, groups, agent: agent)
        truncated = groups.size > cap
        groups = groups.first(cap) if truncated

        envelope = {
          class_name: class_name,
          field: validated_field,
          operation: op_key,
          group_count: groups.size,
          groups: groups.map { |k, v| { key: normalize_group_key(k), value: v } },
        }
        envelope[:value_field]    = value_field if value_field
        envelope[:pointer_class]  = pointer_class if pointer_class
        envelope[:flatten_arrays] = true if flatten_arrays
        envelope[:sort]           = sort_choice if sort_choice
        envelope[:truncated]      = true if truncated
        envelope[:limit]          = cap
        envelope
      end

      # Group records by a date field bucketed at an interval. See
      # TOOL_DEFINITIONS[:group_by_date].
      def group_by_date(agent, class_name:, field:, interval:, operation: nil,
                        value_field: nil, where: nil, timezone: nil, sort: nil,
                        limit: nil, dry_run: false, apply_canonical_filter: true, **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :find)
        validated_field    = validate_group_field!(field, name: :field)
        interval_sym       = validate_group_date_interval!(interval)
        op_key, accumulator = resolve_group_operation!(operation, value_field)
        cap                = clamp_group_limit(limit, default: GROUP_DEFAULT_LIMIT, max: GROUP_MAX_LIMIT)
        sort_choice        = normalize_group_sort(sort) || "key_asc"
        tz                 = validate_timezone!(timezone)

        referenced = [validated_field]
        referenced << validate_group_field!(value_field, name: :value_field) if value_field
        assert_fields_in_allowlist!(class_name, referenced)
        assert_where_fields_in_allowlist!(class_name, where)

        # Reject non-scalar field types that cannot meaningfully be grouped
        # by date. Pointer and array fields are registered in klass.fields;
        # relation fields (has_many through: :relation) are in klass.relations.
        # All three produce null-buckets silently in MongoDB, so we reject
        # them here before building the pipeline.
        gbd_klass = (Parse::Model.find_class(class_name) rescue nil) ||
                    (Parse::Model.const_get(class_name) rescue nil)
        if gbd_klass && gbd_klass.respond_to?(:fields)
          field_type = gbd_klass.fields[validated_field.to_sym] || gbd_klass.fields[validated_field]
          is_relation = gbd_klass.respond_to?(:relations) &&
                        gbd_klass.relations.key?(validated_field.to_sym)
          if %i[pointer array].include?(field_type) || is_relation
            bad_type = field_type || :relation
            raise Parse::Agent::ValidationError,
                  "group_by_date field '#{validated_field}' has type '#{bad_type}', " \
                  "which cannot be grouped by date. Use a :date or :string scalar field."
          end
        end

        formatted_field = resolve_aggregation_field(class_name, validated_field, force_no_pointer: true)
        formatted_value = value_field ? resolve_aggregation_field(class_name, validate_group_field!(value_field, name: :value_field)) : nil

        date_expr = build_date_group_expression(formatted_field, interval_sym, tz)
        pipeline = build_group_pipeline(
          where: where,
          group_field: nil,
          group_expression: date_expr,
          flatten_arrays: false,
          accumulator_op: accumulator,
          agent: agent,
          value_field: formatted_value,
          operation: op_key,
        )
        append_sort_limit!(pipeline, sort_choice: sort_choice, cap: cap, default_sort: "key_asc")

        return dry_run_envelope(class_name: class_name, pipeline: pipeline, params: {
          field: validated_field, interval: interval_sym.to_s, operation: op_key,
          value_field: value_field, timezone: tz, sort: sort_choice, limit: cap,
        }) if dry_run

        result = run_aggregation_for_group_tool!(
          agent,
          class_name: class_name,
          pipeline: pipeline,
          tool: :group_by_date,
          apply_canonical_filter: apply_canonical_filter,
        )
        return result if result.is_a?(Hash) && result[:refused]

        groups = result[:rows].map { |row| [format_date_key(row["objectId"], interval_sym), row["value"]] }
        # Re-sort in Ruby for key-based sorts because date keys are
        # formatted strings post-fetch (the pipeline sorts on the raw
        # _id document/integer); for value-based sorts, the wire sort
        # already left rows in correct order.
        groups = sort_groups(groups, sort_choice) if sort_choice.start_with?("key_")
        truncated = groups.size > cap
        groups = groups.first(cap) if truncated

        envelope = {
          class_name: class_name,
          field: validated_field,
          interval: interval_sym.to_s,
          operation: op_key,
          group_count: groups.size,
          groups: groups.map { |k, v| { key: k, value: v } },
        }
        envelope[:value_field] = value_field if value_field
        envelope[:timezone]    = tz          if tz
        envelope[:sort]        = sort_choice
        envelope[:truncated]   = true        if truncated
        envelope[:limit]       = cap
        envelope
      end

      # Return distinct values of a field. See TOOL_DEFINITIONS[:distinct].
      def distinct(agent, class_name:, field:, where: nil, sort: nil, limit: nil,
                   dry_run: false, apply_canonical_filter: true, **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :find)
        validated_field = validate_group_field!(field, name: :field)
        cap = clamp_group_limit(limit, default: DISTINCT_DEFAULT_LIMIT, max: DISTINCT_MAX_LIMIT)
        sort_choice = case sort.to_s
                      when "asc", "desc" then sort.to_s
                      when "", "none", nil then nil
                      else raise Parse::Agent::ValidationError,
                                 "Invalid sort #{sort.inspect}. Must be 'asc' or 'desc'."
                      end

        assert_fields_in_allowlist!(class_name, [validated_field])
        assert_where_fields_in_allowlist!(class_name, where)

        formatted_field = resolve_aggregation_field(class_name, validated_field)
        pipeline = build_group_pipeline(
          where: where,
          group_field: formatted_field,
          flatten_arrays: false,
          accumulator_op: nil,           # distinct has no accumulator
          value_field: nil,
          agent: agent,
          operation: "distinct",
        )
        # Map distinct's asc/desc to the shared sort vocabulary used by
        # append_sort_limit! (which expects key_*/value_*). Distinct has
        # no value column to sort on.
        wire_sort = case sort_choice
                    when "asc"  then "key_asc"
                    when "desc" then "key_desc"
                    end
        append_sort_limit!(pipeline, sort_choice: wire_sort, cap: cap, default_sort: nil)

        return dry_run_envelope(class_name: class_name, pipeline: pipeline, params: {
          field: validated_field, sort: sort_choice, limit: cap,
        }) if dry_run

        result = run_aggregation_for_group_tool!(
          agent,
          class_name: class_name,
          pipeline: pipeline,
          tool: :distinct,
          apply_canonical_filter: apply_canonical_filter,
        )
        return result if result.is_a?(Hash) && result[:refused]

        values = result[:rows].map { |row| row["objectId"] }
        pointer_class, paired = extract_pointer_class!(values.map { |v| [v, nil] })
        # H2: redact keys and suppress pointer_class when the resolved class
        # is agent_hidden (same pattern as group_by).
        pointer_class, paired = redact_hidden_pointer_groups!(pointer_class, paired, agent: agent)
        values = paired.map(&:first)
        truncated = values.size > cap
        values = values.first(cap) if truncated

        envelope = {
          class_name: class_name,
          field: validated_field,
          count: values.size,
          values: values,
        }
        envelope[:pointer_class] = pointer_class if pointer_class
        envelope[:sort]          = sort_choice   if sort_choice
        envelope[:truncated]     = true          if truncated
        envelope[:limit]         = cap
        envelope
      end

      # ----- helpers -----------------------------------------------------

      # @api private
      # Validate a field-name parameter against the identifier shape.
      def validate_group_field!(field, name:)
        if field.nil? || field.to_s.strip.empty?
          raise Parse::Agent::ValidationError, "#{name} is required"
        end
        s = field.to_s
        # Allow the optional _p_ prefix (some LLMs may pass storage form)
        check = s.start_with?("_p_") ? s.sub(/\A_p_/, "") : s
        unless /\A[A-Za-z][A-Za-z0-9_]{0,127}\z/.match?(check)
          raise Parse::Agent::ValidationError,
                "#{name} #{field.inspect} is not a valid identifier. " \
                "Must start with a letter and contain only letters, digits, and underscores."
        end
        s
      end
      module_function :validate_group_field!

      # @api private
      def validate_group_date_interval!(interval)
        sym = interval.to_s.downcase.to_sym
        unless GROUP_DATE_INTERVALS.include?(sym.to_s)
          raise Parse::Agent::ValidationError,
                "interval #{interval.inspect} is invalid. Must be one of " \
                "#{GROUP_DATE_INTERVALS.join(', ')}."
        end
        sym
      end
      module_function :validate_group_date_interval!

      # @api private
      # Accept IANA tz names and fixed offsets. Tolerant: empty / nil
      # returns nil (UTC). Rejects anything with characters outside the
      # tz alphabet so the value can never smuggle a pipeline operator.
      def validate_timezone!(tz)
        return nil if tz.nil? || tz.to_s.strip.empty?
        s = tz.to_s.strip
        unless /\A[A-Za-z_][A-Za-z_0-9+\-\/]{0,63}\z|\A[+\-]\d{2}:?\d{2}\z/.match?(s)
          raise Parse::Agent::ValidationError,
                "timezone #{tz.inspect} is invalid. Use an IANA name (e.g. 'America/New_York') " \
                "or a fixed offset (e.g. '+05:00')."
        end
        s
      end
      module_function :validate_timezone!

      # @api private
      # Returns [op_key, accumulator_expression]. op_key is the LLM-facing
      # name normalized ("average" → "avg"). value_field is required for
      # sum/avg/min/max — its absence is a validation error.
      def resolve_group_operation!(operation, value_field)
        op_raw = (operation || "count").to_s
        unless GROUP_OPERATIONS.key?(op_raw)
          raise Parse::Agent::ValidationError,
                "operation #{operation.inspect} is invalid. Must be one of " \
                "#{GROUP_OPERATIONS.keys.uniq.join(', ')}."
        end
        op_key = op_raw == "average" ? "avg" : op_raw
        if op_key == "count"
          [op_key, { "$sum" => 1 }]
        else
          if value_field.nil? || value_field.to_s.strip.empty?
            raise Parse::Agent::ValidationError,
                  "operation '#{op_key}' requires value_field"
          end
          [op_key, { GROUP_OPERATIONS[op_raw] => "$__VALUE__" }] # placeholder; substituted by build_group_pipeline
        end
      end
      module_function :resolve_group_operation!

      # @api private
      def normalize_group_sort(sort)
        return nil if sort.nil? || sort.to_s.empty?
        allowed = %w[value_desc value_asc key_desc key_asc]
        unless allowed.include?(sort.to_s)
          raise Parse::Agent::ValidationError,
                "sort #{sort.inspect} is invalid. Must be one of #{allowed.join(', ')}."
        end
        sort.to_s
      end
      module_function :normalize_group_sort

      # @api private
      def clamp_group_limit(limit, default:, max:)
        return default if limit.nil?
        n = Integer(limit) rescue (raise Parse::Agent::ValidationError, "limit must be an integer (got #{limit.inspect})")
        if n < 1 || n > max
          raise Parse::Agent::ValidationError, "limit must be between 1 and #{max}"
        end
        n
      end
      module_function :clamp_group_limit

      # @api private
      # Walk the where: hash and refuse any top-level key (or nested
      # $and/$or/$nor child key) outside the agent_fields allowlist.
      # Closes the same oracle hole that the aggregate pipeline walker
      # closes for $match — see check_match_keys_for_restricted_fields!.
      def assert_where_fields_in_allowlist!(class_name, where)
        return unless where.is_a?(Hash) && !where.empty?
        allowlist = MetadataRegistry.field_allowlist(class_name)
        return if allowlist.nil? || allowlist.empty?
        permitted = allowlist.map(&:to_s) | MetadataRegistry::ALWAYS_KEEP_FIELDS
        check_match_keys_for_restricted_fields!(where, permitted)
      end
      module_function :assert_where_fields_in_allowlist!

      # @api private
      # Verify each referenced field is within agent_fields (or the
      # always-keep set) when an allowlist is declared on the class.
      def assert_fields_in_allowlist!(class_name, fields)
        allowlist = MetadataRegistry.field_allowlist(class_name)
        return if allowlist.nil? || allowlist.empty?
        permitted = allowlist.map(&:to_s) | MetadataRegistry::ALWAYS_KEEP_FIELDS
        Array(fields).each do |raw|
          root = raw.to_s.sub(/\A_p_/, "").split(".").first
          next if root.nil? || root.empty?
          unless permitted.include?(root)
            raise Parse::Agent::AccessDenied.new(
              build_allowlist_refusal("field", raw.to_s, root, permitted),
            )
          end
        end
      end
      module_function :assert_fields_in_allowlist!

      # @api private
      # Resolve a wire-format field name to its MongoDB aggregation form.
      # Pointer fields are auto-prefixed with `_p_` when the local Parse
      # model class declares the field as a :pointer. createdAt/updatedAt
      # are passed through verbatim — Parse Server's /aggregate endpoint
      # translates those.
      def resolve_aggregation_field(class_name, field, force_no_pointer: false)
        s = field.to_s
        return s if s.start_with?("_p_")
        return s if %w[createdAt updatedAt _created_at _updated_at].include?(s)
        klass = (Parse::Model.find_class(class_name) rescue nil) ||
                (Parse::Model.const_get(class_name) rescue nil)
        return s unless klass && klass.respond_to?(:fields) && klass.respond_to?(:field_map)
        # Resolve the Ruby symbol to the Parse wire name (e.g., :author_id → :authorId).
        wire = (klass.field_map[s.to_sym] || s).to_s
        return wire if force_no_pointer
        if klass.fields[s.to_sym] == :pointer || klass.fields[s] == :pointer
          "_p_#{wire}"
        else
          wire
        end
      end
      module_function :resolve_aggregation_field

      # @api private
      # Build the wire-format aggregation pipeline. group_expression is
      # used when a custom _id expression is required (group_by_date);
      # otherwise the _id is "$<group_field>". When accumulator_op is
      # nil we emit a bare $group with only _id (distinct).
      def build_group_pipeline(where:, group_field:, flatten_arrays:,
                               accumulator_op:, value_field:, operation:,
                               group_expression: nil, agent: nil)
        pipeline = []
        if where.is_a?(Hash) && !where.empty?
          pipeline << { "$match" => ConstraintTranslator.translate(where, agent) }
        end
        if flatten_arrays && group_field
          pipeline << { "$unwind" => "$#{group_field}" }
        end

        group_id = group_expression || "$#{group_field}"
        group_stage = { "_id" => group_id }
        if accumulator_op
          # Substitute the value field into the placeholder accumulator.
          # operation == "count" comes through with $sum:1 already.
          if operation == "count"
            group_stage["value"] = accumulator_op
          else
            op_key = accumulator_op.keys.first
            group_stage["value"] = { op_key => "$#{value_field}" }
          end
        end
        pipeline << { "$group" => group_stage }
        pipeline
      end
      module_function :build_group_pipeline

      # @api private
      # Build the MongoDB _id expression for a date-grouped aggregation.
      # Mirrors GroupByDate#build_date_group_expression in query.rb,
      # including the timezone-aware operator form Mongo expects.
      def build_date_group_expression(field_name, interval, timezone)
        op = ->(name) {
          if timezone
            { name => { "date" => "$#{field_name}", "timezone" => timezone } }
          else
            { name => "$#{field_name}" }
          end
        }
        case interval
        when :year
          op.call("$year")
        when :month
          { "year" => op.call("$year"), "month" => op.call("$month") }
        when :week
          { "year" => op.call("$year"), "week" => op.call("$week") }
        when :day
          { "year" => op.call("$year"), "month" => op.call("$month"), "day" => op.call("$dayOfMonth") }
        when :hour
          { "year" => op.call("$year"), "month" => op.call("$month"),
            "day"  => op.call("$dayOfMonth"), "hour" => op.call("$hour") }
        when :minute
          { "year"   => op.call("$year"),  "month"  => op.call("$month"),
            "day"    => op.call("$dayOfMonth"), "hour" => op.call("$hour"),
            "minute" => op.call("$minute") }
        when :second
          { "year"   => op.call("$year"),  "month"  => op.call("$month"),
            "day"    => op.call("$dayOfMonth"), "hour" => op.call("$hour"),
            "minute" => op.call("$minute"), "second" => op.call("$second") }
        end
      end
      module_function :build_date_group_expression

      # @api private
      # Format a date _id back into an ISO-style string for the LLM. nil
      # / unrecognized values are surfaced as the literal "null".
      def format_date_key(key, interval)
        return "null" if key.nil?
        if interval == :year
          return key.to_s
        end
        return "null" unless key.is_a?(Hash)
        y, mo, d = key["year"], key["month"], key["day"]
        h, mi, s = key["hour"], key["minute"], key["second"]
        wk       = key["week"]
        case interval
        when :month  then (y.nil? || mo.nil?) ? "null" : sprintf("%04d-%02d", y, mo)
        when :week   then (y.nil? || wk.nil?) ? "null" : sprintf("%04d-W%02d", y, wk)
        when :day    then (y.nil? || mo.nil? || d.nil?) ? "null" : sprintf("%04d-%02d-%02d", y, mo, d)
        when :hour   then (y.nil? || mo.nil? || d.nil? || h.nil?) ? "null" : sprintf("%04d-%02d-%02d %02d:00", y, mo, d, h)
        when :minute then (y.nil? || mo.nil? || d.nil? || h.nil? || mi.nil?) ? "null" : sprintf("%04d-%02d-%02d %02d:%02d", y, mo, d, h, mi)
        when :second then (y.nil? || mo.nil? || d.nil? || h.nil? || mi.nil? || s.nil?) ? "null" : sprintf("%04d-%02d-%02d %02d:%02d:%02d", y, mo, d, h, mi, s)
        else "null"
        end
      end
      module_function :format_date_key

      # @api private
      # Run the group/distinct pipeline through the same security gates
      # as `aggregate` (class access, tenant scope, COLLSCAN preflight,
      # timeout, hidden-class redaction) but skip the LLM-pipeline
      # validator (we built the pipeline) and the projection walker
      # (our pipeline references derived names like _id/value that are
      # not class fields).
      #
      # @return [Hash] one of:
      #   - { rows: [...] } on success
      #   - { refused: true, reason: ..., ... } when COLLSCAN refused
      def run_aggregation_for_group_tool!(agent, class_name:, pipeline:, tool:,
                                          apply_canonical_filter: true)
        scope = resolve_tenant_scope!(agent, class_name)
        scoped = apply_tenant_scope_to_pipeline(pipeline, scope)

        # TRACK-AGENT-7 split: per-agent filter is UNCONDITIONAL; canonical
        # filter is LLM-controllable via apply_canonical_filter:.
        scoped = apply_per_agent_filter_to_pipeline(scoped, class_name, agent: agent)

        # H3: apply the class's canonical filter (e.g. soft-delete exclusion)
        # so group_by / group_by_date / distinct exclude the same rows that
        # query_class and count_objects exclude by default. This matches the
        # behavior of the generic `aggregate` tool (see line ~2218).
        if apply_canonical_filter
          scoped = apply_canonical_filter_to_pipeline(scoped, class_name, agent: agent)
        end

        if Parse::Agent.refuse_collscan? &&
           !MetadataRegistry.allow_collscan?(class_name) &&
           (match_stage = scoped.first&.dig("$match"))&.any?
          refusal = collscan_preflight(agent, class_name, match_stage)
          return refusal if refusal
        end

        # Parse Server's REST aggregate endpoint does NOT enforce per-row
        # ACL — only the SDK's mongo-direct path applies the _rperm match
        # injection via Parse::ACLScope. So we must route through
        # mongo-direct for ANY non-master identity (session_token,
        # acl_user, acl_role, including a runtime-impersonated agent whose
        # @acl_scope was cleared), not just acl_user/acl_role. Master-key
        # agents keep the REST path because they've already opted out of ACL.
        use_direct = agent.respond_to?(:requires_mongo_direct?) && agent.requires_mongo_direct? &&
                     defined?(Parse::MongoDB) && Parse::MongoDB.enabled?

        with_timeout(tool) do
          rows =
            if use_direct
              translated = Parse::Query.new(class_name).send(
                :translate_pipeline_for_direct_mongodb, scoped,
              )
              raw_rows = Parse::MongoDB.aggregate(class_name, translated, **agent.acl_scope_kwargs)
              raw_rows.map { |raw| Parse::MongoDB.convert_aggregation_document(raw) }
            else
              response = agent.client.aggregate_pipeline(class_name, scoped, **agent.request_opts)
              raise "#{tool} aggregation failed: #{response.error}" unless response.success?
              response.results
            end
          rows = redact_hidden_classes!(rows, agent: agent)
          { rows: rows }
        end
      end
      module_function :run_aggregation_for_group_tool!

      # @api private
      # Inspect the keys of a [[key, value], ...] pair list. When every
      # non-nil key is a string of the form "<Class>$<id>" with the SAME
      # Class, strip the prefix and return [Class, rewritten_pairs].
      # Otherwise return [nil, pairs] unchanged.
      def extract_pointer_class!(pairs)
        classes = pairs.map { |k, _| k.is_a?(String) && k.match(/\A([A-Z_]\w*)\$(\w+)\z/) ? Regexp.last_match(1) : nil }
        return [nil, pairs] if classes.compact.empty?
        return [nil, pairs] if classes.compact.uniq.size != 1
        # Allow some keys to be nil (missing values) — they pass through.
        return [nil, pairs] unless pairs.all? { |k, _| k.nil? || (k.is_a?(String) && k.include?("$")) }
        cls = classes.compact.first
        rewritten = pairs.map { |k, v| [k.is_a?(String) ? k.sub(/\A#{cls}\$/, "") : k, v] }
        [cls, rewritten]
      end
      module_function :extract_pointer_class!

      # @api private
      # H2: After extract_pointer_class! resolves [cls, pairs], check whether
      # +cls+ is an agent_hidden class. If it is, replace every key (objectId)
      # with nil so the hidden class's row identifiers are not surfaced, and
      # return nil as the pointer_class so the class name is also suppressed
      # from the envelope.
      #
      # Returns [pointer_class, pairs] — unchanged when not hidden, redacted
      # when the class is hidden.
      def redact_hidden_pointer_groups!(pointer_class, pairs, agent: nil)
        return [pointer_class, pairs] if pointer_class.nil?
        return [pointer_class, pairs] unless Parse::Agent::MetadataRegistry.hidden?(pointer_class) ||
                                             (agent && !agent.class_filter_permits?(pointer_class))

        # Redact: suppress class name and zero out all objectId keys.
        redacted_pairs = pairs.map { |_k, v| [nil, v] }
        [nil, redacted_pairs]
      end
      module_function :redact_hidden_pointer_groups!

      # @api private
      # Append wire-side $sort and $limit stages so the database — not
      # Ruby — does the truncation. Without this, a group_by over a
      # high-cardinality field returns every group over the wire before
      # Ruby truncates, blowing up both bandwidth and tool-response
      # budgets.
      #
      # We append $limit at `cap + 1` so the handler can still detect
      # truncation server-side (received cap+1 rows => more existed).
      # Sort vocabulary mirrors the LLM-facing surface:
      #   value_desc/value_asc — sort by the $group accumulator output
      #   key_desc/key_asc     — sort by the $group _id
      # `default_sort` applies when the caller didn't specify one (used
      # by group_by_date for chronological "key_asc").
      def append_sort_limit!(pipeline, sort_choice:, cap:, default_sort: nil)
        effective_sort = sort_choice || default_sort
        if effective_sort
          direction = effective_sort.end_with?("_desc") ? -1 : 1
          key       = effective_sort.start_with?("value") ? "value" : "_id"
          pipeline << { "$sort" => { key => direction } }
        end
        pipeline << { "$limit" => cap + 1 }
        pipeline
      end
      module_function :append_sort_limit!

      # @api private
      # Build the dry-run response envelope. Surfaces the exact pipeline
      # the handler would have executed plus the resolved parameters so
      # a caller can hand the pipeline to `aggregate` (or mutate and
      # re-issue) without re-deriving the field-mangling rules.
      def dry_run_envelope(class_name:, pipeline:, params:)
        cleaned = params.reject { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
        {
          dry_run: true,
          class_name: class_name,
          pipeline: pipeline,
          parameters: cleaned,
          hint: "dry_run mode — the pipeline above was constructed but NOT executed. " \
                "Re-issue this call with dry_run: false to run it, or pass the pipeline " \
                "to the aggregate tool (modified as needed) for full pipeline control.",
        }
      end
      module_function :dry_run_envelope

      # @api private
      # Sort a [[key, value], ...] list per the sort_choice.
      def sort_groups(pairs, sort_choice)
        return pairs if sort_choice.nil?
        case sort_choice
        when "value_desc" then pairs.sort_by { |_, v| -sort_key_numeric(v) }
        when "value_asc"  then pairs.sort_by { |_, v|  sort_key_numeric(v) }
        when "key_desc"   then pairs.sort_by { |k, _| sort_key_for(k) }.reverse
        when "key_asc"    then pairs.sort_by { |k, _| sort_key_for(k) }
        else pairs
        end
      end
      module_function :sort_groups

      # @api private
      # Stable comparable representation for mixed-type keys. nil sorts
      # last (regardless of direction; callers reverse for desc).
      def sort_key_for(value)
        case value
        when nil      then [1, ""]
        when Numeric  then [0, value]
        when String   then [0, value]
        else               [0, value.to_s]
        end
      end
      module_function :sort_key_for

      # @api private
      def sort_key_numeric(value)
        case value
        when Numeric then value
        when nil     then 0
        else
          n = Float(value) rescue 0
          n
        end
      end
      module_function :sort_key_numeric

      # @api private
      # Normalize a group key for the wire envelope: nil → "null",
      # everything else is left as-is (Parse Server returns strings,
      # numbers, booleans, and dates verbatim).
      def normalize_group_key(key)
        key.nil? ? "null" : key
      end
      module_function :normalize_group_key

      # ============================================================
      # EXPORT
      # ============================================================

      # Export Parse data as CSV, Markdown table, or fixed-width text table.
      #
      # Two modes:
      # - **Query mode** (default): pass `where:`, `keys:`, `include:`, `order:`,
      #   `limit:`. Underlying call is the same as `query_class` so every
      #   access-control gate (`agent_hidden`, `agent_fields` allowlist,
      #   include-path resolution, post-fetch redaction) applies.
      # - **Aggregate mode**: pass `pipeline:` (mutually exclusive with the
      #   query-mode args). Underlying call is the same as `aggregate` so the
      #   pipeline access policy walker (`$lookup` into hidden classes, field-
      #   level allowlist on `$project`/`$addFields` etc.) applies.
      #
      # Column control:
      # - `columns:` is an ordered array of column specs. Each spec is either
      #   a String (field name, used as the header) or a Hash `{field => header}`
      #   to alias. Dotted paths (`"subject.name"`) extract nested values from
      #   include-resolved pointer fields.
      # - When `columns:` is nil, headers are inferred from the first row's
      #   keys (excluding Parse-internal fields like `__type`).
      #
      # Output:
      # - `format: "csv"` (default) — RFC 4180 CSV via Ruby's stdlib `csv`.
      # - `format: "markdown"` — GFM-style pipe table with `---` separator row.
      # - `format: "table"` — fixed-width ASCII table with `+---+` borders.
      #
      # @return [Hash] `{ class_name:, format:, headers:, row_count:, output: "..." }`
      # Default cap on rows in the formatted output. Sized so that even a
      # wide-schema CSV (10-15 columns) stays under ~80 KB / ~20k tokens —
      # large enough for a sensible export, small enough to not dominate an
      # LLM context window. Override via the `row_cap:` parameter up to
      # MAX_EXPORT_ROW_CAP.
      DEFAULT_EXPORT_ROW_CAP = 1_000

      # Hard ceiling on row_cap regardless of caller override. Past this
      # point the LLM should be calling a different surface (operator-run
      # `rake mcp:tool[export_data,...]`, application-level DB export, etc).
      # Even at this ceiling the dispatcher's MAX_TOOL_RESPONSE_BYTES (4 MiB)
      # may still trim oversized output.
      MAX_EXPORT_ROW_CAP = 10_000

      def export_data(agent, class_name:, where: nil, keys: nil, include: nil,
                             order: nil, limit: nil, skip: nil, pipeline: nil,
                             columns: nil, format: "csv", row_cap: nil, **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :find)
        # Tenant scope enforcement: resolve once here and pass to mode helpers.
        scope = resolve_tenant_scope!(agent, class_name)

        format_s = format.to_s.downcase
        unless %w[csv markdown table].include?(format_s)
          raise Parse::Agent::ValidationError,
                "format must be one of: csv, markdown, table (got #{format.inspect})"
        end

        effective_cap = if row_cap.nil?
            DEFAULT_EXPORT_ROW_CAP
          else
            [row_cap.to_i, MAX_EXPORT_ROW_CAP].min.tap do |c|
              raise Parse::Agent::ValidationError, "row_cap must be positive" if c < 1
            end
          end

        rows = if pipeline
            export_via_aggregate(agent, class_name: class_name, pipeline: pipeline, scope: scope)
          else
            export_via_query(agent, class_name: class_name, where: where, keys: keys,
                                    include: include, order: order, limit: limit, skip: skip,
                                    scope: scope)
          end

        available_rows = rows.size
        truncated      = available_rows > effective_cap
        rows           = rows.first(effective_cap) if truncated

        column_specs   = normalize_export_columns(columns, rows.first)
        headers        = column_specs.map { |spec| spec[:header] }
        extracted_rows = rows.map do |row|
          column_specs.map { |spec| stringify_export_value(extract_export_value(row, spec[:path])) }
        end

        output = case format_s
          when "csv"      then format_export_csv(headers, extracted_rows)
          when "markdown" then format_export_markdown(headers, extracted_rows)
          when "table"    then format_export_text_table(headers, extracted_rows)
          end

        result = {
          class_name: class_name,
          format:     format_s,
          headers:    headers,
          row_count:  extracted_rows.size,
          output:     output,
        }
        if truncated
          result[:truncated]      = true
          result[:available_rows] = available_rows
          result[:row_cap]        = effective_cap
          result[:hint]           = "Output truncated at row_cap=#{effective_cap} of #{available_rows} available rows. " \
                                    "Narrow with where:/pipeline filters, or set row_cap: explicitly (max #{MAX_EXPORT_ROW_CAP}). " \
                                    "For full exports of larger sets use the operator-facing rake mcp:tool[export_data,...] " \
                                    "directly rather than reading the rows back through the LLM."
        end
        result
      end

      # @api private
      def export_via_query(agent, class_name:, where:, keys:, include:, order:, limit:, skip: nil, scope: nil)
        # Reuse query_class's gates by routing through it directly.
        # query_class returns a ResultFormatter-wrapped hash; we want the raw rows.
        query = {}
        query[:limit] = [limit || Agent::DEFAULT_LIMIT, Agent::MAX_LIMIT].min
        query[:skip]  = skip if skip && skip > 0
        query[:order] = order if order

        # NEW-TOOLS-5: validate keys: against identifier regex before
        # the allowlist intersection. This refuses leading-underscore
        # names (_hashed_password, _session_token, _rperm, _wperm, etc.)
        # at the boundary, so they cannot leak through even on classes
        # WITHOUT an agent_fields allowlist.
        validated_keys = validate_keys!(keys)
        allowlist = MetadataRegistry.field_allowlist(class_name)
        caller_keys = validated_keys&.any? ? validated_keys : nil
        effective_keys =
          if allowlist && allowlist.any?
            permitted = allowlist.map(&:to_s) | MetadataRegistry::ALWAYS_KEEP_FIELDS
            caller_keys ? (caller_keys & permitted) : allowlist.map(&:to_s)
          else
            caller_keys
          end

        include = validate_include!(include)
        assert_include_paths_accessible!(class_name, include, agent: agent)
        # keys-on-include auto-projection. Export rows are the bulkiest
        # surface (full-row CSV / Markdown / JSON dumps), so trimming
        # included pointers to their agent_join_fields here pays back the
        # most in token cost. The truncation map is not surfaced on the
        # export envelope (callers consuming CSV/Markdown don't carry
        # structured metadata) but the per-row payload shape is identical
        # to query_class.
        include_projection = apply_include_projection(class_name, effective_keys, include)
        effective_keys = include_projection[:effective_keys]
        query[:keys] = effective_keys.join(",") if effective_keys&.any?
        query[:include] = include.join(",") if include&.any?

        effective_where = apply_tenant_scope_to_where(where, scope, class_name)
        # TRACK-AGENT-7 split: per-agent filter is UNCONDITIONAL.
        effective_where = apply_per_agent_filter_to_where(effective_where, class_name, agent: agent)
        # H3: apply the class's canonical filter so exported rows are the same
        # "valid state" subset that query_class returns. Exporting soft-deleted
        # rows when query_class hides them would be a silent data-integrity gap.
        effective_where = apply_canonical_filter_to_where(effective_where, class_name, agent: agent)
        translated_where = nil
        if effective_where && !effective_where.empty?
          translated_where = ConstraintTranslator.translate(effective_where, agent)
          query[:where] = translated_where.to_json
        end

        rows = nil
        with_timeout(:export_data) do
          if agent.respond_to?(:acl_scope_requires_direct?) && agent.acl_scope_requires_direct?
            rows = execute_find_via_direct(
              agent, class_name,
              where: translated_where, limit: query[:limit], skip: query[:skip] || 0,
              order: order, keys: effective_keys, include: include,
            )
          else
            response = agent.client.find_objects(class_name, query, **agent.request_opts)
            raise "Export query failed: #{response.error}" unless response.success?
            rows = response.results
          end
        end

        redact_hidden_classes!(rows, agent: agent)
      end
      module_function :export_via_query

      # @api private
      def export_via_aggregate(agent, class_name:, pipeline:, scope: nil)
        PipelineValidator.validate!(pipeline)
        enforce_pipeline_access_policy!(class_name, pipeline, agent: agent)
        # Prepend tenant scope $match before per-agent + canonical filter and auto-limit.
        scoped_pipeline = apply_tenant_scope_to_pipeline(pipeline, scope)
        # TRACK-AGENT-7 split: per-agent filter is UNCONDITIONAL.
        scoped_pipeline = apply_per_agent_filter_to_pipeline(scoped_pipeline, class_name, agent: agent)
        # H3: apply canonical filter so pipeline-mode exports exclude the same
        # rows that query_class (and the conversational aggregate tool) exclude.
        scoped_pipeline = apply_canonical_filter_to_pipeline(scoped_pipeline, class_name, agent: agent)
        # Same auto-limit injection as the conversational aggregate tool —
        # an unbounded pipeline against a high-cardinality $group would
        # blow past export_data's row_cap and still hand the server-side
        # cost to Parse. The row_cap clips the result for display; this
        # clips the underlying query too.
        effective_pipeline, _auto_limited = ensure_aggregate_terminal_limit(scoped_pipeline)

        # Route to mongo-direct for ANY non-master identity. The REST
        # aggregate endpoint enforces no ACL, so a session-token agent's
        # REST aggregate would run unscoped — only master-key agents
        # (which opted out of ACL) keep the REST path.
        use_direct = agent.respond_to?(:requires_mongo_direct?) &&
                     agent.requires_mongo_direct? &&
                     defined?(Parse::MongoDB) && Parse::MongoDB.enabled?

        rows = nil
        with_timeout(:export_data) do
          if use_direct
            translated = Parse::Query.new(class_name).send(
              :translate_pipeline_for_direct_mongodb, effective_pipeline,
            )
            raw_rows = Parse::MongoDB.aggregate(class_name, translated, **agent.acl_scope_kwargs)
            rows = raw_rows.map { |raw| Parse::MongoDB.convert_aggregation_document(raw) }
          else
            response = agent.client.aggregate_pipeline(class_name, effective_pipeline, **agent.request_opts)
            raise "Export aggregation failed: #{response.error}" unless response.success?
            rows = response.results
          end
        end

        redact_hidden_classes!(rows, agent: agent)
      end
      module_function :export_via_aggregate

      # @api private
      # Field paths that may never appear in an export, regardless of any
      # per-class allowlist. Closes NEW-TOOLS-8: a caller that paired
      # `columns: ["_session_token"]` with `keys: [...]` would extract
      # internal Parse-Server fields directly through the export pipeline,
      # bypassing the skip-list in {infer_export_columns_from} which only
      # filters fields that were NOT explicitly requested.
      EXPORT_DENIED_COLUMN_PREFIXES = %w[
        _hashed_password _session_token _perishable_token _email_verify_token
        _email_verify_token_expires_at _password_history bcryptPassword
        authData _rperm _wperm ACL _account_lockout_expires_at
      ].freeze

      # Identifier pattern shared with validate_keys! / validate_include!.
      # Enforces letter-prefixed dotted paths so the wire format passes
      # through Parse Server's projector cleanly.
      EXPORT_COLUMN_PATH_RE = /\A[A-Za-z][A-Za-z0-9_.]{0,127}\z/.freeze

      # @api private
      # Resolve a `columns:` parameter into an ordered list of
      #   { path: "dotted.field.path", header: "Display Name" }
      # entries. When columns is nil, infer from the first row.
      def normalize_export_columns(columns, sample_row)
        return infer_export_columns_from(sample_row) if columns.nil? || (columns.respond_to?(:empty?) && columns.empty?)
        unless columns.is_a?(Array)
          raise Parse::Agent::ValidationError, "columns must be an Array (got #{columns.class})"
        end

        columns.map do |spec|
          case spec
          when String
            validate_export_column_path!(spec)
            { path: spec, header: spec }
          when Hash
            unless spec.size == 1
              raise Parse::Agent::ValidationError,
                    "column hash must have exactly one field => header entry (got #{spec.inspect})"
            end
            path, header = spec.first
            path_str = path.to_s
            validate_export_column_path!(path_str)
            { path: path_str, header: header.to_s }
          when Symbol
            validate_export_column_path!(spec.to_s)
            { path: spec.to_s, header: spec.to_s }
          else
            raise Parse::Agent::ValidationError,
                  "column spec must be String, Symbol, or single-entry Hash (got #{spec.class})"
          end
        end
      end
      module_function :normalize_export_columns

      # @api private
      # NEW-TOOLS-8: validate an `export_data` column path against the
      # identifier regex and the sensitive-prefix denylist. Refuses
      # internal Parse-Server fields (`_hashed_password`, `_session_token`,
      # `authData.*`, ACL/permission columns, etc.) at the parameter
      # boundary, regardless of whether the export class declares an
      # `agent_fields` allowlist.
      def validate_export_column_path!(path)
        s = path.to_s
        unless EXPORT_COLUMN_PATH_RE.match?(s)
          raise Parse::Agent::ValidationError,
                "column path #{s.inspect} is invalid. Each path must start with a " \
                "letter and contain only letters, digits, underscores, and dots " \
                "(max 128 chars). Underscore-prefixed names (e.g. _hashed_password, " \
                "_session_token, _rperm) are not permitted."
        end
        # Per-segment underscore check: refuse "authData._provider" /
        # "x._hashed_password" where the root passes but a sub-segment
        # is an internal field.
        if s.include?(".")
          s.split(".").each do |segment|
            next if segment.empty?
            next if /\A[A-Za-z]/.match?(segment)
            raise Parse::Agent::ValidationError,
                  "column path #{s.inspect} has an underscore-prefixed " \
                  "segment (#{segment.inspect}). Each dotted path segment " \
                  "must start with a letter."
          end
        end
        # Root-level sensitive-prefix denylist. Catches `_hashed_password`
        # in addition to obvious top-level entries like `authData`.
        root = s.split(".").first
        if EXPORT_DENIED_COLUMN_PREFIXES.include?(root)
          raise Parse::Agent::ValidationError,
                "column path #{s.inspect} references a denied field root " \
                "(#{root.inspect}). Internal Parse-Server columns " \
                "(_hashed_password, _session_token, authData, ACL, _rperm, _wperm, " \
                "etc.) cannot be exported through the agent surface."
        end
        s
      end
      module_function :validate_export_column_path!

      # @api private
      def infer_export_columns_from(sample_row)
        return [{ path: "objectId", header: "objectId" }] unless sample_row.is_a?(Hash)
        # Skip Parse-internal envelope keys; surface real data columns.
        skip = %w[__type className ACL _rperm _wperm _hashed_password _session_token]
        sample_row.keys.reject { |k| skip.include?(k.to_s) }.map do |k|
          { path: k.to_s, header: k.to_s }
        end
      end
      module_function :infer_export_columns_from

      # @api private
      # Extract a value via a dotted path. Each segment indexes into a Hash
      # under either its string or symbol form. Returns nil if any segment
      # misses or hits a non-Hash.
      def extract_export_value(row, path)
        path.to_s.split(".").reduce(row) do |acc, seg|
          break nil if acc.nil?
          if acc.is_a?(Hash)
            acc[seg] || acc[seg.to_sym]
          else
            nil
          end
        end
      end
      module_function :extract_export_value

      # @api private
      def stringify_export_value(value)
        case value
        when nil           then ""
        when String        then value
        when Hash, Array   then value.to_json
        when Time, DateTime then value.iso8601
        when Date          then value.to_s
        else                    value.to_s
        end
      end
      module_function :stringify_export_value

      # @api private
      def format_export_csv(headers, rows)
        require "csv"
        CSV.generate do |csv|
          csv << headers
          rows.each { |r| csv << r }
        end
      end
      module_function :format_export_csv

      # @api private
      def format_export_markdown(headers, rows)
        return "" if headers.empty?
        lines = []
        lines << "| #{headers.join(" | ")} |"
        lines << "| #{headers.map { "---" }.join(" | ")} |"
        rows.each { |r| lines << "| #{r.map { |c| c.to_s.gsub(/\r?\n/, " ").gsub(/([\\|])/, '\\\\\1') }.join(" | ")} |" }
        lines.join("\n")
      end
      module_function :format_export_markdown

      # @api private
      def format_export_text_table(headers, rows)
        return "" if headers.empty?
        widths = headers.each_with_index.map do |h, i|
          [h.to_s.length, *rows.map { |r| r[i].to_s.length }].max
        end
        sep = "+-" + widths.map { |w| "-" * w }.join("-+-") + "-+"
        fmt = ->(cells) {
          "| " + cells.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join(" | ") + " |"
        }
        ([sep, fmt.call(headers), sep] + rows.map(&fmt) + [sep]).join("\n")
      end
      module_function :format_export_text_table

      # Explain a query's execution plan
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param where [Hash] query constraints
      # @return [Hash] query explanation
      def explain_query(agent, class_name:, where: nil, **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :find)
        # No direct-MongoDB equivalent of Parse Server's REST explain
        # plan exists today, and routing this through master-key REST
        # under an acl_user/acl_role agent would silently bypass the
        # scope. Refuse explicitly; the LLM can fall back to running
        # the query through a session_token-bound or master-key agent
        # when explain output is genuinely needed.
        if agent.respond_to?(:acl_scope_requires_direct?) && agent.acl_scope_requires_direct?
          raise Parse::Agent::ValidationError,
                "explain_query is not available under acl_user / acl_role scope. " \
                "Parse Server's REST explain endpoint has no mongo-direct " \
                "equivalent, and routing the call through master-key REST " \
                "would bypass the agent's declared scope. Re-run the explain " \
                "from a session_token-bound or master-key agent."
        end
        query = { explain: true, limit: 1 }

        # TRACK-AGENT-7 split: per-agent filter is UNCONDITIONAL.
        # H3: apply canonical filter so the explain plan reflects the query
        # that query_class actually executes (same soft-delete / valid-state
        # predicate). Without this, explain_query and query_class could report
        # different index usage for classes with agent_canonical_filter.
        effective_where = apply_per_agent_filter_to_where(where, class_name, agent: agent)
        effective_where = apply_canonical_filter_to_where(effective_where, class_name, agent: agent)

        if effective_where && !effective_where.empty?
          query[:where] = ConstraintTranslator.translate(effective_where, agent).to_json
        end

        response = agent.client.find_objects(class_name, query, **agent.request_opts)

        unless response.success?
          # Parse Server 9.0+ defaults `allowPublicExplain` to false, so a
          # non-master agent's explain is rejected. Surface that as actionable
          # guidance instead of a bare permission error.
          if response.respond_to?(:permission_denied?) && response.permission_denied?
            raise "Explain failed: #{response.error} — Parse Server 9.0+ defaults " \
                  "allowPublicExplain to false; query explain requires a master-key agent " \
                  "or `allowPublicExplain: true` in the server's databaseOptions."
          end
          raise "Explain failed: #{response.error}"
        end

        {
          class_name: class_name,
          constraints: where || {},
          explanation: response.result,
        }
      end

      # ============================================================
      # METHOD TOOLS
      # ============================================================

      # Call an agent-allowed method on a Parse class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param method_name [String] the name of the method to call
      # @param object_id [String, nil] object ID for instance methods
      # @param arguments [Hash] method arguments
      # @return [Hash] method result
      def call_method(agent, class_name:, method_name:, object_id: nil, arguments: nil, **_kwargs)
        # Bypass-fix (v4.1.x security): every other tool entry calls this
        # guard, but call_method previously skipped it — a hidden class that
        # also declared an agent_method could be reached here. The CLP `op:`
        # is wired AFTER we know the method's permission tier (below) so
        # we can pass the right operation to the gate; the first call here
        # checks class-visibility / class-allowlist only.
        assert_class_accessible!(class_name, agent: agent)
        # NEW-TOOLS-9: method_name and object_id format validation.
        assert_method_name!(method_name)
        assert_object_id!(object_id)
        klass = Parse::Model.find_class(class_name)
        raise "Class not found: #{class_name}" unless klass

        method_sym = method_name.to_sym

        # Check if method is agent-allowed
        unless klass.respond_to?(:agent_method_allowed?) && klass.agent_method_allowed?(method_sym)
          raise "Method '#{method_name}' is not agent-allowed on #{class_name}. " \
                "Only methods marked with agent_method, agent_readonly, agent_write, or agent_admin can be called."
        end

        # Check permission level
        unless klass.agent_can_call?(method_sym, agent.permissions)
          method_info = klass.agent_method_info(method_sym)
          required = method_info[:permission] || :readonly
          raise "Permission denied: '#{method_name}' requires #{required} permissions. " \
                "Current level: #{agent.permissions}"
        end

        # Per-instance `methods:` filter. Applied after declaration check,
        # tier check, and class-accessibility check — i.e. only as a final
        # narrowing of an otherwise permitted invocation. Filter cannot
        # elevate: a method not declared via `agent_method` is never
        # reachable regardless of the filter.
        if agent.method_filtered?(method_sym, class_name: class_name)
          raise Parse::Agent::MethodFiltered,
                "Method '#{class_name}.#{method_name}' is not enabled for this agent instance " \
                "(excluded by the configured methods: filter)."
        end

        method_info = klass.agent_method_info(method_sym)

        # Operator-level env-gate for write/admin methods invoked through
        # call_method. Mirrors the gate in Parse::Agent#execute that
        # protects the direct create/update/delete tools: even if the
        # agent permission level allows it, the env var must also be set.
        required_perm = method_info[:permission] || :readonly
        case required_perm
        when :write
          unless Parse::Agent.write_tools_enabled?
            raise Parse::Agent::AccessDenied.new(
                    class_name,
                    "Write methods are disabled. " \
                    "Set PARSE_AGENT_ALLOW_WRITE_TOOLS=true on the server to call '#{class_name}.#{method_name}'.",
                  )
          end
        when :admin
          unless Parse::Agent.schema_ops_enabled?
            raise Parse::Agent::AccessDenied.new(
                    class_name,
                    "Admin methods are disabled. " \
                    "Set PARSE_AGENT_ALLOW_SCHEMA_OPS=true on the server to call '#{class_name}.#{method_name}'.",
                  )
          end
        end

        # Class-Level Permissions gate for call_method. Maps the
        # method's declared permission tier onto the corresponding
        # CLP operation so a class whose CLP doesn't grant write /
        # delete to the agent's scope can't be reached via a
        # `:write` / `:admin` agent_method. `:readonly` methods are
        # checked against CLP `:find` because they're typically
        # query-style code paths. The developer's method body
        # remains responsible for any internal queries it runs —
        # this gate is the BOUNDARY check at the method-name level.
        if agent.respond_to?(:acl_permission_strings)
          clp_op =
            case required_perm
            when :admin   then :delete
            when :write   then :update
            else               :find
            end
          perms = agent.acl_permission_strings
          unless Parse::CLPScope.permits?(class_name.to_s, clp_op, perms)
            raise Parse::Agent::AccessDenied.new(
              class_name,
              "Class '#{class_name}' CLP refuses #{clp_op} (mapped from " \
              "#{required_perm} agent_method) for the agent's scope.",
              kind: :clp_denied,
            )
          end
        end
        args = arguments || {}
        args = args.transform_keys(&:to_sym) if args.is_a?(Hash)

        # Apply mass-assignment guards. Always-denied keys come first:
        # +_hashed_password+, +authData+, +_session_token+, +sessionToken+,
        # +ACL+, +objectId+, +id+, +username+, +_rperm+, +_wperm+,
        # +_perishable_token+, +_email_verify_token+, +createdAt+,
        # +updatedAt+, +className+, +__type+. These can never flow
        # through +call_method+ regardless of +permitted_keys+. Then if
        # the method declared +permitted_keys+, the remaining args are
        # intersected with that allowlist.
        if args.is_a?(Hash) && !args.empty?
          violated = args.each_key.select { |k| CALL_METHOD_DENIED_KEYS.include?(k) }
          unless violated.empty?
            raise Parse::Agent::ValidationError,
                  "Method '#{method_name}' cannot accept arguments " \
                  "#{violated.inspect}; these keys reference protected " \
                  "Parse columns (password hashes, ACL, auth data, " \
                  "identifiers, timestamps) and are never permitted via " \
                  "call_method regardless of permitted_keys."
          end
          if method_info[:permitted_keys]
            permitted = method_info[:permitted_keys] + AGENT_METHOD_RESERVED_ARG_KEYS
            extra = args.each_key.reject { |k| permitted.include?(k) }
            unless extra.empty?
              raise Parse::Agent::ValidationError,
                    "Method '#{method_name}' does not permit arguments " \
                    "#{extra.inspect}. Permitted keys: " \
                    "#{method_info[:permitted_keys].inspect}."
            end
          end
        end

        # Dry-run handling. Two paths:
        #
        # 1. The method declared +supports_dry_run: true+ — keep the
        #    +dry_run+ flag in +args+ so the method body can branch on
        #    it and produce its own preview (e.g., a structural diff,
        #    pre-flight counters). The method controls the contract.
        #
        # 2. The method DID NOT declare dry-run support but the caller
        #    asked for one anyway. Previously we refused with a
        #    ValidationError. The MCP-caller perspective on that
        #    refusal is "I can't safely preview anything that wasn't
        #    pre-blessed by the author," which is unhelpful — the gate
        #    layer can ALWAYS safely report what the call WOULD do
        #    (permission tier resolved, args validated, object resolved
        #    when needed) without invoking the method itself. We now
        #    return a structural preview envelope and the +dry_run+ arg
        #    is stripped before any execution path. The preview is
        #    explicitly flagged +supports_real_dry_run: false+ so a
        #    consumer knows the method body wasn't consulted and a real
        #    dry-run (with method-author logic) isn't available.
        dry_run_requested = args.key?(:dry_run) && args[:dry_run]
        if dry_run_requested && !method_info[:supports_dry_run]
          preview_args = args.reject { |k, _| k == :dry_run }
          # Best-effort object resolution: an instance method's dry-run
          # should fail loudly if the targeted object doesn't exist,
          # since the same lookup will fail at execution time.
          if method_info[:type] == :instance
            raise "object_id required for instance method '#{method_name}'" unless object_id
            obj_exists = !klass.find(object_id).nil?
            unless obj_exists
              raise "Object not found: #{class_name}##{object_id}"
            end
          end
          return {
            class_name:             class_name,
            method:                 method_name,
            object_id:              object_id,
            dry_run:                true,
            supports_real_dry_run:  false,
            would_call: {
              class:     class_name,
              method:    method_name,
              type:      method_info[:type]&.to_s,
              object_id: object_id,
              args:      preview_args,
            },
            note: "The method '#{class_name}.#{method_name}' did not declare supports_dry_run: true, so no method-side preview is available. " \
                  "This response confirms the call would pass the permission/args/object gates the agent enforces; the method body was NOT invoked. " \
                  "Remove dry_run to execute the operation for real.",
          }
        end

        # If the method didn't declare dry-run support and the caller
        # passed a falsy +dry_run+ (or sent the key without it being
        # truthy), strip it before forwarding — the method body has no
        # idea about +dry_run+ and would raise ArgumentError on the
        # unexpected kwarg.
        if args.key?(:dry_run) && !method_info[:supports_dry_run]
          args = args.reject { |k, _| k == :dry_run }
        end

        # Execute with timeout - user methods could be slow
        with_timeout(:call_method) do
          result = if method_info[:type] == :instance
              raise "object_id required for instance method '#{method_name}'" unless object_id
              obj = klass.find(object_id)
              raise "Object not found: #{class_name}##{object_id}" unless obj
              call_with_args(obj, method_sym, args, agent: agent)
            else
              call_with_args(klass, method_sym, args, agent: agent)
            end

          {
            class_name: class_name,
            method: method_name,
            object_id: object_id,
            result: serialize_result(result, agent: agent),
          }
        end
      end

      private

      # Execute a block with a timeout.
      #
      # Wraps the block in Kernel#Timeout.timeout, which is the only timeout
      # mechanism available for REST-mediated agent tools.  The Ruby-level
      # timeout can interrupt at unsafe points (e.g. inside a C-extension or
      # mutex), so it is a last-resort safety net rather than a hard guarantee.
      # Timeout values are resolved via Tools.timeout_for so registered-tool
      # overrides are honoured.
      #
      # NOTE: Parse Server's REST surface (/classes, /aggregate) does not expose
      # a maxTimeMS parameter.  maxTimeMS is only available through the direct
      # Parse::MongoDB path (Parse::MongoDB.find / .aggregate), which is
      # bypassed by these REST-mediated tools.
      #
      # @param tool_name [Symbol] the tool being executed (for error messages)
      # @yield the block to execute with timeout
      # @raise [Agent::ToolTimeoutError] if timeout is exceeded
      def with_timeout(tool_name)
        timeout = Tools.timeout_for(tool_name)
        Timeout.timeout(timeout) { yield }
      rescue Timeout::Error
        raise Agent::ToolTimeoutError.new(tool_name, timeout)
      end

      # ============================================================
      # COLLSCAN pre-flight helpers (Feature 3)
      # ============================================================

      # Run a cheap explain pre-flight on the given where clause.
      # Returns a refusal hash if COLLSCAN is detected, nil if safe to proceed.
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] Parse class name
      # @param where [Hash] raw (untranslated) where constraints
      # @return [Hash, nil] refusal hash or nil
      def collscan_preflight(agent, class_name, where)
        explain_result = run_explain(agent, class_name, where)
        return nil unless explain_result

        winning_plan = explain_result.dig("queryPlanner", "winningPlan") ||
                       explain_result["winningPlan"] ||
                       explain_result

        if collscan?(winning_plan)
          refusal = {
            refused: true,
            reason: "COLLSCAN on #{class_name}",
            suggestion: "Add a filter on an indexed field, or call explain_query directly to inspect the plan.",
          }
          if Parse::Agent.expose_explain?
            refusal[:winning_plan] = summarize_plan(winning_plan)
          end
          refusal
        else
          nil
        end
      end

      # Detect COLLSCAN in a query plan node. Recursively walks inputStage/inputStages.
      #
      # @param plan [Hash, nil] winning plan node
      # @return [Boolean]
      def collscan?(plan)
        return false unless plan.is_a?(Hash)
        return true if plan["stage"] == "COLLSCAN"

        # Recurse into nested inputStage
        return true if collscan?(plan["inputStage"])

        # Recurse into parallel inputStages array (OR_STAGE, etc.)
        if plan["inputStages"].is_a?(Array)
          return true if plan["inputStages"].any? { |s| collscan?(s) }
        end

        false
      end

      # Run an explain query on the given where hash, returning the parsed result hash.
      # Translates constraints for security. Returns nil on any failure (fail open).
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] Parse class name
      # @param where [Hash] raw where constraints
      # @return [Hash, nil]
      def run_explain(agent, class_name, where)
        query = { explain: true, limit: 1 }
        query[:where] = ConstraintTranslator.translate(where, agent).to_json
        response = agent.client.find_objects(class_name, query, **agent.request_opts)
        return nil unless response.success?
        response.result
      rescue StandardError
        nil
      end

      # Produce a compact, human-readable summary of a plan node.
      #
      # @param plan [Hash, nil]
      # @return [String]
      def summarize_plan(plan)
        return "unknown" unless plan.is_a?(Hash)
        stage = plan["stage"] || "unknown"
        filter = plan["filter"] ? " filter=#{plan["filter"].inspect}" : ""
        "#{stage}#{filter}"
      end

      # Call a method with arguments using parameter introspection.
      #
      # We avoid the prior "try kwargs, rescue ArgumentError, retry with no args"
      # pattern because it silently swallows real ArgumentErrors raised from inside
      # the method body (e.g. validation failures), making bugs invisible. Instead
      # we look at Method#parameters and either pass kwargs, or raise a clear
      # error explaining why the call can't be made.
      #
      # @raise [ArgumentError] if the method is blocked, takes positional args
      #   only, or accepts no args but was called with some.
      def call_with_args(target, method_sym, args, agent: nil)
        validate_method_name!(method_sym)

        # Inject `agent:` when the target method explicitly accepts it
        # (declared `def archive(agent:, **)` or `def archive(**kwargs)`).
        # The agent_method author opts in by declaring the keyword in
        # the signature — methods that don't reference it never see it,
        # which preserves backwards compatibility for existing
        # agent_method declarations.
        params = target.method(method_sym).parameters
        param_names = params.map { |_, name| name }
        param_types = params.map(&:first)
        accepts_kwargs = (param_types & %i[key keyreq keyrest]).any?
        accepts_agent_kwarg = agent && (param_names.include?(:agent) || param_types.include?(:keyrest))

        if accepts_agent_kwarg
          args = args.merge(agent: agent)
        end

        return target.public_send(method_sym) if args.nil? || args.empty?

        if accepts_kwargs
          target.public_send(method_sym, **args)
        elsif (param_types & %i[req opt rest]).any?
          raise ArgumentError,
                "Method '#{method_sym}' takes positional arguments only; " \
                "agent-exposed methods must accept keyword arguments " \
                "(received #{truncated_keys(args)})."
        else
          raise ArgumentError,
                "Method '#{method_sym}' takes no arguments but was called " \
                "with #{truncated_keys(args)}."
        end
      end

      # Compact, bounded preview of arg keys for use in error messages.
      # Caps at 5 keys so a caller cannot use long error messages as an
      # enumeration oracle for which kwargs round-trip through the agent.
      def truncated_keys(args)
        keys = args.keys
        shown = keys.first(5).join(", ")
        keys.size > 5 ? "#{keys.size} keys (#{shown}, ...)" : "keys: #{shown}"
      end

      # Maximum number of fields allowed in an include array.
      MAX_INCLUDE_FIELDS = 20

      # Maximum number of fields allowed in a keys: projection. Same cap
      # as MAX_INCLUDE_FIELDS — a longer list usually means the caller is
      # avoiding `keys:` entirely; that's a different conversation.
      MAX_KEYS_FIELDS = 64

      # Validate a `keys:` projection array before forwarding to Parse
      # Server. Same identifier rules as `validate_include!` — entries
      # must start with a letter and use only `[A-Za-z0-9_.]`, max 128
      # chars. This explicitly refuses leading-underscore names like
      # `_hashed_password`, `_session_token`, `_email_verify_token`,
      # `_perishable_token`, `_rperm`, `_wperm`, and `authData.*`
      # subkey-paths starting with `_`.
      #
      # Closes NEW-TOOLS-5: in master-key deployments (default agent
      # auth), Parse Server returns these internal fields when explicitly
      # requested via `keys:`. The `agent_fields` allowlist intersection
      # catches them on classes that declare an allowlist, but a class
      # WITHOUT an allowlist would forward `_hashed_password` through.
      # Refuse at the parameter-validation boundary so the field never
      # reaches Parse Server in the projection list.
      #
      # @param keys [Array<String, Symbol>, nil] the keys: parameter
      # @return [Array<String>, nil] the original array (stringified) when valid
      # @raise [Parse::Agent::ValidationError] when any rule is violated
      def validate_keys!(keys)
        return nil if keys.nil?

        unless keys.is_a?(Array)
          raise Parse::Agent::ValidationError,
                "keys must be an Array of field-name strings (got: #{keys.class})"
        end

        if keys.size > MAX_KEYS_FIELDS
          raise Parse::Agent::ValidationError,
                "keys array exceeds the #{MAX_KEYS_FIELDS}-field limit " \
                "(#{keys.size} entries provided). Omit keys: to fetch all " \
                "fields, or narrow the projection."
        end

        pattern = /\A[A-Za-z][A-Za-z0-9_.]{0,127}\z/
        keys.map do |entry|
          s = entry.to_s
          unless s.match?(pattern)
            raise Parse::Agent::ValidationError,
                  "keys entry #{entry.inspect} is invalid. Each entry must start with a " \
                  "letter and contain only letters, digits, underscores, and dots " \
                  "(max 128 chars). Underscore-prefixed names (e.g. _hashed_password, " \
                  "_session_token, _rperm) are not permitted."
          end
          # Additional per-segment check for dotted paths: refuse subkeys
          # that begin with an underscore (e.g. "authData._provider").
          # Parse's wire format has the path as path1.path2.path3 — every
          # segment must independently start with a letter.
          if s.include?(".")
            s.split(".").each do |segment|
              next if segment.empty?
              next if /\A[A-Za-z]/.match?(segment)
              raise Parse::Agent::ValidationError,
                    "keys entry #{entry.inspect} has an underscore-prefixed " \
                    "segment (#{segment.inspect}). Each dotted path segment must " \
                    "start with a letter."
            end
          end
          s
        end
      end
      module_function :validate_keys!

      # Validate an include array (pointer fields to resolve) before forwarding
      # to Parse Server.
      #
      # Rules:
      #   1. nil is allowed (means no include requested) — returns nil.
      #   2. Must be an Array.
      #   3. Length must not exceed {MAX_INCLUDE_FIELDS}.
      #   4. Each entry must match /\A[A-Za-z][A-Za-z0-9_.]{0,127}\z/
      #      (allows dotted pointer paths like "author.workspace"; rejects any entry
      #      beginning with an underscore such as "_session_token").
      #
      # @param include [Array<String>, nil] the include parameter to validate.
      # @return [Array<String>, nil] the original array when valid, or nil.
      # @raise [Parse::Agent::ValidationError] when any rule is violated.
      def validate_include!(include)
        return nil if include.nil?

        unless include.is_a?(Array)
          raise Parse::Agent::ValidationError,
                "include must be an Array of field-name strings (got: #{include.class})"
        end

        if include.size > MAX_INCLUDE_FIELDS
          raise Parse::Agent::ValidationError,
                "include array exceeds the #{MAX_INCLUDE_FIELDS}-field limit " \
                "(#{include.size} entries provided)"
        end

        pattern = /\A[A-Za-z][A-Za-z0-9_.]{0,127}\z/
        include.each do |entry|
          unless entry.is_a?(String) && entry.match?(pattern)
            raise Parse::Agent::ValidationError,
                  "include entry #{entry.inspect} is invalid. Each entry must start with a " \
                  "letter and contain only letters, digits, underscores, and dots " \
                  "(max 128 chars). Underscore-prefixed names are not permitted."
          end
        end

        include
      end

      # Validates that a method name is not on the blocked list.
      # Comparison is case-insensitive so e.g. `:Instance_Exec` cannot bypass the
      # denylist on Ruby versions / receivers where casing variations are valid.
      # @param method_name [Symbol, String] the method name to validate.
      # @raise [ArgumentError] if the method is blocked.
      def validate_method_name!(method_name)
        if BLOCKED_METHODS.include?(method_name.to_s.downcase)
          raise ArgumentError, "Method '#{method_name}' is blocked for security reasons"
        end
      end

      # Serialize method results for JSON output.
      #
      # NEW-TOOLS-3: every value flowing out of `call_method` is run
      # through {redact_hidden_classes!} (replaces embedded objects
      # belonging to an `agent_hidden` class with a `__redacted` stub)
      # and projected through the owner class's `agent_fields` allowlist
      # when one is declared. The previous implementation called
      # `ResultFormatter.format_object` and returned the raw attributes
      # — bypassing both gates that every other read path enforces.
      #
      # A custom `agent_method` that returns sensitive data via embedded
      # Parse::Object instances (e.g. a `Project.summary` method that
      # also packs a reference to the assignee `_User`) would otherwise
      # leak fields the conversational `query_class` tool would refuse
      # to return.
      def serialize_result(result, agent: nil)
        formatted = case result
          when Parse::Object
            project_object_to_allowlist(result.parse_class, ResultFormatter.format_object(result.parse_class, result.attributes)[:object])
          when Array
            result.map { |item| serialize_result(item, agent: agent) }
          when Hash
            result.transform_values { |v| serialize_result(v, agent: agent) }
          when NilClass, TrueClass, FalseClass, Numeric, String
            result
          else
            result.to_s
          end
        redact_hidden_classes!(formatted, agent: agent)
      end

      # @api private
      # Project a formatted-object Hash through the class's agent_fields
      # allowlist when one is declared. The allowlist union with
      # ALWAYS_KEEP_FIELDS keeps the standard envelope (objectId,
      # createdAt, updatedAt) on every projection. When no allowlist is
      # declared, return the input untouched.
      def project_object_to_allowlist(class_name, object_hash)
        return object_hash unless object_hash.is_a?(Hash)
        allowlist = Parse::Agent::MetadataRegistry.field_allowlist(class_name)
        return object_hash unless allowlist && allowlist.any?
        # Preserve the className tag and any __type metadata so downstream
        # redactors / formatters can still walk the structure.
        preserved = %w[className __type __redacted]
        allowed = allowlist.map(&:to_s) | preserved
        object_hash.each_with_object({}) do |(k, v), acc|
          ks = k.to_s
          acc[k] = v if allowed.include?(ks)
        end
      end
      module_function :project_object_to_allowlist

      # Stamp each row hash with an SDK-added `_source` provenance
      # citation `{ "class", "tool", "object_id" }`. No-op unless
      # `Parse::Agent.include_source_provenance?`. MUST be called AFTER
      # field-allowlist projection and hidden-class redaction: `_source`
      # is SDK metadata, not a Parse field, so stamping last keeps it out
      # of (and safe from) those gates. Idempotent — a row already
      # carrying `_source` is left untouched. `object_id` is nil-safe
      # (aggregation/group rows have no objectId).
      #
      # @param rows [Array<Hash>] row hashes (mutated in place).
      # @param class_name [String]
      # @param tool [Symbol, String]
      # @param id_key [String] the row key holding the objectId.
      # @return [Array<Hash>] the same rows.
      def stamp_source!(rows, class_name:, tool:, id_key: "objectId")
        return rows unless Parse::Agent.include_source_provenance?
        return rows unless rows.is_a?(Array)
        rows.each do |row|
          next unless row.is_a?(Hash)
          next if row.key?("_source") || row.key?(:_source)
          oid = row[id_key] || row[id_key.to_sym]
          row["_source"] = {
            "class"     => class_name.to_s,
            "tool"      => tool.to_s,
            "object_id" => oid,
          }
        end
        rows
      end
      module_function :stamp_source!

      # ============================================================
      # ATLAS SEARCH TOOLS
      # ============================================================
      #
      # The three Atlas Search tools — atlas_text_search,
      # atlas_autocomplete, atlas_faceted_search — wrap
      # {Parse::AtlasSearch}. Common gating:
      #
      #   * +assert_class_accessible!+ enforces the global
      #     +agent_hidden+ + per-agent +classes:+ allowlist before any
      #     search is issued.
      #   * +atlas_auth_options!+ refuses unless the agent carries a
      #     +session_token+ OR was constructed with +master_atlas: true+.
      #     Atlas Search bypasses Parse Server entirely, so the agent
      #     must declare its ACL posture; reusing the implicit
      #     master-key signal from a session-less agent would
      #     silently grant Atlas-bypass authority.
      #   * +agent_fields+ allowlist is intersected with the caller's
      #     +fields:+ / +highlight_field:+ / facet paths at the
      #     boundary, and applied again to the returned documents and
      #     highlight payloads so a field indexed for search but
      #     redacted by +agent_fields+ never reaches the wire.

      # The Tools module declares `private` at the top of its helper
      # section (above), so module-level methods defined past that
      # point are private instance methods by default. Each Atlas
      # Search entry point is re-exposed as a module function below
      # so the dispatcher (`Tools.atlas_text_search(...)` etc.) and
      # the test suite can call it directly.
      def atlas_text_search(agent, class_name:, query:, fields: nil, limit: nil,
                                   highlight_field: nil, filter: nil,
                                   apply_canonical_filter: true, **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :find)
        unless query.is_a?(String) && !query.strip.empty?
          raise Parse::Agent::ValidationError, "query must be a non-empty string"
        end
        if highlight_field
          assert_atlas_field_allowed!(class_name, highlight_field, kind: :highlight_field)
        end
        limit = clamp_atlas_limit(limit)
        auth = atlas_auth_options!(agent, tool: :atlas_text_search)
        fields_norm = normalize_atlas_fields_with_allowlist!(class_name, fields)

        # TRACK-AGENT-6 / TRACK-AGENT-7 fix: per-agent filter is
        # UNCONDITIONAL; canonical filter is LLM-controllable via
        # apply_canonical_filter:. Both compose into the existing
        # `filter:` channel that Parse::AtlasSearch.search emits as
        # a post-$search $match stage (AFTER the ACL $match). The
        # caller's filter, when supplied, AND-merges so neither
        # half can shadow the other.
        effective_filter = compose_atlas_filter(
          filter, class_name, agent: agent,
          apply_canonical_filter: apply_canonical_filter,
        )

        opts = { limit: limit }.merge(auth)
        opts[:fields] = fields_norm if fields_norm
        opts[:filter] = effective_filter if effective_filter
        opts[:highlight_field] = highlight_field if highlight_field

        with_timeout(:atlas_text_search) do
          result = invoke_atlas_search(:search, class_name, query, opts)
          format_atlas_text_search_results(class_name, result, highlight_field: highlight_field)
        end
      end

      # @api private
      def atlas_autocomplete(agent, class_name:, query:, field:, limit: nil, fuzzy: nil,
                             apply_canonical_filter: true, **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :find)
        unless query.is_a?(String) && !query.strip.empty?
          raise Parse::Agent::ValidationError, "query must be a non-empty string"
        end
        unless field.is_a?(String) || field.is_a?(Symbol)
          raise Parse::Agent::ValidationError, "field must be a String or Symbol"
        end
        assert_atlas_field_allowed!(class_name, field, kind: :field)
        limit = clamp_atlas_limit(limit)
        auth = atlas_auth_options!(agent, tool: :atlas_autocomplete)

        # TRACK-AGENT-6 / TRACK-AGENT-7 fix: weave per-agent (UNCONDITIONAL)
        # and canonical (LLM-controllable) filters into the existing
        # `filter:` channel — Parse::AtlasSearch.autocomplete emits it as
        # a $match stage AFTER the ACL $match (see atlas_search.rb:385-388).
        effective_filter = compose_atlas_filter(
          nil, class_name, agent: agent,
          apply_canonical_filter: apply_canonical_filter,
        )

        opts = { limit: limit }.merge(auth)
        opts[:fuzzy] = fuzzy if fuzzy
        opts[:filter] = effective_filter if effective_filter

        with_timeout(:atlas_autocomplete) do
          result = invoke_atlas_search(:autocomplete, class_name, query, opts, field: field.to_s)
          format_atlas_autocomplete_results(class_name, field.to_s, result)
        end
      end

      # @api private
      def atlas_faceted_search(agent, class_name:, facets:, query: "", limit: nil,
                               apply_canonical_filter: true, **_kwargs)
        assert_class_accessible!(class_name, agent: agent, op: :find)
        # Faceted Atlas Search cannot ACL-filter $searchMeta bucket
        # counts (see Parse::AtlasSearch::FacetedSearchNotACLSafe), so
        # this tool requires the explicit master_atlas: true opt-in
        # even when the agent has a session token. A session-bound
        # agent that legitimately needs facets should fall back to
        # multiple atlas_text_search calls with explicit filters.
        unless agent.respond_to?(:master_atlas?) && agent.master_atlas?
          raise Parse::Agent::ValidationError,
                "Tool 'atlas_faceted_search' requires the agent to be constructed " \
                "with master_atlas: true. $searchMeta bucket counts cannot enforce " \
                "per-row ACL; this tool refuses session-scoped calls so per-user " \
                "bucket leakage is impossible."
        end

        # TRACK-AGENT-6 / TRACK-AGENT-7 fix: $searchMeta bucket counts
        # cannot be filtered through a post-search $match because the
        # documents are not in the output stream — the SAME structural
        # constraint that makes session-token ACL unsafe also makes the
        # per-agent / canonical filter unsafe for buckets. Fail-closed:
        # refuse the call entirely when either filter is declared on
        # the class AND the LLM has not opted out of the canonical
        # filter. Bucket counts would otherwise leak hidden / archived
        # rows that every other read tool excludes.
        per_agent = agent && agent.respond_to?(:filter_for) ? agent.filter_for(class_name) : nil
        canonical = Parse::Agent::MetadataRegistry.canonical_filter(class_name)
        active_filters = []
        active_filters << "per-agent filter (filters: kwarg)" if per_agent && !per_agent.empty?
        active_filters << "canonical filter (agent_canonical_filter)" if apply_canonical_filter && canonical && !canonical.empty?
        unless active_filters.empty?
          raise Parse::Agent::AccessDenied.new(
            class_name,
            "atlas_faceted_search cannot enforce #{active_filters.join(' / ')} on " \
            "$searchMeta bucket counts (the matched documents are not in the output " \
            "stream). Use atlas_text_search (which applies these filters via $match) " \
            "or pass apply_canonical_filter: false (and arrange your agent without a " \
            "per-class filter for #{class_name}) to acknowledge the bucket-count leak risk.",
            kind: :atlas_facet_filter_unsafe,
          )
        end

        unless facets.is_a?(Hash) && !facets.empty?
          raise Parse::Agent::ValidationError, "facets must be a non-empty Hash"
        end
        normalize_atlas_facet_paths!(class_name, facets)
        limit = clamp_atlas_limit(limit)

        with_timeout(:atlas_faceted_search) do
          # faceted_search refuses session_token: outright (see
          # Parse::AtlasSearch::FacetedSearchNotACLSafe); pass master:
          # true unconditionally here, since the agent-level gate
          # above already enforced master_atlas?.
          result = Parse::AtlasSearch.faceted_search(
            class_name, query.to_s, facets,
            limit: limit, master: true,
          )
          format_atlas_faceted_results(class_name, result)
        end
      end

      # @api private
      # Build the auth-options hash forwarded to Parse::AtlasSearch.
      # Reads the agent's resolved ACL scope (see {Parse::Agent#acl_scope_kwargs}):
      #
      #   * session_token / acl_user / acl_role scope → SDK injects a
      #     `_rperm` `$match` after the `$search` stage so per-row ACL
      #     is enforced uniformly across all three scope modes.
      #   * master-key posture → forwarded as `master: true`; per-row
      #     ACL enforcement is skipped. This is the intentional
      #     consequence of master-key agent construction, signaled at
      #     construction with the master-key banner.
      #
      # The previous per-tool "must be session_token or master_atlas"
      # refusal was redundant once the SDK started enforcing ACL on
      # every scope mode. The `tool:` kwarg is kept for backwards
      # compatibility with the helper signature (tests may pass it);
      # it's no longer used in the body.
      def atlas_auth_options!(agent, tool: nil)
        agent.acl_scope_kwargs
      end

      # @api private
      def clamp_atlas_limit(limit)
        return ATLAS_LIMIT_DEFAULT if limit.nil?
        n = limit.to_i
        return ATLAS_LIMIT_DEFAULT if n <= 0
        [n, ATLAS_LIMIT_MAX].min
      end

      # @api private
      # Build the auth kwargs hash forwarded to {Parse::MongoDB.aggregate}
      # from the {.aggregate} tool's mongo_direct branch. Mirrors
      # {.atlas_auth_options!} but with a friendlier default for the
      # aggregate path: when the agent has no `session_token`, fall back
      # to `master: true` rather than refusing the call. The agent's
      # existing class/field/tenant/canonical-filter gates already form
      # the security boundary for the aggregate tool, so a session-less
      # agent should run with master-equivalent semantics (preserving
      # pre-4.4.0 behavior). Atlas Search refuses session-less calls
      # because it was a new attack surface; aggregate has been around
      # longer and its enforcement model is class-based, not row-based.
      #
      # Session-tokened agents get a real upgrade here: pre-4.4.0,
      # `Parse::MongoDB.aggregate` ignored session tokens and ran with
      # admin Mongo credentials, so row-ACL was unenforced on the
      # mongo-direct path. With this helper, a session-tokened agent's
      # mongo-direct aggregate gets the same ACLScope `_rperm`
      # enforcement the REST route gets via Parse Server.
      #
      # LLM-supplied kwargs are NOT honored here — the calling tool
      # signature swallows unknown kwargs into `**_kwargs` and the
      # call site at line 2562 does not splat them. The posture comes
      # entirely from agent instance state.
      # @api private
      # Auto-route a REST find_objects-style call through
      # Parse::MongoDB.aggregate when the agent's scope is acl_user /
      # acl_role (no REST "act as role" surface exists). For
      # session_token / master-key agents the caller keeps the existing
      # REST path — Parse Server's REST find_objects honors session_token
      # natively. Returns an Array of Parse-format Hashes shaped like
      # `response.results`, so callers can plug it in as a drop-in
      # replacement.
      #
      # The pipeline composition reuses Parse::Query's
      # {#build_direct_mongodb_pipeline} for sort / include $lookup /
      # keys $project / skip / limit, then prepends the caller's raw
      # where: as a translated `$match` stage (field references and
      # pointer values rewritten via {#convert_stage_for_direct_mongodb}).
      # ACLScope's `_rperm` injection runs inside Parse::MongoDB.aggregate.
      #
      # @param agent [Parse::Agent]
      # @param class_name [String]
      # @param where [Hash, nil] wire-format constraints (already passed
      #   through {ConstraintTranslator.translate} — i.e. MongoDB-shaped
      #   keys like `$gt` / `$or`, but Parse-shaped pointer values).
      # @param limit [Integer, nil]
      # @param skip [Integer, nil]
      # @param order [String, nil] Parse-style "field" or "-field" form.
      # @param keys [Array<String>, nil] projection allowlist.
      # @param include [Array<String>, nil] pointer paths to $lookup.
      # @return [Array<Hash>]
      def execute_find_via_direct(agent, class_name, where: nil, limit: nil,
                                  skip: 0, order: nil, keys: nil, include: nil)
        q = Parse::Query.new(class_name)
        q.limit(limit) if limit && limit > 0
        q.skip(skip) if skip && skip > 0
        # `order:` arrives as a single Parse-style string ("createdAt" or
        # "-createdAt") from query_class; Parse::Query#order accepts it
        # via the Order coercion path.
        if order
          if order.is_a?(String)
            # split comma-separated forms — query_class accepts a single
            # string today but Parse Server's order parameter accepts
            # multiple comma-separated keys.
            order.split(",").each { |o| q.order(o.strip) unless o.strip.empty? }
          else
            q.order(order)
          end
        end
        q.keys(*keys) if keys && keys.any?
        q.includes(*include) if include && include.any?

        pipeline = q.send(:build_direct_mongodb_pipeline)

        # Prepend the caller's where: as a $match stage. The translator
        # rewrites pointer-shaped values (`{__type: Pointer, ...}` →
        # `"ClassName$objectId"`), pointer field references (`author` →
        # `_p_author`), and date / file shapes for direct-MongoDB
        # storage form. Without this, the wire-format where would miss
        # rows that the REST find_objects path matches.
        if where.is_a?(Hash) && !where.empty?
          translated_match = q.send(:convert_stage_for_direct_mongodb, { "$match" => where })
          pipeline = [translated_match] + pipeline
        end

        raw_rows = Parse::MongoDB.aggregate(class_name, pipeline, **agent.acl_scope_kwargs)
        raw_rows.map { |raw| Parse::MongoDB.convert_aggregation_document(raw) }
      end
      module_function :execute_find_via_direct

      # @api private
      # Count variant of {#execute_find_via_direct}. Routes through
      # Parse::MongoDB.aggregate with a terminal $count stage. Returns
      # an Integer (the count), mirroring what Parse Server REST
      # find_objects with `count: 1` would surface as `response.count`.
      def execute_count_via_direct(agent, class_name, where: nil)
        pipeline = []
        if where.is_a?(Hash) && !where.empty?
          translated_match = Parse::Query.new(class_name).send(
            :convert_stage_for_direct_mongodb, { "$match" => where },
          )
          pipeline << translated_match
        end
        pipeline << { "$count" => "count" }
        raw_rows = Parse::MongoDB.aggregate(class_name, pipeline, **agent.acl_scope_kwargs)
        return 0 if raw_rows.empty?
        raw_rows.first["count"] || 0
      end
      module_function :execute_count_via_direct

      def mongo_direct_auth_kwargs(agent)
        # Single point of truth: delegate to agent.acl_scope_kwargs.
        # The agent emits exactly one of {session_token:}, {acl_user:},
        # {acl_role:}, or {master: true} based on construction. The old
        # session_token-or-master pairing is preserved as the
        # session_token / master-key endpoints of this set; new
        # acl_user/acl_role scopes also flow through correctly so
        # ACLScope's `_rperm` $match runs on direct mongo aggregations
        # regardless of which identity input the agent was constructed
        # with.
        agent.acl_scope_kwargs
      end

      # @api private
      # Coerce +fields+ to an array of strings and intersect with the
      # class's +agent_fields+ allowlist. Raises {AccessDenied} when
      # the caller named a field outside the allowlist — refuse, not
      # silently strip, so the LLM gets a clear error rather than an
      # empty result it might retry forever.
      def normalize_atlas_fields_with_allowlist!(class_name, fields)
        return nil if fields.nil?
        arr = Array(fields).map(&:to_s).reject(&:empty?)
        return nil if arr.empty?

        allowlist = Parse::Agent::MetadataRegistry.field_allowlist(class_name)
        if allowlist && allowlist.any?
          permitted = allowlist.map(&:to_s)
          rejected = arr - permitted
          unless rejected.empty?
            raise Parse::Agent::AccessDenied.new(
              class_name,
              "Atlas Search field(s) #{rejected.inspect} outside agent_fields allowlist for class '#{class_name}'.",
              kind: :field_denied,
              denied_field: rejected.first,
              allowed_fields: permitted,
            )
          end
        end
        arr
      end

      # @api private
      # Compose an Atlas Search filter hash that combines the caller's
      # `filter:` (if any) with the per-agent and (optionally) canonical
      # filters declared for the class. Returns nil when no filters
      # apply (so the underlying invoke_atlas_search drops the
      # `filter:` opt entirely instead of emitting an empty $match).
      #
      # TRACK-AGENT-6 / TRACK-AGENT-7 — the per-agent filter
      # (operator scoping) is UNCONDITIONAL; the canonical filter
      # (per-class) is gated on `apply_canonical_filter:`. Caller-
      # supplied `filter:` is preserved; all three are AND-merged so
      # neither half can shadow the other.
      def compose_atlas_filter(caller_filter, class_name, agent:, apply_canonical_filter: true)
        per_agent = agent && agent.respond_to?(:filter_for) ? agent.filter_for(class_name) : nil
        canonical = apply_canonical_filter ?
                      Parse::Agent::MetadataRegistry.canonical_filter(class_name) :
                      nil

        parts = []
        parts << per_agent.dup if per_agent && !per_agent.empty?
        parts << canonical.dup if canonical && !canonical.empty?
        parts << caller_filter if caller_filter.is_a?(Hash) && !caller_filter.empty?

        case parts.size
        when 0 then nil
        when 1 then parts.first
        else        { "$and" => parts }
        end
      end
      module_function :compose_atlas_filter

      # @api private
      def assert_atlas_field_allowed!(class_name, field_name, kind:)
        name = field_name.to_s
        allowlist = Parse::Agent::MetadataRegistry.field_allowlist(class_name)
        return if allowlist.nil? || allowlist.empty?
        permitted = allowlist.map(&:to_s)
        return if permitted.include?(name)
        raise Parse::Agent::AccessDenied.new(
          class_name,
          "Atlas Search #{kind} #{name.inspect} outside agent_fields allowlist for class '#{class_name}'.",
          kind: :field_denied,
          denied_field: name,
          allowed_fields: permitted,
        )
      end

      # @api private
      # Validate that every facet's +path:+ entry is in the class's
      # +agent_fields+ allowlist. Mutates +facets+ in place by
      # ensuring each value is a Hash with a string +path+ (the form
      # Parse::AtlasSearch expects).
      def normalize_atlas_facet_paths!(class_name, facets)
        allowlist = Parse::Agent::MetadataRegistry.field_allowlist(class_name)
        permitted = allowlist ? allowlist.map(&:to_s) : nil

        facets.each do |name, config|
          unless config.is_a?(Hash)
            raise Parse::Agent::ValidationError,
                  "facet #{name.inspect}: definition must be a Hash, got #{config.class}"
          end
          path = config[:path] || config["path"]
          unless path.is_a?(String) || path.is_a?(Symbol)
            raise Parse::Agent::ValidationError,
                  "facet #{name.inspect}: path: must be a String or Symbol"
          end
          path_str = path.to_s
          if permitted && !permitted.include?(path_str)
            raise Parse::Agent::AccessDenied.new(
              class_name,
              "Facet path #{path_str.inspect} outside agent_fields allowlist for class '#{class_name}'.",
              kind: :field_denied,
              denied_field: path_str,
              allowed_fields: permitted,
            )
          end
        end
      end

      # @api private
      # Thin wrapper that invokes the right Parse::AtlasSearch method
      # and translates ACLRequired / FacetedSearchNotACLSafe / NotAvailable
      # into Parse::Agent::ValidationError so the agent's execute()
      # rescue handler renders them cleanly. The library-level errors
      # carry implementation details (toggle names, internal stage
      # ordering) that aren't useful in an LLM tool-call response.
      def invoke_atlas_search(op, class_name, query, opts, **extra)
        case op
        when :search
          Parse::AtlasSearch.search(class_name, query, **opts)
        when :autocomplete
          Parse::AtlasSearch.autocomplete(class_name, query, field: extra.fetch(:field), **opts)
        else
          raise ArgumentError, "unknown atlas op #{op.inspect}"
        end
      rescue Parse::AtlasSearch::NotAvailable => e
        raise Parse::Agent::ValidationError, "Atlas Search is not configured on this deployment: #{e.message}"
      rescue Parse::AtlasSearch::IndexNotFound => e
        raise Parse::Agent::ValidationError, "Atlas Search index not found: #{e.message}"
      rescue Parse::AtlasSearch::ACLRequired => e
        raise Parse::Agent::ValidationError, "Atlas Search ACL gate refused the call: #{e.message}"
      rescue Parse::AtlasSearch::InvalidSearchParameters => e
        raise Parse::Agent::ValidationError, "Atlas Search invalid parameters: #{e.message}"
      end

      # @api private
      def format_atlas_text_search_results(class_name, result, highlight_field: nil)
        allowlist = Parse::Agent::MetadataRegistry.field_allowlist(class_name)
        permitted = allowlist && allowlist.any? ? (allowlist.map(&:to_s) | Parse::Agent::MetadataRegistry::ALWAYS_KEEP_FIELDS) : nil

        rows = result.results.map do |obj|
          row = serialize_atlas_object(obj)
          row = row.select { |k, _| permitted.include?(k.to_s) } if permitted
          # Normalize to query_class's LLM-friendly form (compact pointers,
          # ISO dates, ACL stripped) instead of raw wire-form. Done before
          # the SDK-added score/highlights so those stay verbatim.
          row = ResultFormatter.simplify_object(row)
          row["score"] = obj.search_score if obj.respond_to?(:search_score) && obj.search_score
          if highlight_field && obj.respond_to?(:search_highlights) && obj.search_highlights
            highlights = filter_atlas_highlights(obj.search_highlights, permitted)
            row["highlights"] = highlights unless highlights.nil? || highlights.empty?
          end
          row
        end
        stamp_source!(rows, class_name: class_name, tool: :atlas_text_search)

        {
          class_name: class_name,
          count: rows.length,
          results: rows,
        }
      end

      # @api private
      def format_atlas_autocomplete_results(class_name, field, result)
        allowlist = Parse::Agent::MetadataRegistry.field_allowlist(class_name)
        permitted = allowlist && allowlist.any? ? (allowlist.map(&:to_s) | Parse::Agent::MetadataRegistry::ALWAYS_KEEP_FIELDS) : nil

        rows = (result.results || []).map do |obj|
          row = serialize_atlas_object(obj)
          row = row.select { |k, _| permitted.include?(k.to_s) } if permitted
          ResultFormatter.simplify_object(row)
        end

        {
          class_name: class_name,
          field: field,
          suggestions: result.suggestions,
          count: rows.length,
          results: rows,
        }
      end

      # @api private
      def format_atlas_faceted_results(class_name, result)
        allowlist = Parse::Agent::MetadataRegistry.field_allowlist(class_name)
        permitted = allowlist && allowlist.any? ? (allowlist.map(&:to_s) | Parse::Agent::MetadataRegistry::ALWAYS_KEEP_FIELDS) : nil

        rows = (result.results || []).map do |obj|
          row = serialize_atlas_object(obj)
          row = row.select { |k, _| permitted.include?(k.to_s) } if permitted
          ResultFormatter.simplify_object(row)
        end

        {
          class_name: class_name,
          total_count: result.total_count,
          facets: result.facets,
          count: rows.length,
          results: rows,
        }
      end

      # @api private
      # Serialize a Parse::Object (or raw Hash) into the wire-format
      # hash used by other tool envelopes. Falls through to +as_json+
      # for Parse objects and returns the input hash for raw-mode
      # results.
      def serialize_atlas_object(obj)
        if obj.is_a?(Hash)
          obj.dup
        elsif obj.respond_to?(:as_json)
          json = obj.as_json
          json.is_a?(Hash) ? json : { "value" => json }
        else
          { "value" => obj.to_s }
        end
      end

      # @api private
      # Drop highlight entries whose +path+ is not in the
      # +agent_fields+ allowlist. Highlight snippets carry verbatim
      # field content; without this filter, a field redacted from
      # the row would still leak through its highlight passage.
      def filter_atlas_highlights(highlights, permitted_fields)
        return highlights if permitted_fields.nil?
        return [] unless highlights.respond_to?(:select)
        highlights.select do |h|
          path = h.is_a?(Hash) ? (h["path"] || h[:path]) : nil
          path && permitted_fields.include?(path.to_s)
        end
      end

      # Re-expose the three Atlas Search tool entry points as module
      # functions so `Parse::Agent::Tools.atlas_text_search(...)` etc.
      # are callable from the dispatcher. The helper methods stay
      # private because they take an instance-method-shaped contract
      # (sharing `self` with other Tools instance methods) that
      # callers should not depend on.
      module_function :atlas_text_search
      module_function :atlas_autocomplete
      module_function :atlas_faceted_search
    end
  end
end
