# encoding: UTF-8
# frozen_string_literal: true

require "set"
require_relative "../clp_scope"
require_relative "../authorization"

module Parse
  module AtlasSearch
    # Compatibility shim over {Parse::Authorization}.
    #
    # This module used to own session-token resolution, role-closure
    # expansion, and both caches. It no longer does. Deciding who a caller is
    # and what they may read is authorization infrastructure that Atlas
    # Search consumes, not infrastructure Atlas Search owns, and the old
    # arrangement meant `Parse::Query#results_direct` on a query with no
    # `$search` in it went through `Parse::ACLScope` into this namespace to
    # find out who was asking. See {Parse::Authorization} for the reasoning
    # and for the real implementation.
    #
    # Everything here now delegates to the default client's authorization
    # context. That is the one behavior difference worth knowing: these
    # methods take no `client:`, so they can only ever address
    # `Parse.client`. Code running against a secondary application should
    # call `other_client.authorization` directly.
    #
    # Slated for removal in 6.0.
    module Session
      # @deprecated Use {Parse::Authorization::InvalidSession}. Kept as the
      #   same object rather than a subclass so existing `rescue
      #   Parse::AtlasSearch::Session::InvalidSession` clauses still catch
      #   what the resolver actually raises.
      InvalidSession = Parse::Authorization::InvalidSession

      # @deprecated Use {Parse::Authorization::MemoryCache}.
      MemoryCache = Parse::Authorization::MemoryCache

      # @deprecated Use {Parse::Authorization::Resolved}.
      Resolved = Parse::Authorization::Resolved

      class << self
        # @deprecated Use `client.authorization.resolve(token)`, or
        #   {Parse::Authorization.resolve} with an explicit `client:`.
        # @return [Parse::Authorization::Resolved]
        def resolve(session_token)
          context.resolve(session_token)
        end

        # @deprecated Use `client.authorization.invalidate(token)`. Note that
        #   `Parse::Cache::Invalidation` now does this automatically from the
        #   `_Session` `after_logout` trigger, so an application no longer has
        #   to remember to call it from its own logout path.
        def invalidate(session_token)
          context.invalidate(session_token)
        end

        # @deprecated Use `client.authorization.invalidate_user_roles(id)`.
        def invalidate_user_roles(user_id)
          context.invalidate_user_roles(user_id)
        end

        # @deprecated Use `client.authorization.reset_caches!`.
        def reset_caches!
          context.reset_caches!
        end

        private

        def context
          Parse.client.authorization
        end
      end
    end
  end
end
