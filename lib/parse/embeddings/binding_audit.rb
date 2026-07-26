# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Embeddings
    # Checks that a `:vector` property's declared provider binding
    # still matches the provider actually registered under that name.
    #
    # A `:vector` property may declare `provider:`, `model:`, and
    # `dimensions:`. Only `provider:` was ever enforced. `dimensions:`
    # is verified — but only against the vector a provider already
    # returned, i.e. after the call has been made and paid for. And
    # `model:` was never checked at all, which is the dangerous one: two
    # generations of the same model family usually share a width
    # (`voyage-3` and `voyage-3.5` are both 1024), so swapping the
    # registered provider's model silently mixes incompatible
    # embeddings into one index. Nothing raises, recall just quietly
    # degrades, and the damage is only repairable by re-embedding.
    #
    # This module closes both gaps by comparing the declaration against
    # the live provider BEFORE any request is issued.
    #
    # Auditing cannot happen at class-definition time: providers are
    # registered by name and, as {Parse::Core::EmbedManaged} documents,
    # registration may legitimately happen any time before the first
    # save. So the audit runs lazily on each use and is also exposed as
    # {.audit_all!} for an explicit boot-time or CI check.
    module BindingAudit
      # Raised when a property's declared binding disagrees with the
      # registered provider.
      class BindingMismatch < Parse::Embeddings::Error; end

      # Raised when the audit cannot enumerate the classes it is meant
      # to check. Distinct from {BindingMismatch}: nothing was found to
      # be wrong, but nothing was verified either.
      class DiscoveryFailed < Parse::Embeddings::Error; end

      class << self
        # Verify one property binding against a resolved provider.
        #
        # Deliberately NOT memoized. The check is a pair of comparisons
        # against values already in memory, so caching it saves nothing
        # measurable — while any cache key cheap enough to be worth
        # computing (class name, provider object id) can go stale when a
        # class is unloaded and redefined with a changed declaration, or
        # when object ids are recycled. A validator that silently skips
        # after a reload is worse than no validator, so correctness wins
        # over an optimization with no observable benefit.
        #
        # @param klass [Class] the Parse::Object subclass.
        # @param field [Symbol] the `:vector` property name.
        # @param provider [Parse::Embeddings::Provider]
        # @raise [BindingMismatch]
        # @return [void]
        def verify!(klass, field, provider)
          declared = klass.vector_properties[field.to_sym]
          return if declared.nil?

          check!(klass, field, provider, declared)
          nil
        end

        # Audit every declared binding whose provider is registered.
        # Intended for boot or CI: it surfaces a drifted declaration
        # before a single embedding is written, rather than on the
        # first save that happens to touch it.
        #
        # @param classes [Array<Class>, nil] defaults to every
        #   Parse::Object subclass carrying `:vector` properties.
        # @param strict [Boolean] when true, an unregistered provider
        #   is itself a failure; otherwise those bindings are skipped
        #   (a provider may be registered later in boot).
        # @return [Array<String>] human-readable problems, empty when clean.
        def audit_all!(classes: nil, strict: false)
          problems = []
          begin
            bindings = collect_bindings(classes)
          rescue DiscoveryFailed => e
            return [e.message]
          end

          bindings.each do |klass, field, declared|
            provider_name = declared[:provider]
            next if provider_name.nil?

            begin
              provider = Parse::Embeddings.provider(provider_name)
            rescue Parse::Embeddings::ProviderNotRegistered => e
              problems << "#{klass}##{field}: #{e.message}" if strict
              next
            end

            begin
              check!(klass, field, provider, declared)
            rescue BindingMismatch => e
              problems << e.message
            end
          end
          problems
        end

        # {.audit_all!} that raises instead of returning problems.
        #
        # @raise [BindingMismatch] when any binding disagrees.
        # @return [void]
        def audit_all_or_raise!(classes: nil, strict: false)
          problems = audit_all!(classes: classes, strict: strict)
          return if problems.empty?

          raise BindingMismatch,
                "Parse::Embeddings binding audit failed:\n  - #{problems.join("\n  - ")}"
        end

        # Retained as a no-op for callers that invoked it when this
        # module memoized verdicts.
        # @return [void]
        def reset!
          nil
        end

        private

        # Read a provider accessor, distinguishing "not implemented"
        # from a legitimate nil. Returns `:unavailable` for the former
        # so {#check!} can fail closed rather than skip the comparison.
        def accessor(provider, method)
          value = provider.public_send(method)
          value.nil? ? :unavailable : value
        rescue NotImplementedError, NoMethodError
          :unavailable
        end

        def check!(klass, field, provider, declared)
          declared_model = declared[:model]
          if declared_model
            actual_model = accessor(provider, :model_name)
            # A declaration states a requirement. A provider that cannot
            # answer what model it runs cannot satisfy it, so this fails
            # closed — otherwise a custom provider without `model_name`
            # would write same-width embeddings that are never checked
            # against the declaration at all.
            if actual_model == :unavailable
              raise BindingMismatch,
                    "#{klass}##{field} declares model: #{declared_model.inspect} but the " \
                    "provider registered as #{declared[:provider].inspect} " \
                    "(#{provider.class}) does not report a usable #model_name, so the " \
                    "binding cannot be verified. Implement #model_name on the provider, " \
                    "or drop `model:` from the property to opt out of the check."
            end
            if declared_model.to_s != actual_model.to_s
              raise BindingMismatch,
                    "#{klass}##{field} declares model: #{declared_model.inspect} but the " \
                    "provider registered as #{declared[:provider].inspect} is running " \
                    "#{actual_model.inspect}. Vectors from different models are not " \
                    "comparable; embedding with the current provider would corrupt this " \
                    "index. Update the declaration and re-embed, or register the declared " \
                    "model."
            end
          end

          declared_dims = declared[:dimensions]
          if declared_dims
            actual_dims = accessor(provider, :dimensions)
            if actual_dims == :unavailable
              raise BindingMismatch,
                    "#{klass}##{field} declares dimensions: #{declared_dims} but the " \
                    "provider registered as #{declared[:provider].inspect} " \
                    "(#{provider.class}) does not report a usable #dimensions, so the " \
                    "binding cannot be verified. #dimensions is required by the provider " \
                    "protocol."
            end
            if declared_dims != actual_dims
              raise BindingMismatch,
                    "#{klass}##{field} declares dimensions: #{declared_dims} but the provider " \
                    "registered as #{declared[:provider].inspect} emits #{actual_dims}-dim " \
                    "vectors. Fix the declaration or configure the provider's width before " \
                    "embedding."
            end
          end
          nil
        end

        def collect_bindings(classes)
          list = classes || default_classes
          list.flat_map do |klass|
            next [] unless klass.respond_to?(:vector_properties)
            klass.vector_properties.map { |field, declared| [klass, field, declared] }
          end
        end

        # Discovery must NOT swallow its own failure: an empty list from
        # a crashed sweep is indistinguishable from a clean audit, so
        # `audit_all_or_raise!` would report success having checked
        # nothing. Failures propagate as {DiscoveryFailed} and
        # {.audit_all!} converts them into a reported problem.
        def default_classes
          return [] unless defined?(Parse::Object)
          ObjectSpace.each_object(Class).select do |k|
            k < Parse::Object && k.respond_to?(:vector_properties) &&
              !k.vector_properties.empty?
          end
        rescue StandardError => e
          raise DiscoveryFailed,
                "Parse::Embeddings::BindingAudit could not enumerate Parse::Object " \
                "subclasses (#{e.class}: #{e.message}); the audit checked nothing. " \
                "Pass `classes:` explicitly to audit a known set."
        end
      end
    end
  end
end
