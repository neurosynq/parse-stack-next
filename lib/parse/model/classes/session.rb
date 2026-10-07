# encoding: UTF-8
# frozen_string_literal: true
# Note: Do not require "../object" here - this file is loaded from object.rb
# and adding that require would create a circular dependency.

module Parse
  # This class represents the data and columns contained in the standard Parse
  # `_Session` collection. The Session class maintains per-device (or website) authentication
  # information for a particular user. Whenever a User object is logged in, a new Session record, with
  # a session token is generated. You may use a known active session token to find the corresponding
  # user for that session. Deleting a Session record (and session token), effectively logs out the user, when making Parse requests
  # on behalf of the user using the session token.
  #
  # The default schema for the {Session} class is as follows:
  #   class Parse::Session < Parse::Object
  #      # See Parse::Object for inherited properties...
  #
  #      property :session_token
  #      property :created_with, :object
  #      property :expires_at, :date
  #      property :installation_id
  #      property :restricted, :boolean
  #
  #      belongs_to :user
  #
  #      # Installation where the installation_id matches.
  #      has_one :installation, ->{ where(installation_id: i.installation_id) }, scope_only: true
  #   end
  #
  # @note CLP on `_Session` is mostly redundant: non-master `find` queries
  #   are silently rewritten by Parse Server's REST layer
  #   (`RestQuery.js`) to scope by `user = <current user>`, so a caller
  #   never sees another user's sessions regardless of CLP. `find` also
  #   requires a session token. You cannot grant cross-user session
  #   visibility through {Parse::Object.set_clp}.
  #
  # @see Parse::Object
  class Session < Parse::Object
    parse_class Parse::Model::CLASS_SESSION

    # @!attribute created_with
    # @return [Hash] data on how this Session was created.
    property :created_with, :object

    # @!attribute expires_at
    # @return [Parse::Date] when the session token expires.
    property :expires_at, :date

    # @!attribute installation_id
    # @return [String] The installation id from the Installation table.
    # @see Installation#installation_id
    property :installation_id

    # @!attribute [r] restricted
    # @return [Boolean] whether this session token is restricted.
    property :restricted, :boolean

    # @!attribute [r] session_token
    #  @return [String] the session token for this installation and user pair.
    property :session_token
    # @!attribute [r] user
    #  This property is mapped as a `belongs_to` association with the {Parse::User}
    #  class. Every session instance is tied to a specific logged in user.
    #  @return [User] the user corresponding to this session.
    #  @see User
    belongs_to :user

    # @!attribute [r] installation
    # Returns the {Parse::Installation} where the sessions installation_id field matches the installation_id field
    # in the {Parse::Installation} collection. This is implemented as a has_one scope.
    # @version 1.7.1
    # @return [Parse::Installation] The associated {Parse::Installation} tied to this session
    has_one :installation, -> { where(installation_id: i.installation_id) }, scope_only: true

    # =========================================================================
    # Session Management - Class Methods
    # =========================================================================

    class << self
      # Return the Session record for this session token.
      # @param token [String] the session token
      # @param opts [Hash] additional keyword options forwarded to the
      #   underlying client request (e.g. `cache: false`,
      #   `use_master_key: false`, `headers:`).
      # @return [Session] the session for this token, otherwise nil.
      def session(token, **opts)
        # A stray :session_token in opts would be forwarded into the request
        # stack and silently override the positional token argument. Drop it
        # so the explicit token always wins.
        opts.delete(:session_token)
        response = client.fetch_session(token, **opts)
        if response.success?
          return Parse::Session.build response.result
        end
        nil
      end

      # Query scope for active (non-expired) sessions.
      # @return [Parse::Query] a query for sessions that haven't expired
      # @example
      #   active_sessions = Parse::Session.active.all
      def active
        query(:expires_at.gte => Time.now)
      end

      # Query scope for expired sessions.
      # @return [Parse::Query] a query for sessions that have expired
      # @example
      #   expired_sessions = Parse::Session.expired.all
      def expired
        query(:expires_at.lt => Time.now)
      end

      # Query scope for sessions belonging to a specific user.
      # @param user [Parse::User, Parse::Pointer, String] the user or user ID
      # @return [Parse::Query] a query for the user's sessions
      # @example
      #   user_sessions = Parse::Session.for_user(user).all
      def for_user(user)
        user = Parse::User.pointer(user) if user.is_a?(String)
        query(user: user)
      end

      # Revoke (delete) all sessions for a specific user.
      # @param user [Parse::User, Parse::Pointer, String] the user or user ID
      # @param except [String] optional session token to exclude from revocation
      # @return [Integer] the number of sessions revoked
      # @example
      #   # Revoke all sessions for a user
      #   Parse::Session.revoke_all_for_user(user)
      #
      #   # Revoke all except current session
      #   Parse::Session.revoke_all_for_user(user, except: current_session_token)
      def revoke_all_for_user(user, except: nil)
        sessions = for_user(user)
        sessions = sessions.where(:session_token.ne => except) if except
        sessions_to_revoke = sessions.all
        sessions_to_revoke.each(&:destroy)
        sessions_to_revoke.count
      end

      # Count active sessions for a specific user.
      # @param user [Parse::User, Parse::Pointer, String] the user or user ID
      # @return [Integer] count of active sessions
      # @example
      #   count = Parse::Session.active_count_for_user(user)
      def active_count_for_user(user)
        for_user(user).where(:expires_at.gte => Time.now).count
      end
    end

    # =========================================================================
    # Session Management - Instance Methods
    # =========================================================================

    # Check if this session has expired.
    # @return [Boolean] true if the session has expired
    # @example
    #   if session.expired?
    #     puts "Session has expired"
    #   end
    def expired?
      return false if expires_at.nil?
      expires_at < Time.now
    end

    # Check if this session is still valid (not expired).
    # @return [Boolean] true if the session is still valid
    # @example
    #   if session.valid?
    #     puts "Session is still active"
    #   end
    def valid?
      !expired?
    end

    # Get the remaining time until this session expires.
    # @return [Float, nil] seconds remaining until expiration, nil if no expiration, 0 if already expired
    # @example
    #   remaining = session.time_remaining
    #   puts "Session expires in #{remaining / 3600} hours" if remaining
    def time_remaining
      return nil if expires_at.nil?
      remaining = expires_at.to_time - Time.now
      remaining > 0 ? remaining : 0
    end

    # Check if this session expires within the given duration.
    # @param duration [Integer] number of seconds
    # @return [Boolean] true if session expires within the duration
    # @example
    #   if session.expires_within?(1.hour)
    #     puts "Session expires soon!"
    #   end
    def expires_within?(duration)
      return false if expires_at.nil?
      expires_at < (Time.now + duration)
    end

    # Revoke (delete) this session, effectively logging out the user on this device.
    # @return [Boolean] true if successfully revoked
    # @example
    #   session.revoke!
    def revoke!
      destroy
    end

    # Deletes the session and forgets it in the client's identity plane, so
    # mongo-direct and Atlas Search reads stop resolving the token at once
    # instead of when the cached entry expires. Both the token and the owning
    # user's entries are dropped. A session that does not carry them (built
    # from its objectId, or fetched without the master key or with `keys:`
    # leaving them out) has them looked up first: with the master key as SDK
    # metadata when the client has one, otherwise with the `session:` passed
    # here. A lookup that finds no row leaves nothing to forget. Only a
    # lookup that fails outright drops every cached identity on the client,
    # at most once every {RESET_INTERVAL} seconds per client.
    #
    # The entries are dropped when the delete succeeds or reports the row
    # is already gone (or not visible to the caller). A delete that raises
    # still drops the known token, which is harmless, but does not touch the
    # owner's entries.
    #
    # A batch delete through `Array#destroy` drops the same entries for
    # each session in it. With an identity plane that cannot drop a
    # single user's entries (a custom plane without `bump_generation` or
    # `invalidate_value`), a revoked token keeps resolving until its cached
    # entry expires.
    # @param session [String] (see Parse::Object#destroy)
    # @return [Boolean] whether the operation was successful.
    def destroy(session: nil)
      # A session never saved is not deleted (see Parse::Object#destroy), so
      # there is nothing to forget either.
      return super if new?
      begin
        Parse::Session.send(:_preload_identity_for_destroy!, [self], session_token: session)
        token, owner_id = _identity_for_destroy
      ensure
        # The looked-up token is a live credential: keep it in locals only.
        _clear_identity_for_destroy!
      end
      result = nil
      begin
        result = super
      ensure
        # `false` covers "object not found", which is either a session
        # already revoked elsewhere or one the caller cannot see; dropping
        # cached entries is idempotent in both cases. A raised delete still
        # drops the token it named but leaves the owner alone.
        if result.nil?
          _forget_identity!(token == :unknown ? nil : token, nil)
        else
          _forget_identity!(token, owner_id)
        end
      end
    end

    # Seconds between two full identity-cache resets triggered by a failed
    # session lookup on the same client.
    RESET_INTERVAL = 5

    # Process-local record of the last lookup-triggered reset per client.
    @identity_reset_at = {}
    @identity_reset_mutex = Mutex.new

    class << self
      private

      # Reset `cl`'s identity and role caches, at most once every
      # {RESET_INTERVAL} seconds per client.
      # @!visibility private
      def _rate_limited_identity_reset!(cl)
        auth = cl.respond_to?(:authorization) ? cl.authorization : nil
        return unless auth.respond_to?(:reset_caches!)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        due = @identity_reset_mutex.synchronize do
          last = @identity_reset_at[cl.object_id]
          next false if last && now - last < RESET_INTERVAL
          @identity_reset_at[cl.object_id] = now
          true
        end
        auth.reset_caches! if due
      end

      # Look up the token and owner of every session about to be deleted that
      # does not carry them, so the delete can drop their identity entries.
      # One `_Session` query per client. A client with a master key reads it
      # as SDK metadata (it works inside `Parse.without_master_key`); one
      # without reads it with `session_token`, or skips the lookup when there
      # is none. The query never uses the response cache: its rows carry live
      # session tokens.
      #
      # A row the lookup did not return is marked absent: there is nothing
      # to forget for it. Only a lookup that raised marks its sessions
      # `:unknown`, which makes their delete reset the client's identity
      # cache (rate limited).
      # @param sessions [Array<Parse::Object>]
      # @param session_token [String, nil] the delete's own session.
      # @!visibility private
      def _preload_identity_for_destroy!(sessions, session_token: nil)
        pending = sessions.select { |o| o.is_a?(Parse::Session) && o.send(:_identity_lookup_needed?) }
        return if pending.empty?
        pending.group_by(&:client).each do |cl, group|
          has_master = cl.respond_to?(:master_key) && cl.master_key.present?
          token = session_token.respond_to?(:session_token) ? session_token.session_token : session_token
          token = nil unless token.is_a?(String) && !token.strip.empty?
          unless has_master || token
            group.each { |o| o.instance_variable_set(:@_identity_for_destroy, :absent) }
            next
          end
          ids = group.map(&:id).uniq
          found = begin
              query = Parse::Session.query(:objectId.in => ids, limit: ids.size)
              query.keys(:session_token, :user)
              query.client = cl
              query.cache = false
              if has_master
                query.instance_variable_set(:@_metadata_master, true)
              else
                query.session_token = token
              end
              query.results.to_h do |row|
                owner = row.instance_variable_get(:@user)
                [row.id, [row.instance_variable_get(:@session_token), owner.respond_to?(:id) ? owner.id : nil]]
              end
            rescue StandardError => e
              warn "[Parse::Session] could not look up the token and owner of " \
                   "#{ids.size} session(s) before deleting them (#{e.class}); " \
                   "dropping the whole identity cache instead."
              nil
            end
          group.each do |o|
            mark = if found.nil?
                :unknown
              elsif (row = found[o.id]) && (row[0].is_a?(String) || row[1])
                row
              else
                :absent
              end
            o.instance_variable_set(:@_identity_for_destroy, mark)
          end
        end
      end
    end

    # Called by `Array#destroy` for each session in the batch with its
    # response. The entries are dropped only when the delete succeeded or
    # reported the row gone ("object not found").
    # @!visibility private
    def _after_batch_destroy(response = nil)
      identity = _identity_for_destroy
      _clear_identity_for_destroy!
      _forget_identity!(*identity) if Parse::Session.send(:_destroy_applied?, response)
    end
    private :_after_batch_destroy

    # Whether a batch delete response means the row is gone: success, or
    # "object not found". A missing response (older callers) counts as
    # applied.
    # @!visibility private
    def self._destroy_applied?(response)
      return true if response.nil?
      (response.respond_to?(:success?) && response.success?) ||
        (response.respond_to?(:object_not_found?) && response.object_not_found?)
    end
    private_class_method :_destroy_applied?

    # Remove the token and owner {._preload_identity_for_destroy!} looked
    # up. The token is a live credential and must not outlive the delete
    # (it would show in `inspect` or `instance_variables`).
    # @!visibility private
    def _clear_identity_for_destroy!
      remove_instance_variable(:@_identity_for_destroy) if instance_variable_defined?(:@_identity_for_destroy)
    end
    private :_clear_identity_for_destroy!

    # Whether this session lacks the token or the owner its identity-plane
    # entries are keyed by: a fetch without the master key (no token) or
    # with `keys:` leaving them out.
    # @!visibility private
    def _identity_lookup_needed?
      # Keyed on the objectId, not `new?`: `Array#destroy` deletes by id
      # alone, so a session built from an id (no timestamps loaded) is still
      # deleted and its token must still be dropped.
      return false if @id.blank?
      !@session_token.is_a?(String) || @session_token.empty? || _identity_owner_id.nil?
    end
    private :_identity_lookup_needed?

    # Serialization omits `sessionToken` unless `include_session_token: true`
    # is passed. A session token is a bearer credential, and `as_json` is the
    # surface that reaches logs, API responses and agent tool output.
    # @param opts [Hash] see Parse::Object#as_json.
    # @option opts [Boolean] :include_session_token include the token.
    # @return [Hash]
    def as_json(opts = nil)
      opts = (opts || {}).dup
      include_token = opts.delete(:include_session_token) == true
      json = super(opts)
      return json if include_token || !json.is_a?(Hash)
      json.except("session_token", "sessionToken", :session_token, :sessionToken)
    end

    # Redacts the session token from the default inspect output.
    # @return [String]
    def inspect
      looked_up = @_identity_for_destroy
      Parse::User.redact_session_token(super, @session_token, looked_up.is_a?(Array) ? looked_up[0] : nil)
    end

    private

    # The token and owner id to forget for this delete: what this instance
    # carries, completed by {._preload_identity_for_destroy!} when it did
    # not, or `:unknown` when that lookup failed.
    # @!visibility private
    def _identity_for_destroy
      looked_up = @_identity_for_destroy
      token = @session_token.is_a?(String) && !@session_token.empty? ? @session_token : nil
      owner_id = _identity_owner_id
      return [:unknown, owner_id] if looked_up == :unknown
      return [token, owner_id] if looked_up == :absent
      if looked_up.is_a?(Array)
        token ||= looked_up[0]
        owner_id ||= looked_up[1]
      end
      [token, owner_id]
    end

    # The owning user's id, read from the association ivar directly:
    # calling `user` on a partially fetched session could trigger an
    # autofetch just to learn the owner.
    # @!visibility private
    def _identity_owner_id
      owner = @user
      owner.respond_to?(:id) ? owner.id : nil
    end

    # Drop the token and the owner's entries from this session's client's
    # identity plane.
    # @!visibility private
    def _forget_identity!(token, owner_id)
      cl = client
      if token == :unknown
        # The lookup failed, so the token's entry cannot be named. Drop every
        # cached identity on this client (the next read of each token
        # re-resolves it, which is safe), at most once every RESET_INTERVAL
        # seconds so repeated failures cannot flush a shared plane on every
        # request. The owner's entries go as well when the owner is known.
        Parse::Session.send(:_rate_limited_identity_reset!, cl)
        token = nil
      end
      cl.invalidate_session_identity(token) if token.is_a?(String) && cl.respond_to?(:invalidate_session_identity)
      cl.invalidate_user_identity(owner_id) if owner_id && cl.respond_to?(:invalidate_user_identity)
    rescue StandardError
      # Runs from an `ensure`: never replace the delete's own outcome.
      nil
    end
  end
end
