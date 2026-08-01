# encoding: UTF-8
# frozen_string_literal: true

require "set"
require_relative "clp_scope"

module Parse
  # Local, evidence-aware inspection of Parse Server object permissions.
  #
  # This is a policy preflight, not an authorization boundary: sessions can be
  # revoked and Cloud Code or custom adapters can add rules the SDK cannot see.
  # The actual Parse Server request remains authoritative. Boolean convenience
  # predicates accept only `:allowed`; both `:denied` and `:unknown` fail closed.
  module Access
    OPERATIONS = %i[read write delete].freeze
    CLP_OPERATIONS = { read: :get, write: :update, delete: :delete }.freeze
    SUPPORTED_SYSTEM_CLASSES = %w[_User _Role].freeze

    # An access answer together with the evidence behind it.
    class Decision
      attr_reader :status, :operation, :reasons, :details

      def initialize(status:, operation:, reasons: [], details: {})
        @status = status.to_sym
        @operation = operation.to_sym
        @reasons = Array(reasons).compact.map(&:to_sym).uniq.freeze
        @details = details.dup.freeze
        freeze
      end

      def allowed?
        status == :allowed
      end

      def denied?
        status == :denied
      end

      def unknown?
        status == :unknown
      end

      def to_h
        { status: status, operation: operation, reasons: reasons, details: details }
      end
    end

    LayerResult = Struct.new(:status, :via, :reason, :role_claims, keyword_init: true)
    Attempt = Struct.new(:decision, :roles_could_help, keyword_init: true)
    private_constant :LayerResult, :Attempt

    class << self
      # Inspect one operation. `authenticated: true` is an assertion by the
      # caller; it does not validate a session token. When omitted for a user,
      # an attached session token is accepted as local evidence. An id-only
      # user is not treated as authenticated. A role represents a hypothetical
      # authenticated member, but cannot satisfy user/pointer-specific rules.
      #
      # @param principal [Parse::User, Parse::Role]
      # @param object [Parse::Object]
      # @param operation [Symbol] `:read`, `:write`, or `:delete`.
      # @param client [Parse::Client, nil] application whose CLP and role graph
      #   should be inspected. Defaults to the principal's configured client.
      # @param authenticated [Boolean, nil] explicit authentication evidence.
      # @param max_role_depth [Integer] maximum inherited-role traversal depth.
      # @return [Decision]
      def check(principal:, object:, operation:, client: nil, authenticated: nil,
                max_role_depth: 10)
        Checker.new(
          principal: principal,
          object: object,
          client: client,
          authenticated: authenticated,
          max_role_depth: max_role_depth,
        ).check(operation)
      end

      # Inspect multiple operations while sharing one role-closure lookup.
      # @return [Hash<Symbol, Decision>]
      def check_all(principal:, object:, operations: OPERATIONS, client: nil,
                    authenticated: nil, max_role_depth: 10)
        checker = Checker.new(
          principal: principal,
          object: object,
          client: client,
          authenticated: authenticated,
          max_role_depth: max_role_depth,
        )
        Array(operations).each_with_object({}) do |operation, decisions|
          op = operation.to_sym
          decisions[op] = checker.check(op)
        end.freeze
      end
    end

    # Stateful only for the lifetime of one check/check_all call so an inherited
    # role closure can be reused without becoming a stale authorization cache.
    class Checker
      def initialize(principal:, object:, client:, authenticated:, max_role_depth:)
        @principal = principal
        @object = object
        @client = client || principal_client
        @authentication = authentication_state(authenticated)
        @max_role_depth = Integer(max_role_depth)
        @expanded_claims = nil
        @role_lookup_error = nil
      rescue ArgumentError, TypeError
        @max_role_depth = 0
      end

      def check(operation)
        op = operation.to_sym
        raise ArgumentError, "unsupported access operation: #{operation.inspect}" unless
          OPERATIONS.include?(op)

        preflight = preflight_decision(op)
        return preflight if preflight

        case @authentication
        when :unknown
          check_with_unknown_authentication(op)
        when :authenticated
          check_with_authenticated_principal(op)
        else
          evaluate(op, public_claims, authenticated: false).decision
        end
      end

      private

      def preflight_decision(operation)
        unless valid_principal?
          return decision(:unknown, operation, :unsupported_principal)
        end
        unless defined?(Parse::Object) && @object.is_a?(Parse::Object)
          return decision(:unknown, operation, :invalid_target)
        end
        return decision(:unknown, operation, :client_required) if @client.nil?
        if @object.respond_to?(:has_selective_keys?) && @object.has_selective_keys?
          return decision(:unknown, operation, :target_partially_fetched)
        end
        return decision(:unknown, operation, :target_is_pointer) if @object.pointer?

        class_name = @object.parse_class.to_s
        if class_name.start_with?("_") && !SUPPORTED_SYSTEM_CLASSES.include?(class_name)
          return decision(:unknown, operation, :unsupported_system_class)
        end

        user_target_preflight(operation, class_name)
      rescue StandardError
        decision(:unknown, operation, :target_state_unavailable)
      end

      def user_target_preflight(operation, class_name)
        return unless class_name == Parse::Model::CLASS_USER
        return if operation == :read

        # Parse Server only permits a user to update/delete their own `_User`
        # row. A role cannot identify which member is making the request.
        return decision(:unknown, operation, :user_self_requires_concrete_member) if role_principal?
        return decision(:denied, operation, :authentication_required) if @authentication == :anonymous
        return decision(:unknown, operation, :authentication_unverified) if @authentication == :unknown

        principal_id = safe_user_id
        target_id = @object.id.to_s
        if principal_id.empty? || target_id.empty?
          return decision(:unknown, operation, :user_identity_unavailable)
        end
        return decision(:denied, operation, :user_self_only) unless principal_id == target_id

        nil
      end

      def check_with_unknown_authentication(operation)
        anonymous = evaluate(operation, public_claims, authenticated: false)
        return anonymous.decision if anonymous.decision.allowed?

        # Probe only the direct identity claim. Never traverse a role graph for
        # an id-only User: without a session that would let callers enumerate
        # another user's effective permissions by assigning a victim objectId.
        asserted = evaluate(operation, direct_claims, authenticated: true)
        if asserted.decision.denied? && !asserted.roles_could_help
          asserted.decision
        else
          decision(:unknown, operation, :authentication_unverified)
        end
      end

      def check_with_authenticated_principal(operation)
        direct = evaluate(operation, direct_claims, authenticated: true)
        return direct.decision if direct.decision.allowed?
        return direct.decision unless direct.roles_could_help
        return decision(:unknown, operation, :invalid_role_depth) if @max_role_depth <= 0
        unless role_identity_available?
          return decision(:unknown, operation, :role_identity_unavailable)
        end

        claims = expanded_claims
        if @role_lookup_error
          return decision(
                   :unknown,
                   operation,
                   :role_membership_unavailable,
                   role_error: @role_lookup_error.class.name,
                 )
        end
        evaluate(operation, claims, authenticated: true).decision
      end

      def evaluate(operation, claims, authenticated:)
        acl = acl_evaluation(operation, claims, authenticated: authenticated)
        clp = Parse::CLPScope.evaluate_access(
          @object.parse_class,
          CLP_OPERATIONS.fetch(operation),
          claims: claims,
          authenticated: authenticated,
          user_id: concrete_user_id(authenticated),
          client: @client,
        )

        row_status = :allowed
        row_reason = nil
        if clp.row_check_required?
          if clp.pointer_fields.any? { |field| !pointer_field_supported?(field) }
            row_status = :unknown
            row_reason = :pointer_field_schema_unavailable
          elsif pointer_field_locally_changed?(clp.pointer_fields)
            row_status = :unknown
            row_reason = :pointer_field_has_local_changes
          elsif pointer_fields_match?(clp.pointer_fields, concrete_user_id(authenticated))
            row_status = :allowed
          else
            row_status = :denied
            row_reason = :pointer_field_mismatch
          end
        end

        statuses = [acl.status, clp.status, row_status]
        status = if statuses.include?(:denied)
            :denied
          elsif statuses.include?(:unknown)
            :unknown
          else
            :allowed
          end
        reasons = [acl.reason, clp.reason, row_reason]
        details = { acl_via: acl.via, clp_via: clp.via }.compact

        # Parent/user roles can recover a failed layer only when every other
        # AND-ed layer is either already allowed or has its own role branch.
        acl_recoverable = acl.status == :allowed || acl.role_claims.any?
        clp_recoverable = clp.allowed? || clp.role_claims.any?
        role_branch_exists = acl.role_claims.any? || clp.role_claims.any?
        roles_could_help = status != :allowed && role_branch_exists &&
                           acl_recoverable && clp_recoverable

        result = decision(status, operation, reasons, details)
        if role_principal? && @object.parse_class == Parse::Model::CLASS_USER &&
           operation == :read && !result.allowed?
          result = decision(:unknown, operation, :user_self_requires_concrete_member)
        end

        Attempt.new(decision: result, roles_could_help: roles_could_help)
      rescue StandardError => e
        Attempt.new(
          decision: decision(:unknown, operation, :permission_evaluation_failed,
                             error: e.class.name),
          roles_could_help: false,
        )
      end

      def acl_evaluation(operation, claims, authenticated:)
        if user_self?(authenticated)
          return layer(:allowed, via: :user_self)
        end

        state = if @object.respond_to?(:authorization_acl_state)
            @object.authorization_acl_state
          else
            :unknown
          end
        return layer(:unknown, reason: :acl_unavailable) if state == :unknown

        if @object.id.to_s.length.positive? && @object.respond_to?(:acl_changed?) &&
           @object.acl_changed?
          return layer(:unknown, reason: :acl_has_local_changes)
        end
        return layer(:allowed, via: :public_default) if state == :absent

        acl = @object.acl
        return layer(:unknown, reason: :acl_unavailable) if acl.nil?
        keys = if operation == :read
            acl.readable_by
          else
            acl.writable_by
          end
        keys = Array(keys).map(&:to_s)
        roles = keys.select { |key| key.start_with?("role:") }
        if keys.any? { |key| claims.include?(key) }
          via = keys.include?(Parse::ACL::PUBLIC) ? :public : :principal
          layer(:allowed, via: via, role_claims: roles)
        else
          layer(:denied, reason: :acl_denied, role_claims: roles)
        end
      end

      def user_self?(authenticated)
        return false unless authenticated && user_principal?
        return false unless @object.parse_class == Parse::Model::CLASS_USER
        principal_id = safe_user_id
        !principal_id.empty? && principal_id == @object.id.to_s
      end

      def pointer_fields_match?(fields, user_id)
        return false if user_id.to_s.empty?
        return true if fields.any? { |field| local_pointer_value_matches?(field, user_id) }
        document = @object.as_json(only_fetched: false)
        Parse::CLPScope.filter_by_pointer_fields([document], fields, user_id).any?
      end

      def pointer_field_supported?(field)
        local, type = pointer_field_definition(field)
        return false if local.nil?
        return true if type == :array
        return false unless type == :pointer
        target = @object.class.references[local]
        Parse::Model.same_parse_class?(target, Parse::Model::CLASS_USER)
      rescue StandardError
        false
      end

      def pointer_field_definition(field)
        local = @object.field_map.find do |key, remote|
          key.to_s == field.to_s || remote.to_s == field.to_s
        end&.first
        [local, local && @object.class.fields[local]]
      end

      # Included pointers may be hydrated as full Parse::User objects. Their
      # JSON representation has `__type: "Object"`, so the strict wire-format
      # matcher correctly rejects it as a pointer; the typed local value still
      # proves both the `_User` class and objectId without triggering a getter
      # (and therefore without autofetching).
      def local_pointer_value_matches?(field, user_id)
        local, = pointer_field_definition(field)
        return false if local.nil?
        value = @object.instance_variable_get(:"@#{local}")
        values = if value.respond_to?(:collection)
            value.collection
          elsif value.is_a?(Array)
            value
          else
            [value]
          end
        values.any? do |candidate|
          candidate.respond_to?(:parse_class) && candidate.respond_to?(:id) &&
            Parse::Model.same_parse_class?(candidate.parse_class, Parse::Model::CLASS_USER) &&
            candidate.id.to_s == user_id.to_s
        end
      rescue StandardError
        false
      end

      def pointer_field_locally_changed?(fields)
        return false if @object.id.to_s.empty?
        changed = @object.respond_to?(:changed) ? @object.changed.map(&:to_s) : []
        fields.any? do |field|
          local = @object.field_map.find { |_key, remote| remote.to_s == field.to_s }&.first
          changed.include?(field.to_s) || (local && changed.include?(local.to_s))
        end
      end

      def expanded_claims
        return @expanded_claims if @expanded_claims
        claims = direct_claims.dup
        names = if user_principal?
            Parse::Role.all_for_user(
              @principal,
              max_depth: @max_role_depth,
              client: @client,
              strict: true,
            )
          else
            @principal.all_parent_role_names(
              max_depth: @max_role_depth,
              client: @client,
              strict: true,
            )
          end
        Array(names).each do |name|
          next if name.to_s.empty?
          claims << "role:#{name}"
        end
        @expanded_claims = claims.freeze
      rescue StandardError => e
        @role_lookup_error = e
        @expanded_claims = direct_claims.freeze
      end

      def public_claims
        Set.new([Parse::ACL::PUBLIC]).freeze
      end

      def direct_claims
        claims = Set.new([Parse::ACL::PUBLIC])
        if user_principal?
          user_id = safe_user_id
          claims << user_id unless user_id.empty?
        else
          role_name = safe_role_name
          claims << "role:#{role_name}" unless role_name.empty?
        end
        claims
      end

      def concrete_user_id(authenticated)
        authenticated && user_principal? ? safe_user_id : nil
      end

      def authentication_state(explicit)
        return :authenticated if explicit == true
        return :anonymous if explicit == false
        return :authenticated if role_principal?
        return :unknown unless user_principal?
        token = @principal.instance_variable_get(:@session_token)
        token.is_a?(String) && !token.empty? ? :authenticated : :unknown
      end

      def valid_principal?
        user_principal? || role_principal?
      end

      def user_principal?
        defined?(Parse::User) && @principal.is_a?(Parse::User)
      end

      def role_principal?
        defined?(Parse::Role) && @principal.is_a?(Parse::Role)
      end

      def safe_user_id
        user_principal? ? @principal.id.to_s : ""
      rescue StandardError
        ""
      end

      # Reading Role#name can autofetch an id-only role. Permission inspection
      # must stay local, so use only an already-hydrated value.
      def safe_role_name
        value = @principal.instance_variable_get(:@name) if role_principal?
        value.to_s
      rescue StandardError
        ""
      end

      def role_identity_available?
        if user_principal?
          !safe_user_id.empty?
        else
          !safe_role_name.empty? && !@principal.id.to_s.empty?
        end
      rescue StandardError
        false
      end

      def principal_client
        @principal.client if @principal.respond_to?(:client)
      rescue StandardError
        nil
      end

      def layer(status, via: nil, reason: nil, role_claims: [])
        LayerResult.new(
          status: status,
          via: via,
          reason: reason,
          role_claims: Array(role_claims).freeze,
        )
      end

      def decision(status, operation, reasons = [], details = {})
        Decision.new(
          status: status,
          operation: operation,
          reasons: reasons,
          details: details,
        )
      end
    end

    private_constant :Checker
  end
end
