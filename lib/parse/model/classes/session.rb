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
      # @return [Session] the session for this token, otherwise nil.
      def session(token, **opts)
        response = client.fetch_session(token, opts)
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
  end
end
