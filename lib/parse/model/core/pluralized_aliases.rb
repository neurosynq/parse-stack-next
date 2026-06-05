# encoding: UTF-8
# frozen_string_literal: true

module Parse
  # Global `const_missing` hook that lazily resolves the plural form of a
  # {Parse::Object} subclass constant to that class. Referencing `Posts`
  # when a class `Post` exists installs `Posts` as an alias for `Post` on
  # the referencing module and returns it, so query entry points like
  # `Posts.where(...).count` work without any per-model boilerplate.
  #
  # The hook is prepended onto `Module` so it applies to constant lookups
  # in any namespace (top-level and nested). It is tightly guarded: every
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
