# encoding: UTF-8
# frozen_string_literal: true

require "active_support/concern"

module Parse
  module Core
    # Declarative write protection for model fields, enforced inside
    # before_save webhook handling. Unlike Parse Server's class-level
    # `protectedFields` (which only hides values on read), these guards
    # revert disallowed client writes before the change reaches the
    # persistent store.
    #
    # Four modes are supported:
    #
    # * `:master_only`      - the field is never writable by clients. Any
    #   client-supplied value is reverted; master-key requests bypass
    #   the guard.
    # * `:immutable`        - the field is writable when the object is
    #   created but is reverted on any subsequent client update.
    #   Master-key requests bypass the guard.
    # * `:always_immutable` - same as `:immutable` for creates, but the
    #   field is also reverted on master-key updates. Useful for fields
    #   that must NEVER change after creation regardless of who is
    #   writing (e.g. a one-way state transition marker, or a slug used
    #   in canonical URLs that breaks on rename).
    # * `:set_once`         - the field is writable while the persisted
    #   value is blank, then locked forever. Master-key writes DO NOT
    #   bypass the lock once a value is set. Useful for derived fields
    #   that are populated by an after_create callback (e.g.
    #   `parse_reference`) where the canonical value depends on the
    #   server-assigned objectId and must never change after first
    #   assignment.
    #
    # Reverts are a silent successful no-op from the client's perspective:
    # the save proceeds normally, the guarded field simply isn't written.
    # A DEBUG-level log line is emitted for diagnosis, but nothing is raised
    # and nothing is logged at WARN/INFO, so clients that routinely resubmit
    # a full record don't generate log noise.
    #
    # @example
    #   class Project < Parse::Object
    #     property :slug, :string
    #     property :created_by, :pointer
    #
    #     guard :created_by, :master_only
    #     guard :slug, :external_id, :immutable
    #   end
    module FieldGuards
      extend ActiveSupport::Concern

      GUARD_MODES = [:master_only, :immutable, :always_immutable, :set_once].freeze

      included do
        class_attribute :field_guards, instance_writer: false
        self.field_guards = {}.freeze
      end

      module ClassMethods
        # Declare one or more guarded fields. Two call shapes are accepted:
        #
        #   guard :slug, :immutable                 # positional mode (must be the last arg)
        #   guard :owner, :tags, :master_only       # multiple fields, positional mode
        #   guard :slug, mode: :immutable           # keyword mode (less ambiguous)
        #
        # @param fields [Array<Symbol>] one or more field names
        # @param mode [Symbol, nil] positional mode; required unless `mode:` keyword is given
        # @param mode_kw [Symbol, nil] keyword mode (alternative to the trailing positional arg)
        def guard(*fields, mode: nil)
          # Support `guard :field, :master_only` by treating a trailing
          # symbol that matches a known mode as the positional mode arg.
          # Anything else (unknown symbol, no trailing symbol, etc.) falls
          # through to the validation below with a clear error message.
          if mode.nil? && fields.last.is_a?(Symbol) && GUARD_MODES.include?(fields.last)
            mode = fields.pop
          end

          raise ArgumentError, "guard requires at least one field name" if fields.empty?
          unless GUARD_MODES.include?(mode)
            raise ArgumentError,
                  "guard mode missing or invalid: #{mode.inspect}. " \
                  "Allowed: #{GUARD_MODES.inspect}. Call as " \
                  "`guard :field, :master_only` or `guard :field, mode: :master_only`."
          end

          new_guards = field_guards.dup
          fields.each { |f| new_guards[f.to_sym] = mode }
          self.field_guards = new_guards.freeze

          # Ensure Parse Server is configured to call our webhook for this
          # class. Without a before_save route, the webhook is never invoked
          # and the guard is silently a no-op (a credible misconfiguration
          # footgun). Register a stub only if no handler exists yet; if the
          # user later declares `webhook :before_save`, it replaces this stub.
          ensure_field_guards_webhook!
        end

        # @!visibility private
        def ensure_field_guards_webhook!
          return unless respond_to?(:parse_class)
          class_name = parse_class
          return if class_name.blank?
          # Load-order safety: in `lib/parse/stack.rb` the model classes are
          # required before `Parse::Webhooks`, so a `guard` declaration in a
          # class body (e.g. `Parse::User`) fires before the Webhooks
          # constant exists. Skip the route registration in that case —
          # application code that uses `guard` from its own model files (a
          # later load step) will hit this path with Webhooks already
          # loaded, and Parse::Webhooks.route_field_guards! re-registers the
          # built-in routes after Webhooks loads.
          return unless defined?(Parse::Webhooks)
          existing = Parse::Webhooks.routes[:before_save][class_name]
          return if existing.present?
          Parse::Webhooks.route(:before_save, self) { parse_object }
        end
      end

      # Revert any disallowed client writes per the class-level guards.
      # Called by {Parse::Webhooks.call_route} for before_save triggers,
      # before {Parse::Object#prepare_save!} runs.
      #
      # @param master [Boolean] true if the webhook request used the master key
      # @param is_new [Boolean] true if this is a create (no original record)
      # @return [Array<Symbol>] field names that were reverted
      def apply_field_guards!(master:, is_new:)
        guards = self.class.field_guards
        return [] if guards.blank?

        reverted = guards.each_with_object([]) do |(field, mode), acc|
          next unless changed.include?(field.to_s)
          case mode
          when :master_only
            # Master bypasses; client writes always reverted
            next if master
            revert_field!(field, is_new: is_new)
            acc << field
          when :immutable
            # Master bypasses; clients can set on create, never on update
            next if master
            next if is_new
            revert_field!(field, is_new: false)
            acc << field
          when :always_immutable
            # No master bypass on updates: the field is frozen for everyone
            # (including server/admin code using the master key) once the
            # object exists. Creates are still allowed for everyone.
            next if is_new
            revert_field!(field, is_new: false)
            acc << field
          when :set_once
            # Allow writes while the persisted (original) value is blank;
            # lock the field once it holds a value. No master bypass --
            # once set, NOTHING can change it. Implementation note: this
            # checks the dirty-tracked "was" value rather than the current
            # value, so an update payload that includes a new value is
            # only rejected if the field was previously populated.
            previous = changed_attributes[field.to_s]
            next if previous.nil? || previous.to_s.strip.empty?
            revert_field!(field, is_new: false)
            acc << field
          end
        end

        if reverted.any?
          klass = self.class.respond_to?(:parse_class) ? self.class.parse_class : self.class.name
          oid = (respond_to?(:id) && id) || "<new>"
          Parse.logger&.debug(
            "[Parse::FieldGuards] Reverted client writes on #{klass}:#{oid} -> #{reverted.join(", ")}"
          )
        end

        reverted
      end

      private

      # On update: restore the previous persisted value and clear dirty.
      # On create: zero the field (still dirty) so the response payload
      # tells Parse Server to drop the client-supplied value instead of
      # silently letting it through.
      #
      # Handles three field shapes:
      #   * Scalar properties (including belongs_to pointers): ActiveModel
      #     `restore_attributes` sets back to the prior value and clears dirty.
      #   * has_many :relation fields: the proxy itself tracks pending
      #     add/remove operations; we roll those back on the proxy and clear
      #     the parent's dirty flag so {Parse::Object#relation_change_operations}
      #     emits nothing for this field.
      #   * has_many array fields (PointerCollectionProxy backed by an Array
      #     property): treated as a scalar property; `restore_attributes`
      #     reassigns the prior proxy. Mutations to a proxy that doesn't
      #     trigger a setter (e.g. some in-place edits) may not fully revert;
      #     prefer assigning a new array if you need strict revert semantics.
      def revert_field!(field, is_new:)
        field_sym = field.to_sym
        field_str = field.to_s

        if respond_to?(:relations) && relations[field_sym]
          proxy = public_send(field_sym)
          # Reset the pending add/remove ledger that backs
          # relation_change_operations. The proxy itself has no public reset
          # API for these (its rollback!/restore_attributes path expects
          # setters that don't exist for additions/removals), so we clear
          # them directly and then drop the proxy's dirty markers.
          proxy.instance_variable_set(:@additions, []) if proxy.instance_variable_defined?(:@additions)
          proxy.instance_variable_set(:@removals, []) if proxy.instance_variable_defined?(:@removals)
          proxy.clear_changes! if proxy.respond_to?(:clear_changes!)
          clear_attribute_changes([field_str])
          return
        end

        if is_new
          public_send("#{field_str}=", nil)
        else
          restore_attributes([field_str])
        end
      end
    end
  end
end
