# encoding: UTF-8
# frozen_string_literal: true

module Parse
  # Global `const_missing` hook that lazily resolves the plural form of a
  # {Parse::Object} subclass constant to that class. Referencing `Posts`
  # when a class `Post` exists installs `Posts` as an alias for `Post` and
  # returns it, so query entry points like
  # `Posts.where(...).count` work without any per-model boilerplate.
  #
  # The hook is prepended onto `Module` so a plural reference resolves from
  # any namespace, but the alias constant is only ever installed in the
  # namespace that defines the singular class (`::Posts` for a top-level
  # `Post`, `Blog::Posts` for `Blog::Post`). A lookup from an unrelated
  # module never adds a constant to that module, and a frozen namespace is
  # skipped rather than raising `FrozenError`. It is tightly guarded: every
  # path that is not a plural-of-a-Parse-class falls through to `super`,
  # preserving normal `NameError` and autoloader (Zeitwerk/classic)
  # behavior. The whole feature is gated on {Parse.pluralized_aliases?} so
  # opting out (`Parse.pluralized_aliases = false`) makes this a near-zero
  # cost pass-through.
  #
  # @see Parse.pluralized_aliases
  # @see Parse.__pluralized_alias_for
  module PluralizedAliases
    def const_missing(name)
      klass = Parse.__pluralized_alias_for(self, name) if defined?(Parse)
      return klass unless klass.nil?
      super
    end
  end
end

Module.prepend(Parse::PluralizedAliases)
