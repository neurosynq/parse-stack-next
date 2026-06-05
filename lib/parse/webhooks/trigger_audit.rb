# encoding: UTF-8
# frozen_string_literal: true

require "active_support/inflector"

module Parse
  class Webhooks
    # Operator-facing audit that cross-references three sources of truth about a
    # Parse application's trigger logic and reports where they disagree:
    #
    #   1. **Model callbacks** — the ActiveModel `before_save` / `after_save` /
    #      `after_create` / ... callbacks declared on each {Parse::Object}
    #      subclass (app-defined ones, with framework-internal callbacks filtered
    #      out by source location).
    #   2. **Local webhook routes** — the blocks registered via
    #      `webhook :before_save { ... }` / `Parse::Webhooks.route(...)`, held in
    #      {Parse::Webhooks.routes}.
    #   3. **Server triggers** — what is actually registered with Parse Server
    #      (`GET hooks/triggers`), so a matching client POST reaches your Rack app.
    #
    # The non-obvious relationship the audit exists to surface (see
    # {file:docs/webhooks_guide.md}): a model's ActiveModel callbacks only run
    # server-side for **non-Ruby clients** when BOTH a local route is registered
    # (so the webhook router has a handler) AND the trigger is registered on Parse
    # Server (so it POSTs at all). Declaring `after_save :send_email` alone does
    # nothing for a JS/Swift/REST/Dashboard write — that write never touches your
    # Ruby process, and the callback is silently skipped.
    #
    # SECURITY POSTURE — mirrors {Parse::Core::Describe}. This is operator-side
    # observability, NOT data exposed to an LLM. The server fetch hits the
    # master-key-only `hooks/triggers` endpoint, so a `network: true` audit
    # requires a master-key client; `network: false` audits callbacks vs. local
    # routes only and needs no credentials. Output is never included in tool
    # responses or any `parse.agent.*` notification payload.
    #
    # @example
    #   audit = Parse::Webhooks.trigger_audit            # Hash report (network)
    #   puts Parse::Webhooks.trigger_audit(pretty: true) # human-readable summary
    #   Parse::Webhooks.trigger_audit(network: false)    # local-only, no master key
    class TriggerAudit
      # The object-shaped triggers an ActiveModel callback or a webhook block can
      # map to. (Auth / LiveQuery triggers carry no object and have no ActiveModel
      # callback equivalent, so they are surfaced only as server/local routes, not
      # cross-referenced against model callbacks.)
      OBJECT_TRIGGERS = %i[
        before_save after_save before_delete after_delete before_find after_find
      ].freeze

      # Maps an ActiveModel callback chain + phase to the local trigger name whose
      # webhook handler runs it server-side. `before_create` / `after_create` ride
      # inside the save handler (Parse Server has no create trigger); the webhook
      # router runs the destroy chain inside the beforeDelete handler.
      CALLBACK_TRIGGER_MAP = {
        [:save,    :before] => :before_save,
        [:create,  :before] => :before_save,
        [:save,    :after]  => :after_save,
        [:create,  :after]  => :after_save,
        [:destroy, :before] => :before_delete,
        [:destroy, :after]  => :after_delete,
      }.freeze

      # ActiveModel callback chains + phases with NO server trigger that can run
      # them. The webhook router only runs the `:save` and `:create` chains (plus
      # the destroy chain on beforeDelete) — it never runs `:update` or
      # `:validation`. So these callbacks are LOCAL-ONLY: they fire for
      # Ruby-initiated saves but can never fire for a non-Ruby client, and no
      # trigger registration changes that. Surfaced as an informational note, not
      # a fixable gap.
      LOCAL_ONLY_MAP = {
        [:update,     :before] => :before_update,
        [:update,     :after]  => :after_update,
        [:validation, :before] => :before_validation,
        [:validation, :after]  => :after_validation,
      }.freeze

      # The ActiveModel callback chains we introspect.
      CALLBACK_CHAINS = %i[validation create update save destroy].freeze

      # Directory under which a callback's source file marks it as
      # framework-internal (defined by the gem) rather than app-defined. Computed
      # from this file's own location: `__dir__` is `<gem>/lib/parse/webhooks`, so
      # its parent is `<gem>/lib/parse`.
      GEM_PARSE_DIR = ::File.expand_path("..", __dir__)

      # Per-class audit row.
      class ClassAudit
        # @return [String] the Parse class name (e.g. "Post", "_User", "*").
        attr_reader :parse_class
        # @return [Hash{Symbol=>Array<Hash>}] app-defined callbacks keyed by local
        #   trigger-ish name (`:before_save`, `:after_create`, ...). Each value is
        #   an array of `{ name:, source: }`.
        attr_reader :callbacks
        # @return [Array<Symbol>] local trigger names that have a registered
        #   webhook block/route for this class (or via the `*` wildcard route).
        attr_reader :local_routes
        # @return [Hash{Symbol=>String}] server-registered triggers for this class,
        #   mapped trigger-name => url. Empty when `network: false`.
        attr_reader :server_triggers
        # @return [Array<Hash>] findings for this class. See {TriggerAudit} for the
        #   finding kinds.
        attr_reader :findings
        # @return [Boolean] whether a loaded Parse::Object subclass models this class.
        attr_reader :modeled

        def initialize(parse_class:, callbacks:, local_routes:, server_triggers:,
                       findings:, modeled:)
          @parse_class     = parse_class
          @callbacks       = callbacks
          @local_routes    = local_routes
          @server_triggers = server_triggers
          @findings        = findings
          @modeled         = modeled
        end

        # @return [Boolean] true when the class has at least one finding.
        def issues?
          @findings.any?
        end

        # @return [Hash] a JSON-safe representation of this row.
        def to_h
          {
            parse_class:     parse_class,
            modeled:         modeled,
            callbacks:       callbacks,
            local_routes:    local_routes,
            server_triggers: server_triggers,
            findings:        findings,
          }
        end
      end

      # @return [Array<ClassAudit>] one row per audited class, sorted by name.
      attr_reader :classes
      # @return [Boolean] whether the server was queried for registered triggers.
      attr_reader :networked

      # @param network [Boolean] when true, query Parse Server for registered
      #   triggers (requires a master-key client). When false, audit model
      #   callbacks against local routes only.
      # @param client [Parse::Client, nil] optional client override for the server
      #   fetch.
      # @param include_framework [Boolean] when true, also report gem-internal
      #   callbacks (e.g. the `_User` default-ACL callback). Off by default to keep
      #   the report focused on app-defined logic.
      def initialize(network: true, client: nil, include_framework: false)
        @networked         = network
        @include_framework = include_framework
        @client            = client
        @server_lookup     = network ? fetch_server_triggers : {}
        @classes           = build_classes
      end

      # @return [Array<Hash>] every finding across all classes, flattened, with the
      #   class name folded into each entry. Convenient for programmatic checks
      #   (CI fails the build if `gaps.any? { |g| g[:kind] == :callbacks_inert }`).
      def gaps
        @classes.flat_map do |ca|
          ca.findings.map { |f| f.merge(parse_class: ca.parse_class) }
        end
      end

      # @return [Hash] the full JSON-safe report.
      def to_h
        {
          networked: networked,
          classes:   @classes.map(&:to_h),
          summary:   summary,
        }
      end
      alias as_json to_h

      # @return [Hash] finding counts keyed by kind, plus class totals.
      def summary
        counts = Hash.new(0)
        gaps.each { |g| counts[g[:kind]] += 1 }
        {
          classes_audited:    @classes.size,
          classes_with_issues: @classes.count(&:issues?),
          findings:           counts,
        }
      end

      # @return [String] a human-readable, `puts`-friendly summary in the style of
      #   `Model.describe(pretty: true)`.
      def pretty
        lines = ["Parse trigger audit (#{networked ? "server-compared" : "local-only"}):"]
        @classes.each do |ca|
          header = "  #{ca.parse_class}"
          header += " [server-only]" unless ca.modeled
          lines << header

          ca.callbacks.each do |trigger, cbs|
            names = cbs.map { |c| c[:name] }.join(", ")
            lines << "    callback #{trigger}: #{names}"
          end
          lines << "    routes:  #{ca.local_routes.map(&:to_s).sort.join(", ")}" if ca.local_routes.any?
          if networked && ca.server_triggers.any?
            lines << "    server:  #{ca.server_triggers.keys.map(&:to_s).sort.join(", ")}"
          end

          if ca.findings.empty?
            lines << "    ok"
          else
            ca.findings.each { |f| lines << "    #{finding_glyph(f[:kind])} #{f[:message]}" }
          end
        end
        s = summary
        lines << ""
        lines << "Summary: #{s[:classes_audited]} class(es), " \
                 "#{s[:classes_with_issues]} with issues."
        s[:findings].sort.each { |kind, n| lines << "  #{kind}: #{n}" }
        lines.join("\n")
      end
      alias to_s pretty

      private

      # Pull `hooks/triggers` and build server[className][local_trigger] => url.
      # Raises a clear error (rather than letting the bare REST 403 surface) when
      # no master key is configured — the endpoint is master-key-only.
      def fetch_server_triggers
        client = @client || Parse::Webhooks.client
        if client.respond_to?(:master_key) && client.master_key.blank?
          raise ArgumentError,
                "Parse::Webhooks.trigger_audit requires a master-key client to " \
                "read server triggers (the hooks/triggers endpoint is " \
                "master-key-only). Configure a master key, or pass network: false " \
                "to audit model callbacks against local routes only."
        end
        lookup = Hash.new { |h, k| h[k] = {} }
        client.triggers.results.each do |t|
          next unless t["url"].present?
          name  = t["triggerName"]
          klass = t[Parse::Model::KEY_CLASS_NAME] || t["className"]
          next if name.blank? || klass.blank?
          lookup[klass.to_s][name.to_s.underscore.to_sym] = t["url"]
        end
        lookup
      end

      # The union of every class that any of the three sources knows about, so a
      # server-only trigger (no local model) or a `*` wildcard route still appears.
      def build_classes
        names = Set.new
        Parse.registered_classes.each { |c| names << c.to_s }
        @server_lookup.each_key { |c| names << c.to_s }
        OBJECT_TRIGGERS.each do |trigger|
          route_map = Parse::Webhooks.routes[trigger]
          next if route_map.nil?
          route_map.each_key { |c| names << c.to_s }
        end
        # All trigger chains, in case a non-object trigger (function aside) is
        # registered against a class name.
        Parse::API::Hooks::TRIGGER_NAMES_LOCAL.each do |trigger|
          route_map = Parse::Webhooks.routes[trigger]
          next if route_map.nil?
          route_map.each_key { |c| names << c.to_s }
        end

        names.to_a.sort.map { |name| audit_class(name) }
      end

      def audit_class(name)
        klass     = name == "*" ? nil : (Parse::Model.find_class(name) rescue nil)
        callbacks = klass ? collect_callbacks(klass) : {}
        routes    = collect_local_routes(name)
        server    = @server_lookup[name] || {}
        findings  = analyze(name, callbacks, routes, server)
        ClassAudit.new(
          parse_class:     name,
          callbacks:       callbacks,
          local_routes:    routes,
          server_triggers: server,
          findings:        findings,
          modeled:         !klass.nil?,
        )
      end

      # App-defined ActiveModel callbacks keyed by a trigger-ish name
      # (`:before_save`, `:after_create`, `:before_update`, ...). Framework
      # callbacks are filtered by source location unless include_framework is set.
      def collect_callbacks(klass)
        out = {}
        CALLBACK_CHAINS.each do |chain|
          callback_chain = klass.send("_#{chain}_callbacks")
          callback_chain.each do |cb|
            next unless cb.kind == :before || cb.kind == :after
            entry = describe_callback(klass, cb)
            next if entry[:framework] && !@include_framework
            key = :"#{cb.kind}_#{chain}"
            (out[key] ||= []) << entry.slice(:name, :source).merge(framework: entry[:framework])
          end
        end
        # Drop the framework flag from values when not requested (keeps output lean).
        unless @include_framework
          out.each_value { |arr| arr.each { |h| h.delete(:framework) } }
        end
        out
      end

      # Resolve a callback's display name, source location, and whether it is
      # framework-internal (defined under the gem's lib/parse).
      def describe_callback(klass, cb)
        filter = cb.filter
        case filter
        when Symbol
          loc = begin
              klass.instance_method(filter).source_location
            rescue NameError
              nil
            end
          { name: filter.to_s, source: format_source(loc), framework: framework_source?(loc) }
        when Proc
          loc = filter.source_location
          { name: "(block)", source: format_source(loc), framework: framework_source?(loc) }
        else # String (eval'd) — uncommon
          { name: "(string)", source: nil, framework: false }
        end
      end

      def framework_source?(loc)
        return false if loc.nil?
        ::File.expand_path(loc.first.to_s).start_with?(GEM_PARSE_DIR + ::File::SEPARATOR)
      end

      def format_source(loc)
        return nil if loc.nil?
        "#{loc.first}:#{loc.last}"
      end

      # Local trigger names with a registered block for this class. The `*`
      # wildcard route applies to every class, so a class inherits any wildcard
      # routes in addition to its own.
      def collect_local_routes(name)
        triggers = []
        Parse::API::Hooks::TRIGGER_NAMES_LOCAL.each do |trigger|
          route_map = Parse::Webhooks.routes[trigger]
          next if route_map.nil?
          if route_map[name].present?
            triggers << trigger
          elsif name != "*" && route_map["*"].present?
            triggers << trigger
          end
        end
        triggers
      end

      # Cross-reference the three axes and emit findings. Finding kinds:
      #
      # - `:callbacks_inert` — app callbacks exist that map to an object trigger,
      #   but the local route and/or the server trigger is missing, so they never
      #   run for non-Ruby clients. The headline gap. `missing:` lists which
      #   piece(s) are absent (`:route`, `:server`).
      # - `:route_not_registered` — a local webhook block exists but the server
      #   trigger is not registered, so Parse Server never POSTs to it.
      # - `:orphan_server_trigger` — a server trigger is registered but there is no
      #   local route to handle it; the round-trip is wasted (the router returns a
      #   success no-op).
      # - `:local_only_callbacks` — informational: `before_update` / `after_update`
      #   / `*_validation` callbacks that no server trigger can ever run.
      def analyze(name, callbacks, routes, server)
        findings = []
        server_known = @networked

        # Which object triggers do the app callbacks require?
        required = Hash.new { |h, k| h[k] = [] } # trigger => [callback keys]
        callbacks.each_key do |cb_key|
          kind, chain = split_callback_key(cb_key)
          if (trigger = CALLBACK_TRIGGER_MAP[[chain, kind]])
            required[trigger] << cb_key
          end
        end

        required.each do |trigger, cb_keys|
          has_route  = routes.include?(trigger)
          has_server = server.key?(trigger)
          missing = []
          missing << :route unless has_route
          missing << :server if server_known && !has_server
          next if missing.empty?

          findings << {
            kind:    :callbacks_inert,
            trigger: trigger,
            missing: missing,
            callbacks: cb_keys.sort,
            message: inert_message(name, trigger, missing, cb_keys),
          }
        end

        # Local block registered but no server trigger.
        if server_known
          routes.each do |trigger|
            next unless OBJECT_TRIGGERS.include?(trigger) ||
                        Parse::API::Hooks::TRIGGER_NAMES_LOCAL.include?(trigger)
            next if server.key?(trigger)
            # Wildcard-only coverage is reported on the "*" row, not here.
            next unless Parse::Webhooks.routes[trigger]&.key?(name)
            findings << {
              kind:    :route_not_registered,
              trigger: trigger,
              message: "Local `webhook :#{trigger}` block for #{name} is not " \
                       "registered as a server trigger — run register_triggers! " \
                       "so Parse Server POSTs to it.",
            }
          end

          # Server trigger registered but nothing local handles it.
          server.each_key do |trigger|
            next if routes.include?(trigger)
            findings << {
              kind:    :orphan_server_trigger,
              trigger: trigger,
              message: "Server trigger #{trigger} is registered for #{name} but no " \
                       "local webhook block handles it — every matching operation " \
                       "pays a webhook round-trip that does nothing.",
            }
          end
        end

        # Local-only callbacks (informational).
        local_only = callbacks.keys.filter_map do |cb_key|
          kind, chain = split_callback_key(cb_key)
          cb_key if LOCAL_ONLY_MAP.key?([chain, kind])
        end
        if local_only.any?
          findings << {
            kind:    :local_only_callbacks,
            callbacks: local_only.sort,
            message: "#{name} has local-only callbacks (#{local_only.sort.join(", ")}) " \
                     "that no server trigger can run — they fire for Ruby-initiated " \
                     "saves but never for non-Ruby clients.",
          }
        end

        findings
      end

      # ":before_save" => [:before, :save]; "after_create" => [:after, :create].
      def split_callback_key(cb_key)
        s = cb_key.to_s
        if s.start_with?("before_")
          [:before, s.sub("before_", "").to_sym]
        elsif s.start_with?("after_")
          [:after, s.sub("after_", "").to_sym]
        else
          [nil, nil]
        end
      end

      def inert_message(name, trigger, missing, cb_keys)
        callbacks = cb_keys.sort.join(", ")
        reason =
          if missing == [:route, :server]
            "neither a local `webhook :#{trigger}` block nor a server trigger is " \
              "registered"
          elsif missing == [:route]
            "no local `webhook :#{trigger}` block is registered to handle it"
          else # [:server]
            "a local block exists but the #{trigger} server trigger is not registered"
          end
        "#{name} callbacks (#{callbacks}) will NOT run for non-Ruby clients: " \
          "#{reason}. Register `webhook :#{trigger}` and run register_triggers!."
      end

      def finding_glyph(kind)
        case kind
        when :callbacks_inert       then "GAP "
        when :route_not_registered  then "GAP "
        when :orphan_server_trigger then "WARN"
        when :local_only_callbacks  then "note"
        else "    "
        end
      end
    end

    class << self
      # Audit trigger logic across all registered classes, cross-referencing model
      # ActiveModel callbacks, locally registered webhook blocks, and the triggers
      # registered on Parse Server. See {Parse::Webhooks::TriggerAudit}.
      #
      # The server comparison reads the master-key-only `hooks/triggers` endpoint,
      # so `network: true` (the default) requires a master-key client. Pass
      # `network: false` for a credential-free audit of callbacks vs. local routes.
      #
      # @param pretty [Boolean] when true, return the human-readable String summary
      #   instead of the Hash report.
      # @param network [Boolean] query Parse Server for registered triggers.
      # @param client [Parse::Client, nil] optional client override.
      # @param include_framework [Boolean] include gem-internal callbacks.
      # @return [Hash, String] the report Hash, or the pretty String when
      #   `pretty: true`.
      def trigger_audit(pretty: false, network: true, client: nil, include_framework: false)
        audit = TriggerAudit.new(
          network: network, client: client, include_framework: include_framework
        )
        pretty ? audit.pretty : audit.to_h
      end
    end
  end
end
