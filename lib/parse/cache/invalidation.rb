# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Cache
    # Registers the webhook triggers that keep the identity and role planes
    # honest without relying on application discipline.
    #
    # Before this, the documented contract asked applications to call
    # `Session.invalidate` and `invalidate_user_roles` from their own logout and
    # role-mutation paths. That depends on every application remembering, and it
    # misses role changes made by any other client: a mobile SDK, the dashboard,
    # or Node cloud code. Registering our own triggers moves the responsibility
    # to the SDK and covers writes from every source Parse Server sees.
    #
    #   Parse::Cache::Invalidation.install!(cache)
    #
    # The TTL remains the backstop. These triggers require the application to
    # run a webhook endpoint Parse Server can reach and to have registered the
    # hooks; unregistered or unreachable, the TTL is the only bound on
    # staleness. TTL *and* hooks, not TTL or hooks.
    module Invalidation
      # Classes we register against, exposed for tests and diagnostics.
      # Literal class names rather than Parse::Model constants: this file is
      # required from Parse::Client before Parse::Model is defined, and these
      # are fixed Parse Server protocol names, not app-domain classes.
      USER_CLASS = "_User"
      SESSION_CLASS = "_Session"
      ROLE_CLASS = "_Role"

      TRIGGERS = {
        role: [[:after_save, ROLE_CLASS], [:after_delete, ROLE_CLASS]],
        identity: [[:after_save, USER_CLASS],
                   [:after_delete, USER_CLASS],
                   [:after_logout, SESSION_CLASS]],
      }.freeze

      class << self
        # Install the triggers for a cache exposing `roles` and `identity`
        # planes.
        #
        # @param cache [Parse::Cache::Redis] a keyspace-configured cache.
        # @return [Array<Array>] the routes registered.
        def install!(cache)
          unless cache.respond_to?(:roles) && cache.respond_to?(:identity)
            raise ArgumentError,
                  "Parse::Cache::Invalidation requires a cache with role and identity planes"
          end
          registered = []
          registered.concat(install_role_triggers!(cache))
          registered.concat(install_identity_triggers!(cache))
          registered
        end

        private

        def install_role_triggers!(cache)
          TRIGGERS[:role].map do |(type, class_name)|
            Parse::Webhooks.route(type, class_name) do |payload|
              guard do
                # A role write does not say which users are affected: membership
                # and hierarchy changes arrive as relation deltas on `users` and
                # `roles`, and the cached value is a flattened transitive closure,
                # so a parent-role change reaches the members of every child.
                # Clearing the whole plane is both correct and cheap under a
                # scoped SCAN. Parse Server does the same, for the same reason.
                cache.roles.clear
                # Stamp the epoch so a *foreign* role entry written before this
                # moment is rejected on read. Parse Server does not clear its own
                # role cache on a `_Role` delete, so without this the next read
                # would take its stale entry back and our clear would shorten
                # revocation by nothing.
                cache.roles.touch_epoch
              end
              true
            end
            [type, class_name]
          end
        end

        def install_identity_triggers!(cache)
          TRIGGERS[:identity].map do |(type, class_name)|
            Parse::Webhooks.route(type, class_name) do |payload|
              guard do
                case type
                when :after_logout
                  # The only trigger Parse Server permits on `_Session`. The
                  # object's own sessionToken is scrubbed from the payload, but
                  # the token is captured from the requesting user before
                  # scrubbing, and for a logout that user *is* the session being
                  # ended. A master-key logout carries no user, so fall back to
                  # the generation bump.
                  #
                  # Pass the RAW token, not a pre-hashed digest.
                  # `Parse::Cache::SubCache#invalidate` hashes its `key`
                  # argument internally for the `:idn` family (see
                  # `SubCache#logical_key`), the same way `#get` / `#set` do —
                  # that is what makes a `set(raw_token, ...)` /
                  # `get(raw_token)` pair round-trip. Hashing here first and
                  # handing SubCache an already-hashed value made it hash the
                  # digest a second time, landing on a key nothing had ever
                  # written to, so logout silently failed to evict the entry.
                  token = payload.respond_to?(:session_token) ? payload.session_token : nil
                  if token && !token.to_s.empty?
                    cache.identity.invalidate(token.to_s)
                  else
                    bump_subject(cache, subject_id(payload))
                  end
                else
                  # A `_User` write gives a user id, but identity entries are
                  # keyed by session token and no reverse map exists. Bumping a
                  # per-user generation invalidates every one of that user's
                  # entries in O(1), including tokens this process has never
                  # resolved, and without Parse Server's master-key `_Session`
                  # query.
                  bump_subject(cache, subject_id(payload))
                end
              end
              true
            end
            [type, class_name]
          end
        end

        # These triggers fire AFTER the write has committed, so raising here
        # turns an already-successful save into a 500 for the client. A cache
        # backend that is down must degrade to TTL-bounded staleness, never to
        # a failed application request. The error is reported without its
        # message, which can carry a key and therefore a session token.
        def guard
          yield
        rescue StandardError => e
          warn "[Parse::Cache::Invalidation] invalidation failed: #{e.class}"
          if defined?(ActiveSupport::Notifications)
            begin
              ActiveSupport::Notifications.instrument(
                "parse.cache.invalidation_error", error: e.class.name,
              )
            rescue StandardError
              nil
            end
          end
          nil
        end

        def bump_subject(cache, user_id)
          return if user_id.nil? || user_id.to_s.empty?
          cache.identity.bump_generation(user_id.to_s)
        end

        # The affected user's id. For a `_User` trigger that is the object
        # itself; for a session it is the session's user pointer.
        def subject_id(payload)
          object = payload.respond_to?(:parse_object) ? payload.parse_object : nil
          return nil if object.nil?
          if object.respond_to?(:id) && payload.respond_to?(:parse_class) &&
             payload.parse_class == USER_CLASS
            return object.id
          end
          user = object.respond_to?(:user) ? object.user : nil
          return user.id if user.respond_to?(:id)
          object.respond_to?(:id) ? object.id : nil
        end
      end
    end
  end
end
