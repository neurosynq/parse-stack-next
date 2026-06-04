# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # Sanitization primitives for prompt-injection hardening (NEW-PROMPT-6).
    # A single home for the transforms applied to data that flows toward an
    # LLM: schema descriptions surfaced by the schema tools, untrusted tool
    # result content, and canary scanning of tool results.
    #
    # All functions are pure (module_function via `extend self`) and have no
    # dependency on a live client.
    module PromptHardening
      extend self

      # Identifier shape for LLM-surfaced field names: ASCII letter/underscore
      # start, then up to 127 more identifier chars. NOT the secret-field
      # boundary — it permits a leading underscore; `_rperm`/`_hashed_password`
      # are stopped by field_allowlist / validate_keys!, untouched here. This
      # only drops non-identifier names (spaces, punctuation, >128 chars,
      # leading digit) that could carry injection payloads in a field name.
      # The length is an injection-safety cap, not a Parse limit — it is set
      # well above any realistic field name so valid identifiers aren't
      # silently dropped from the schema surfaced to the LLM.
      FIELD_NAME_RE = /\A[a-zA-Z_][a-zA-Z0-9_]{0,127}\z/

      # Max characters retained from any LLM-surfaced description.
      DESCRIPTION_CAP = 200

      SCHEMA_DESC_OPEN  = "<schema_description>"
      SCHEMA_DESC_CLOSE = "</schema_description>"

      # C0 (0x00-0x1F except \t\n) + DEL + C1 (0x7F-0x9F) + zero-width
      # (200B-200D, 2060, FEFF). Stripped from descriptions so invisible
      # control/format characters can't smuggle instructions past a human
      # reviewer or confuse the model.
      CONTROL_CHARS_RE = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u200B-\u200D\u2060\uFEFF]/

      # Sub-part 1 — sanitize an enriched schema hash before it is
      # serialized toward the LLM. Returns a sanitized deep copy (input is
      # not mutated). Drops fields whose names fail {FIELD_NAME_RE} (with a
      # `[Parse::Agent:PROMPT]` warning), and scrubs + caps + marker-wraps
      # every description / usage string (class-level, per-field, and enum
      # value descriptions).
      #
      # @param schema [Hash]
      # @return [Hash]
      def sanitize_schema_for_llm(schema)
        return schema unless schema.is_a?(Hash)
        out = deep_dup(schema)
        class_name = out["className"] || out[:className]

        %w[description usage].each do |k|
          out[k] = sanitize_description(out[k]) if out[k].is_a?(String)
        end

        fields = out["fields"] || out[:fields]
        if fields.is_a?(Hash)
          fields.keys.each do |fname|
            unless valid_field_name?(fname)
              fields.delete(fname)
              warn "[Parse::Agent:PROMPT] dropped field #{fname.inspect} on " \
                   "#{class_name.inspect}: invalid identifier"
              next
            end
            cfg = fields[fname]
            next unless cfg.is_a?(Hash)
            %w[description usage].each do |k|
              cfg[k] = sanitize_description(cfg[k]) if cfg[k].is_a?(String)
            end
            allowed = cfg["allowed_values"] || cfg[:allowed_values]
            if allowed.is_a?(Array)
              allowed.each do |v|
                next unless v.is_a?(Hash)
                v["description"] = sanitize_description(v["description"]) if v["description"].is_a?(String)
                v[:description]  = sanitize_description(v[:description])  if v[:description].is_a?(String)
              end
            end
          end
        end

        # agent_methods entries are surfaced to the LLM by format_schema exactly
        # like field descriptions, and their :description / per-parameter
        # description strings come from the same developer-authored DSL — so they
        # get the same marker-neutralization / control-char strip / length cap.
        # (format_methods emits symbol-keyed hashes; tolerate both forms.)
        methods = out["agent_methods"] || out[:agent_methods]
        if methods.is_a?(Array)
          methods.each do |m|
            next unless m.is_a?(Hash)
            m["description"] = sanitize_description(m["description"]) if m["description"].is_a?(String)
            m[:description]  = sanitize_description(m[:description])  if m[:description].is_a?(String)
            sanitize_nested_descriptions!(m["parameters"] || m[:parameters])
          end
        end

        out
      end

      # @return [Boolean] whether `name` is a safe LLM-surfaceable identifier.
      def valid_field_name?(name)
        FIELD_NAME_RE.match?(name.to_s)
      end

      # Scrub control chars, cap length, and wrap a description in
      # <schema_description> markers. Markers in the RAW text are neutralized
      # FIRST (so a stored `</schema_description>` can't close the wrapper).
      #
      # @param str [String]
      # @return [String]
      def sanitize_description(str)
        return str unless str.is_a?(String)
        cleaned = scrub_marker_injection(str)
        cleaned = cleaned.gsub(CONTROL_CHARS_RE, "")
        cleaned = cleaned[0, DESCRIPTION_CAP] if cleaned.length > DESCRIPTION_CAP
        "#{SCHEMA_DESC_OPEN}#{cleaned}#{SCHEMA_DESC_CLOSE}"
      end

      # Sub-part 2 — neutralize wrapper/marker strings embedded in untrusted
      # content so a stored value cannot impersonate or close the
      # tool-result wrapper. Idempotent: the escaped form no longer contains
      # the original literal, so re-application is a no-op (content is
      # re-serialized into history every turn).
      #
      # When `Parse::Agent.prompt_marker_strict` is true, raises instead of
      # escaping (fail-closed for high-assurance deployments).
      #
      # @param content [String, #to_s]
      # @return [String]
      def scrub_marker_injection(content)
        s = content.to_s
        strict = Parse::Agent.prompt_marker_strict
        injection_markers.each do |marker|
          next unless s.include?(marker)
          if strict
            raise Parse::Agent::SecurityError,
                  "prompt_marker_strict: untrusted content contains a reserved marker"
          end
          s = s.gsub(marker, escape_marker(marker))
        end
        s
      end

      # Sub-part 3 — scan text for any operator-registered canary phrase.
      # @param text [String]
      # @return [String, nil] the matched phrase/pattern source, or nil.
      def scan_for_canaries(text)
        canaries = Parse::Agent.prompt_injection_canaries
        return nil if canaries.nil? || canaries.empty?
        s = text.to_s
        return nil if s.empty?
        down = s.downcase
        canaries.each do |c|
          case c
          when Regexp
            return c.source if c.match?(s)
          else
            phrase = c.to_s
            return phrase if !phrase.empty? && down.include?(phrase.downcase)
          end
        end
        nil
      end

      private

      # Recursively run every `description` string nested in an agent method's
      # JSON-Schema `parameters` through {#sanitize_description}, so per-parameter
      # descriptions get the same hardening as field descriptions. Mutates in
      # place; tolerates string- and symbol-keyed hashes and arbitrary nesting.
      def sanitize_nested_descriptions!(node)
        case node
        when Hash
          node.each do |k, v|
            if (k == "description" || k == :description) && v.is_a?(String)
              node[k] = sanitize_description(v)
            else
              sanitize_nested_descriptions!(v)
            end
          end
        when Array
          node.each { |e| sanitize_nested_descriptions!(e) }
        end
      end

      # The literal strings scrub_marker_injection neutralizes. The MCP
      # wrapper marker is resolved lazily to avoid a load-order dependency.
      def injection_markers
        markers = [SCHEMA_DESC_OPEN, SCHEMA_DESC_CLOSE]
        if defined?(Parse::Agent::MCPClient::UNTRUSTED_TOOL_RESULT_MARKER)
          markers << Parse::Agent::MCPClient::UNTRUSTED_TOOL_RESULT_MARKER
        end
        markers
      end

      # Insert a backslash after the first character so the original literal
      # no longer occurs (keeps the text human-readable and idempotent).
      def escape_marker(marker)
        return marker if marker.length < 2
        "#{marker[0]}\\#{marker[1..]}"
      end

      def deep_dup(obj)
        case obj
        when Hash  then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
        when Array then obj.map { |e| deep_dup(e) }
        when String then obj.dup
        else obj
        end
      end
    end
  end
end
