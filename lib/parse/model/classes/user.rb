# encoding: UTF-8
# frozen_string_literal: true

# Note: Do not require "../object" here - this file is loaded from object.rb
# and adding that require would create a circular dependency.

require "securerandom"

module Parse
  class Error
    # 200	Error code indicating that the username is missing or empty.
    class UsernameMissingError < Error; end

    # 201	Error code indicating that the password is missing or empty.
    class PasswordMissingError < Error; end

    # Error code 202: indicating that the username has already been taken.
    class UsernameTakenError < Error; end

    # 203	Error code indicating that the email has already been taken.
    class EmailTakenError < Error; end

    # 204	Error code indicating that the email is missing, but must be specified.
    class EmailMissing < Error; end

    # 205	Error code indicating that a user with the specified email was not found.
    class EmailNotFound < Error; end

    # 125	Error code indicating that the email address was invalid.
    class InvalidEmailAddress < Error; end
  end

  # The main class representing the _User table in Parse. A user can either be signed up or anonymous.
  # All users need to have a username and a password, with email being optional but globally unique if set.
  # You may add additional properties by redeclaring the class to match your specific schema.
  #
  # The default schema for the {User} class is as follows:
  #
  #   class Parse::User < Parse::Object
  #      # See Parse::Object for inherited properties...
  #
  #      property :auth_data, :object
  #      property :username
  #      property :password
  #      property :email
  #
  #      has_many :active_sessions, as: :session
  #   end
  #
  # *Signup*
  #
  # You can signup new users in two ways. You can either use a class method
  # {Parse::User.signup} to create a new user with the minimum fields of username,
  # password and email, or create a {Parse::User} object can call the {#signup!}
  # method. If signup fails, it will raise the corresponding exception.
  #
  #  user = Parse::User.signup(username, password, email)
  #
  #  #or
  #  user = Parse::User.new username: "user", password: "s3cret"
  #  user.signup!
  #
  # *Login/Logout*
  #
  # With the {Parse::User} class, you can also perform login and logout
  # functionality. The class special accessors for {#session_token} and {#session}
  # to manage its authentication state. This will allow you to authenticate
  # users as well as perform Parse queries as a specific user using their session
  # token. To login a user, use the {Parse::User.login} method by supplying the
  # corresponding username and password, or if you already have a user record,
  # use {#login!} with the proper password.
  #
  #  user = Parse::User.login(username,password)
  #  user.session_token # session token from a Parse::Session
  #  user.session # Parse::Session tied to the token
  #
  #  # You can login user records
  #  user = Parse::User.first
  #  user.session_token # nil
  #
  #  passwd = 'p_n7!-e8' # corresponding password
  #  user.login!(passwd) # true
  #
  #  user.session_token # 'r:pnktnjyb996sj4p156gjtp4im'
  #
  #  # logout to delete the session
  #  user.logout
  #
  # If you happen to already have a valid session token, you can use it to
  # retrieve the corresponding Parse::User.
  #
  #  # finds user with session token
  #  user = Parse::User.session(session_token)
  #
  #  user.logout # deletes the corresponding session
  #
  # *OAuth-Login*
  #
  # You can signup users using third-party services like Facebook and Twitter as
  # described in {http://docs.parseplatform.org/rest/guide/#signing-up
  # Signing Up and Logging In}. To do this with Parse-Stack, you can call the
  # {Parse::User.autologin_service} method by passing the service name and the
  # corresponding authentication hash data. For a listing of supported third-party
  # authentication services, see {http://docs.parseplatform.org/parse-server/guide/#oauth-and-3rd-party-authentication OAuth}.
  #
  #  fb_auth = {}
  #  fb_auth[:id] = "123456789"
  #  fb_auth[:access_token] = "SaMpLeAAiZBLR995wxBvSGNoTrEaL"
  #  fb_auth[:expiration_date] = "2025-02-21T23:49:36.353Z"
  #
  #  # signup or login a user with this auth data.
  #  user = Parse::User.autologin_service(:facebook, fb_auth)
  #
  # You may also combine both approaches of signing up a new user with a
  # third-party service and set additional custom fields. For this, use the
  # method {Parse::User.create}.
  #
  #  # or to signup a user with additional data, but linked to Facebook
  #  data = {
  #    username: "johnsmith",
  #    name: "John",
  #    email: "user@example.com",
  #    authData: { facebook: fb_auth }
  #  }
  #  user = Parse::User.create data
  #
  # *Linking/Unlinking*
  #
  # You can link or unlink user accounts with third-party services like
  # Facebook and Twitter as described in:
  # {http://docs.parseplatform.org/rest/guide/#linking-users Linking and Unlinking Users}.
  # To do this, you must first get the corresponding authentication data for the
  # specific service, and then apply it to the user using the linking and
  # unlinking methods. Each method returns true or false if the action was
  # successful. For a listing of supported third-party authentication services,
  # see {http://docs.parseplatform.org/parse-server/guide/#oauth-and-3rd-party-authentication OAuth}.
  #
  #  user = Parse::User.first
  #
  #  fb_auth = { ... } # Facebook auth data
  #
  #  # Link this user's Facebook account with Parse
  #  user.link_auth_data! :facebook, fb_auth
  #
  #  # Unlinks this user's Facebook account from Parse
  #  user.unlink_auth_data! :facebook
  #
  # @see Parse::Object
  class User < Parse::Object
    parse_class Parse::Model::CLASS_USER

    # When true (default), saving a new {Parse::User} that has a `password`
    # value routes through Parse Server's signup endpoint (`POST /parse/users`)
    # with the `X-Parse-Revocable-Session` header set, so the signup response
    # returns a session token that is applied to the in-memory user object
    # via the standard `sessionToken_set_attribute!` hydration path. Without
    # this flag, `Parse::User.new(...).save!` left `session_token` `nil`
    # because the underlying create path did not request a revocable session.
    #
    # Set to `false` to always create users without requesting a revocable
    # session token - for example, when a master-key server-side script is
    # provisioning user rows that will receive credentials later. New users
    # created with no password always fall through to the standard create
    # path regardless of this flag.
    #
    # `auth_data` (federated identity / OAuth) signup is deliberately NOT
    # triggered by this flag. `POST /parse/users` treats `auth_data` as a
    # claim against an existing account, so allowing mass-assigned `auth_data`
    # to trigger a revocable-session signup would let attacker-controlled
    # params plant another user's session token onto the in-memory object.
    # Use {.autologin_service} or {.signup} (the explicit class methods) for
    # OAuth-driven signup; both bypass the mass-assignment filter because the
    # caller is explicitly choosing the federated-identity flow.
    #
    # Inherited through subclasses via {ActiveSupport::Concern}'s
    # `class_attribute`, so an application-specific subclass may override
    # the default without affecting `Parse::User` itself.
    #
    # @return [Boolean]
    class_attribute :signup_on_save, instance_writer: false
    self.signup_on_save = true

    # @return [String] The session token if this user is logged in.
    attr_reader :session_token

    # @!attribute auth_data
    # The auth data for this Parse::User. Depending on how this user is authenticated or
    # logged in, the contents may be different, especially if you are using another third-party
    # authentication mechanism like Facebook/Twitter.
    # @return [Hash] Auth data hash object.
    property :auth_data, :object

    # @!attribute email
    # Emails are optional in Parse, but if set, they must be unique.
    # @return [String] The email field.
    property :email

    # @overload password=(value)
    # You may set a password for this user when you are creating them. Parse never returns a
    # Parse::User's password when a record is fetched. Therefore, normally this getter is nil.
    # While this API exists, it is recommended you use either the #login! or #signup! methods.
    # (see #login!)
    # @return [String] The password you set.
    property :password

    # @!attribute username
    # All Parse users have a username and must be globally unique.
    # @return [String] The user's username.
    property :username

    # @!attribute email_verified
    # Whether this user's email address has been verified. Set by Parse Server
    # when the user follows the verification link delivered by the email
    # adapter, and applied to the in-memory object by {#signup!} / signup-on-save
    # when the server includes it in the signup response (see
    # +SIGNUP_RESPONSE_APPLY_KEYS+).
    # @return [Boolean]
    property :email_verified, :boolean

    # @!attribute active_sessions
    # A has_many relationship to all {Parse::Session} instances for this user. This
    # will query the _Session collection for all sessions which have this user in it's `user`
    # column.
    # @version 1.7.1
    # @return [Array<Parse::Session>] A list of active Parse::Session objects.
    has_many :active_sessions, as: :session

    # @!attribute installations
    # A `has_many` query-form association resolving to all
    # {Parse::Installation} records whose `user` pointer is this user.
    # Useful for targeted push — e.g. sending a notification to every
    # device the user is signed into. This is a query (no column is
    # stored on `_User`); each access issues a `find` against
    # `_Installation` for `where(user: self)`.
    #
    # **Requires a master-key client.** Parse Server hardcodes
    # `_Installation` `find` to master-key-only at the REST layer, so
    # this association will return an empty array (or fail-closed
    # depending on agent scope) under a session-token-only / sessionless
    # client. The `user` pointer is also not a reliable owner identity
    # — devices outlive sessions and can change users — see
    # {Parse::Installation} for the full caveat list.
    # @return [Array<Parse::Installation>]
    has_many :installations, as: :installation

    # CHANGE -- ACLs can be managed
    # before_save do
    #   # You cannot specify user ACLs.
    #   self.clear_attribute_change!([:acl])
    # end

    # `emailVerified` is server-controlled: Parse Server flips it when the
    # user follows the verification link, and only master-key callers (e.g.
    # a `beforeSignUp` cloud function approving an internal email domain)
    # are meant to set it explicitly. Client writes from any platform —
    # this Ruby SDK, iOS, JS, etc. — are silently reverted at the
    # `_User.beforeSave` webhook boundary.
    #
    # This complements the SDK-side {SERVER_CONTROLLED_KEYS} strip
    # ({strip_server_controlled_keys!}), which removes the field from
    # outbound signup/create bodies before the request leaves the SDK.
    # The guard is the cross-client backstop and only runs when the
    # deployment has the Parse Server webhook callback wired to a Ruby app
    # running the `Parse::Webhooks` middleware. Reads are unaffected — a
    # logged-in user can still see their own `email_verified` flag.
    guard :email_verified, :master_only

    # @!visibility private
    # Thread-local key used by {.with_authdata_trust} to mark the
    # current hydration as a legitimate self-fetch (login/signup/MFA/
    # `/users/me`). Outside that scope, {#apply_attributes!} strips
    # +authData+ from incoming server JSON so a `_User` query/find that
    # crosses ACL boundaries cannot leak another user's federated-identity
    # tokens into the in-memory object.
    AUTHDATA_TRUST_KEY = :__parse_stack_user_authdata_trusted

    class << self
      # @!visibility private
      # Run +block+ in a scope where the next {Parse::User#apply_attributes!}
      # call is permitted to hydrate +authData+ from the response. Used by
      # +login+/+login!+/+session!+/+create+/+link_auth_data!+/MFA paths
      # where the row being hydrated is provably the authenticating user.
      def with_authdata_trust
        prior = Thread.current[AUTHDATA_TRUST_KEY]
        Thread.current[AUTHDATA_TRUST_KEY] = true
        begin
          yield
        ensure
          Thread.current[AUTHDATA_TRUST_KEY] = prior
        end
      end

      # @!visibility private
      # True iff the calling thread is currently inside a
      # {.with_authdata_trust} scope.
      def authdata_trusted?
        Thread.current[AUTHDATA_TRUST_KEY] == true
      end

      # =========================================================================
      # Field-visibility DSL for _User
      # =========================================================================
      #
      # `_User` has two field-visibility flavors that vanilla
      # {Parse::Object.protect_fields} can't express on its own because
      # Parse Server's `protectedFieldsOwnerExempt` option special-cases
      # the owning user (the user sees their own row in full unless the
      # option is disabled). These helpers wrap that pattern.
      #
      # ## Prerequisites
      #
      # 1. Set `protectedFieldsOwnerExempt: false` in your Parse Server
      #    startup options. With the default `true`, the owning user is
      #    silently exempted from every `protectedFields` rule on `_User`,
      #    so {.master_only_fields} would still be visible to the user
      #    themselves.
      # 2. For {.self_visible_fields}: add a self-pointer field on `_User`
      #    that points to the same user, and maintain it from a
      #    `beforeSave('_User')` Cloud Code trigger:
      #
      #    ```js
      #    Parse.Cloud.beforeSave(Parse.User, (req) => {
      #      const u = req.object;
      #      if (!u.get('self')) u.set('self', u);  // self-pointer
      #    });
      #    ```
      #
      # The SDK cannot install either of those — they're server-side
      # configuration — but the helpers below will warn if they detect
      # they're being mis-applied.

      # Hide one or more fields from query/get responses for **all**
      # non-master callers, including the owning user themselves.
      # Useful for admin-only metadata living on `_User`
      # (e.g. internal scoring, moderation notes).
      #
      # Requires Parse Server option `protectedFieldsOwnerExempt: false`.
      # With the default `true`, the owning user still sees these fields
      # on their own row.
      #
      # @param fields [Array<Symbol,String>] field names. Use snake_case
      #   Ruby property names; they're auto-converted to camelCase.
      # @return [Array<Symbol>] full master-only field list after this call.
      # @example
      #   class Parse::User
      #     property :my_opinion_of_them, :string
      #     master_only_fields :my_opinion_of_them
      #   end
      def master_only_fields(*fields)
        @master_only_fields ||= []
        @master_only_fields = (@master_only_fields + fields.flatten.map(&:to_sym)).uniq
        _warn_about_owner_exempt_prereq!
        _rebuild_user_protected_fields!
        @master_only_fields.dup
      end

      # Hide one or more fields from public/role/other-user callers, but
      # allow the **owning user** to see them. Useful for private profile
      # data that belongs to the user (e.g. preferences, private notes).
      #
      # Requires:
      # * Parse Server option `protectedFieldsOwnerExempt: false`.
      # * A self-pointer field on `_User` (named via `via:`, default
      #   `:self`) that is set to the row's own pointer by a
      #   `beforeSave('_User')` Cloud Code trigger.
      #
      # @param fields [Array<Symbol,String>] field names. snake_case OK.
      # @param via [Symbol,String] name of the self-pointer field on
      #   `_User` (default `:self`).
      # @return [Array<Symbol>]
      # @example
      #   class Parse::User
      #     property :favorite_color, :string
      #     self_visible_fields :favorite_color, via: :self
      #   end
      def self_visible_fields(*fields, via: :self)
        @self_visible_fields ||= []
        @self_visible_fields = (@self_visible_fields + fields.flatten.map(&:to_sym)).uniq
        @self_pointer_field = via.to_sym
        _warn_about_owner_exempt_prereq!
        _warn_about_self_pointer_prereq!(via)
        _rebuild_user_protected_fields!
        @self_visible_fields.dup
      end

      # Override {Parse::Object.protect_fields} on `_User` so that ad-hoc
      # uses (i.e. not through {.master_only_fields} /
      # {.self_visible_fields}) emit a one-time advisory pointing at the
      # higher-level helpers and the `protectedFieldsOwnerExempt` flag.
      # The behavior is otherwise unchanged.
      def protect_fields(pattern, fields)
        _warn_about_user_protect_fields! unless @_user_field_dsl_active
        super
      end

      # @!visibility private
      def _rebuild_user_protected_fields!
        @master_only_fields  ||= []
        @self_visible_fields ||= []
        pointer = @self_pointer_field || :self
        all_hidden = (@master_only_fields + @self_visible_fields).uniq

        @_user_field_dsl_active = true
        begin
          protect_fields("*", all_hidden) unless all_hidden.empty?
          unless @self_visible_fields.empty?
            protect_fields("userField:#{pointer}", @master_only_fields)
          end
        ensure
          @_user_field_dsl_active = false
        end
      end

      # @!visibility private
      def _warn_about_user_protect_fields!
        return if @_user_protect_fields_warned
        @_user_protect_fields_warned = true
        _emit_user_field_advisory(
          "[Parse::User] protect_fields was called directly on _User. " \
          "For master-only and owner-visible field patterns prefer " \
          "`Parse::User.master_only_fields` and `Parse::User.self_visible_fields`. " \
          "Either way, ensure Parse Server is started with " \
          "`protectedFieldsOwnerExempt: false` (the default `true` exempts the " \
          "owning user from every protectedFields rule on _User, which silently " \
          "negates these protections for the user's own row).",
        )
      end

      # @!visibility private
      # Fires once when `master_only_fields` / `self_visible_fields` is first
      # used. Without `protectedFieldsOwnerExempt: false` in Parse Server's
      # startup options, neither helper does what its name promises -- the
      # default `true` silently exempts the owning user from every
      # protectedFields rule on _User. The SDK can't introspect Parse
      # Server's startup options, so we surface this as a one-time advisory
      # at declaration time so it's loud enough to catch before deploy.
      def _warn_about_owner_exempt_prereq!
        return if @_owner_exempt_warned
        @_owner_exempt_warned = true
        _emit_user_field_advisory(
          "[Parse::User] master_only_fields / self_visible_fields require " \
          "Parse Server option `protectedFieldsOwnerExempt: false`. With the " \
          "default `true`, the owning user is silently exempted from every " \
          "protectedFields rule on _User, so a field declared master-only " \
          "would still be visible to the user themselves on their own row. " \
          "Set `protectedFieldsOwnerExempt: false` in your ParseServer " \
          "options BEFORE deploying. See docs/acl_clp_guide.md §4.2.",
        )
      end

      # @!visibility private
      # Fires once when `self_visible_fields` is first used. The Parse
      # Server side requires (a) a self-pointer field on _User populated
      # by a beforeSave('_User') trigger, AND (b) a one-shot backfill on
      # any pre-existing user rows so the pointer is set before the
      # `userField:<via>` group matches them.
      def _warn_about_self_pointer_prereq!(via)
        return if @_self_pointer_warned
        @_self_pointer_warned = true
        _emit_user_field_advisory(
          "[Parse::User] self_visible_fields(via: :#{via}) requires a " \
          "self-pointer field named `#{via}` on _User pointing at the same " \
          "row, populated by a beforeSave('_User') Cloud Code trigger. " \
          "Existing user rows ALSO need a one-shot backfill (the trigger " \
          "only fires on save) -- without it, those rows never match the " \
          "`userField:#{via}` group and the field stays hidden from the " \
          "user themselves. See docs/acl_clp_guide.md §4.2.",
        )
      end

      # @!visibility private
      def _emit_user_field_advisory(msg)
        if Parse.respond_to?(:logger) && Parse.logger
          Parse.logger.warn(msg)
        else
          Kernel.warn(msg)
        end
      end
    end

    # @!visibility private
    # Defense-in-depth strip of +authData+ on the way into the in-memory
    # User. Parse Server returns +authData+ on +GET /users/:id+ to any
    # caller with ACL read on the row, and the default +_User+ ACL is
    # permissive in many deployments — without this filter, fetching a
    # different user (or iterating a +Parse::Query.new(User)+ result set)
    # would expose their OAuth +access_token+ / +id_token+ to anyone who
    # JSON-renders the result (Rails views, agent tool output, logging).
    #
    # The strip runs unconditionally unless the caller is inside a
    # {.with_authdata_trust} scope, which is set by the self-fetch
    # paths in this file (login/login!/session!/create/link_auth_data!/
    # unlink_auth_data!) and by the MFA login extension. Trusted callers
    # pass through to +super+ with the hash untouched. The PROTECTED
    # mass-assignment filter that runs inside +super+ is unaffected.
    def apply_attributes!(hash, dirty_track: false, filter_protected: nil, protected_set: nil)
      if hash.is_a?(Hash) && !self.class.authdata_trusted?
        if hash.key?(:authData) || hash.key?("authData") ||
           hash.key?(:auth_data) || hash.key?("auth_data")
          hash = hash.dup
          hash.delete(:authData)
          hash.delete("authData")
          hash.delete(:auth_data)
          hash.delete("auth_data")
        end
      end
      super(hash, dirty_track: dirty_track, filter_protected: filter_protected, protected_set: protected_set)
    end

    # @return [Boolean] true if this user is anonymous (i.e. created
    #   via the +authData.anonymous+ provider rather than via signup
    #   with a username/password or a real OAuth provider).
    def anonymous?
      !anonymous_id.nil?
    end

    # Returns the anonymous identifier only if this user is anonymous.
    # @see #anonymous?
    # @return [String] The anonymous identifier for this anonymous user.
    def anonymous_id
      auth_data["anonymous"]["id"] if auth_data.present? && auth_data["anonymous"].is_a?(Hash)
    end

    # Adds the third-party authentication data to for a given service.
    # @param service_name [Symbol] The name of the service (ex. :facebook)
    # @param data [Hash] The body of the OAuth data. Dependent on each service.
    # @raise [Parse::Client::ResponseError] If user was not successfully linked
    def link_auth_data!(service_name, **data)
      response = client.set_service_auth_data(id, service_name, data)
      raise Parse::Client::ResponseError, response if response.error?
      self.class.with_authdata_trust { apply_attributes!(response.result) }
    end

    # Removes third-party authentication data for this user
    # @param service_name [Symbol] The name of the third-party service (ex. :facebook)
    # @raise [Parse::Client::ResponseError] If user was not successfully unlinked
    # @return [Boolean] True/false if successful.
    def unlink_auth_data!(service_name)
      response = client.set_service_auth_data(id, service_name, nil)
      raise Parse::Client::ResponseError, response if response.error?
      self.class.with_authdata_trust { apply_attributes!(response.result) }
    end

    # Upgrade an anonymous user (one created via the +authData.anonymous+
    # provider) into a full username/password account. This is the
    # SDK-side counterpart of the Parse JS SDK's
    # +_linkWith('username', ...)+ flow — it sends a single
    # +PUT /users/:id+ with the new credentials and an explicit
    # +authData: { anonymous: nil }+ unlink in the same body, then
    # narrowly applies the server's response to the in-memory user.
    #
    # The +authData.anonymous+ unlink is essential: leaving the anonymous
    # provider attached after assigning a username would let anyone else
    # who somehow learned the (random) anonymous id silently log in as
    # the freshly-named account, a documented Parse foot-gun.
    #
    # @param username [String] the username to claim. Must be unique.
    # @param password [String] the password to set on the account.
    # @param email [String, nil] optional email address. Must be unique
    #   if provided.
    # @raise [Parse::Error::AuthenticationError] when this instance has
    #   no attached +@session_token+, no objectId, or is not anonymous.
    # @raise [Parse::Error::UsernameMissingError] when +username+ is blank.
    # @raise [Parse::Error::PasswordMissingError] when +password+ is blank.
    # @raise [Parse::Error::UsernameTakenError] when Parse Server reports
    #   the username already exists.
    # @raise [Parse::Error::EmailTakenError] when Parse Server reports
    #   the email already exists.
    # @raise [Parse::Error::InvalidEmailAddress] when Parse Server
    #   reports the email is malformed.
    # @raise [Parse::Client::ResponseError] for any other error response.
    # @return [Boolean] true on success.
    def upgrade_anonymous!(username:, password:, email: nil)
      require_self_session!(:upgrade_anonymous!)
      if @id.nil? || @id.to_s.empty?
        raise Parse::Error::AuthenticationError,
              "Parse::User#upgrade_anonymous! requires a saved user (no objectId)"
      end
      unless anonymous?
        raise Parse::Error::AuthenticationError,
              "Parse::User#upgrade_anonymous! is only valid for anonymous users " \
              "(authData.anonymous is not present on this instance)"
      end
      if username.nil? || username.to_s.empty?
        raise Parse::Error::UsernameMissingError, "upgrade_anonymous! requires a username."
      end
      if password.nil? || password.to_s.empty?
        raise Parse::Error::PasswordMissingError, "upgrade_anonymous! requires a password."
      end

      body = {
        username: username.to_s,
        password: password.to_s,
        # Explicitly unlink the anonymous provider in the same request
        # that claims the new credentials — otherwise the account
        # remains takeover-able via the anonymous id.
        authData: { anonymous: nil },
      }
      body[:email] = email.to_s if email.is_a?(String) && !email.empty?

      response = client.update_user(@id, body, session_token: @session_token)

      if response.success?
        result = response.result || {}
        @updated_at = result["updatedAt"] || @updated_at
        # Parse Server may rotate the session token on a credential
        # change; apply it narrowly if present without going through the
        # full property writer chain.
        if result["sessionToken"].is_a?(String) && !result["sessionToken"].empty?
          @session_token = result["sessionToken"]
        end
        @auth_data.delete("anonymous") if @auth_data.is_a?(Hash)
        @username = username.to_s
        @email = email.to_s if email.is_a?(String) && !email.empty?
        @password = nil
        changes_applied!
        clear_partial_fetch_state!
        return true
      end

      case response.code
      when Parse::Response::ERROR_USERNAME_MISSING
        raise Parse::Error::UsernameMissingError, response
      when Parse::Response::ERROR_PASSWORD_MISSING
        raise Parse::Error::PasswordMissingError, response
      when Parse::Response::ERROR_USERNAME_TAKEN
        raise Parse::Error::UsernameTakenError, response
      when Parse::Response::ERROR_EMAIL_TAKEN
        raise Parse::Error::EmailTakenError, response
      when Parse::Response::ERROR_EMAIL_INVALID
        raise Parse::Error::InvalidEmailAddress, response
      end
      raise Parse::Client::ResponseError, response
    end

    # @!visibility private
    # So that apply_attributes! works with session_token for login
    def session_token_set_attribute!(token, track = false)
      @session_token = token.to_s
    end

    alias_method :sessionToken_set_attribute!, :session_token_set_attribute!

    # @return [Boolean] true if this user has a session token.
    def logged_in?
      self.session_token.present?
    end

    # Request a password reset for this user
    # @return [Boolean] true if it was successful requested. false otherwise.
    # @see Parse::User.request_password_reset
    def request_password_reset
      return false if email.nil?
      Parse::User.request_password_reset(email)
    end

    # You may set a password for this user when you are creating them. Parse never returns a
    # @param passwd The user's password to be used for signing up.
    # @raise [Parse::Error::UsernameMissingError] If username is missing.
    # @raise [Parse::Error::PasswordMissingError] If password is missing.
    # @raise [Parse::Error::UsernameTakenError] If the username has already been taken.
    # @raise [Parse::Error::EmailTakenError] If the email has already been taken (or exists in the system).
    # @raise [Parse::Error::InvalidEmailAddress] If the email is invalid.
    # @raise [Parse::Client::ResponseError] An unknown error occurred.
    # @return [Boolean] True if signup it was successful. If it fails an exception is thrown.
    def signup!(passwd = nil)
      self.password = passwd || password
      if username.blank?
        raise Parse::Error::UsernameMissingError, "Signup requires a username."
      end

      if password.blank?
        raise Parse::Error::PasswordMissingError, "Signup requires a password."
      end

      signup_attrs = attribute_updates
      # See {#signup_create} for the rationale on the safe-pattern check.
      if self.class.signup_body_self_only_acl_safe?(signup_attrs)
        signup_attrs.except!(:createdAt, :updatedAt, "createdAt", "updatedAt")
      else
        signup_attrs.except!(*Parse::Properties::BASE_FIELD_MAP.flatten)
      end
      self.class.strip_server_controlled_keys!(signup_attrs)

      # first signup the user, then save any additional attributes
      response = client.create_user signup_attrs

      if response.success?
        # Restrict what the server can plant into the in-memory user via
        # the signup response, matching the defense in {#signup_create}.
        # `POST /parse/users` legitimately returns objectId, createdAt,
        # updatedAt (extracted into @-vars directly below), sessionToken,
        # and emailVerified. Any other key in the response body --
        # `authData`, `_rperm`, `_wperm`, `roles`, etc. -- is dropped, so
        # a compromised or MITM'd Parse Server cannot use this code path
        # to plant credentials/permissions onto the user we just signed
        # up. The previous `apply_attributes! response.result` accepted
        # every key the server returned through the typed property
        # writers (`authData_set_attribute!` exists because we declare
        # `property :auth_data, :object`), which was a footgun the
        # save-as-signup path had already addressed.
        result = response.result
        @id = result[Parse::Model::OBJECT_ID] || @id
        @created_at = result["createdAt"] || @created_at
        @updated_at = result["updatedAt"] || result["createdAt"] || @updated_at
        set_attributes!(result.slice(*SIGNUP_RESPONSE_APPLY_KEYS))
        # Drop the plaintext password from memory now that the server
        # has it hashed and we no longer need it. Matches the Parse JS
        # SDK behavior of clearing the password attribute after a
        # successful save/signup. Uses direct ivar assignment so the
        # dirty tracker doesn't record this clear as a pending change
        # that would be re-sent on the next save.
        @password = nil
        # Mirror Parse::Object#save: a successful round-trip means the
        # locally-set credential fields are now in sync with the server
        # and must NOT be re-sent on the next save. Without this, a
        # subsequent user.save! re-transmits `password`, which Parse
        # Server treats as a password change under
        # revokeSessionOnPasswordReset and revokes the session just
        # minted by this signup.
        changes_applied!
        clear_partial_fetch_state!
        return true
      end

      case response.code
      when Parse::Response::ERROR_USERNAME_MISSING
        raise Parse::Error::UsernameMissingError, response
      when Parse::Response::ERROR_PASSWORD_MISSING
        raise Parse::Error::PasswordMissingError, response
      when Parse::Response::ERROR_USERNAME_TAKEN
        raise Parse::Error::UsernameTakenError, response
      when Parse::Response::ERROR_EMAIL_TAKEN
        raise Parse::Error::EmailTakenError, response
      when Parse::Response::ERROR_EMAIL_INVALID
        raise Parse::Error::InvalidEmailAddress, response
      end
      raise Parse::Client::ResponseError, response
    end

    # Override of {Parse::Core::Actions::InstanceMethods#create} so that
    # saving a new user that has a `password` goes through Parse Server's
    # signup endpoint and the returned session token is applied to the
    # in-memory object. Falls through to the inherited raw `_User` insert
    # when the new user has no password or when {.signup_on_save} has been
    # disabled. Like the inherited `:create` path, the `before_create` /
    # `after_create` callback chain still fires and the method returns the
    # response's success flag (errors propagate to {Parse::Object#save} as
    # a `false` return, which the caller may turn into a
    # {Parse::RecordNotSaved} via `save!` / `autoraise: true`).
    #
    # `auth_data`-only signups (federated-identity / OAuth flows where no
    # password is set) are deliberately NOT routed through this path,
    # because `POST /parse/users` treats `auth_data` as an identity claim
    # against an existing user — accepting it from a mass-assigned hash
    # would expose a session-token planting vector. OAuth signup is the
    # responsibility of the explicit {#signup!} method (or
    # {Parse::User.autologin_service}), whose call sites necessarily make
    # the federated-identity decision themselves.
    # @!visibility private
    def create
      if self.class.signup_on_save && self.password.present?
        signup_create
      else
        super
      end
    end

    # Login and get a session token for this user.
    # @param passwd [String] The password for this user.
    # @return [Boolean] True/false if we received a valid session token.
    def login!(passwd = nil)
      self.password = passwd || self.password
      response = client.login(username.to_s, password.to_s)
      if response.success?
        # Unlike signup, login's response is the canonical state of an
        # existing user, including any linked authData. Applying the
        # full response body here is intentional -- the server is
        # telling us what the account currently looks like. (Compare
        # signup, where we narrow to an allow-list because a brand-new
        # account has no legitimate authData to report.)
        self.class.with_authdata_trust { apply_attributes! response.result }
        # Drop the plaintext password from memory now that the login
        # has succeeded. Direct ivar assignment so the dirty tracker
        # doesn't record this clear as a pending change.
        @password = nil
        # Clear dirty state so a subsequent user.save! does not re-send
        # `password` (which Parse Server would treat as a password
        # change and use to revoke the session this login just issued).
        # See the matching note in #signup!.
        changes_applied!
        clear_partial_fetch_state!
      end
      self.session_token.present?
    end

    # Invalid the current session token for this logged in user.
    # @return [Boolean] True/false if successful
    def logout
      return true if self.session_token.blank?
      client.logout session_token
      self.session_token = nil
      true
    rescue
      false
    end

    # @!visibility private
    def session_token=(token)
      @session = nil
      @session_token = token
    end

    # @return [Session] the session corresponding to the user's session token.
    def session
      if @session.blank? && @session_token.present?
        response = client.fetch_session(@session_token)
        # Trusted hydration: +response.result+ is the server-side
        # _Session row, which legitimately includes +sessionToken+,
        # +createdAt+, +updatedAt+, and other protected keys. Route
        # through {Parse::Object.build} which handles the trusted-init
        # signalling.
        @session ||= Parse::Object.build(response.result, Parse::Model::CLASS_SESSION)
      end
      @session
    end

    # @!visibility private
    # Keys that must never flow through +Parse::User.create+ from a
    # mass-assigned hash. +authData+ on the user-signup endpoint causes
    # Parse Server to silently log into the existing account that matches
    # that auth_data and return ITS sessionToken — full account takeover
    # if the caller blindly forwards client-supplied parameters.
    # +objectId+ allows the caller to pick the user's identifier on
    # creation, sometimes targetable depending on Parse Server config.
    UNSAFE_CREATE_KEYS = %i[authData auth_data objectId id].freeze

    # @!visibility private
    # Fields that are server-controlled and must be stripped from any body
    # that the SDK sends to the signup endpoint or +Parse::User.create+,
    # regardless of who supplied them. Unlike {UNSAFE_CREATE_KEYS}, passing
    # one of these is not refused (no exception is raised); the field is
    # silently dropped before wire transit.
    #
    # +emailVerified+ is the canonical case: Parse Server's default `_User`
    # CLP restricts writes to the master key, so a caller-supplied value
    # would normally be rejected anyway — but the SDK strips it as
    # defense-in-depth so signup with mass-assigned attributes cannot
    # smuggle a verified=true onto a brand-new account if the deployment
    # has loosened the default CLP. (Update-path coverage is handled by
    # the {Parse::Core::FieldGuards} declaration
    # {guard :email_verified, :master_only} below, which silently reverts
    # client writes at the `_User.beforeSave` webhook boundary.)
    #
    # The underscore-prefixed entries are internal Parse Server `_User`
    # bookkeeping columns (verify tokens, perishable tokens, the bcrypt
    # password hash, lockout state, etc.). Parse Server rejects writes to
    # them from non-master callers anyway, but the SDK strips them as a
    # belt-and-suspenders measure so a mass-assigned hash from request
    # parameters cannot reach the wire with these keys at all.
    #
    # The trusted signup-response apply path ({SIGNUP_RESPONSE_APPLY_KEYS})
    # is unaffected by this strip because it uses {#set_attributes!}, not
    # the dirty-tracked setter that {#attribute_updates} reads from.
    SERVER_CONTROLLED_KEYS = %i[
      emailVerified email_verified
      _hashed_password
      _email_verify_token _email_verify_token_expires_at
      _perishable_token _perishable_token_expires_at
      _password_history
      _failed_login_count
      _account_lockout_expires_at
    ].freeze

    # Creates a new Parse::User given a hash that maps to the fields defined in your Parse::User collection.
    #
    # Mass-assignment of +authData+/+auth_data+/+objectId+ is refused. If you
    # intend to create-or-login a user via federated identity, use
    # {.autologin_service} or {.link_or_create_with_auth_data}. Passing
    # those keys directly bypasses the SDK's federated-identity wrapper
    # and risks returning a victim's sessionToken to whoever submitted
    # the request.
    #
    # @param body [Hash] The hash containing the Parse::User fields. The field `username` and `password` are required.
    # @option opts [Boolean] :master_key Whether the master key should be used for this request.
    # @raise [ArgumentError] If +body+ contains +authData+/+auth_data+/+objectId+ — use {.autologin_service} for federated flows.
    # @raise [Parse::Error::UsernameMissingError] If username is missing.
    # @raise [Parse::Error::PasswordMissingError] If password is missing.
    # @raise [Parse::Error::UsernameTakenError] If the username has already been taken.
    # @raise [Parse::Error::EmailTakenError] If the email has already been taken (or exists in the system).
    # @raise [Parse::Error::InvalidEmailAddress] If the email is invalid.
    # @raise [Parse::Client::ResponseError] An unknown error occurred.
    # @return [User] Returns a successfully created Parse::User.
    def self.create(body, **opts)
      # Consume and clear the SDK-internal trust marker before validation
      # or wire transit. This prevents trusted-authdata flag smuggling
      # through callers that copy hashes from a request parameter.
      trusted = body.is_a?(Hash) ? (body.delete(:__parse_stack_trusted_authdata) ||
                                    body.delete("__parse_stack_trusted_authdata")) : false
      assert_create_body_safe!(body) unless trusted
      strip_server_controlled_keys!(body)
      response = client.create_user(body, **opts)
      if response.success?
        body.delete :password # clear password before merging
        # Self-fetch trust: the response.result describes the user we
        # just created, so any returned authData IS that user's own
        # federated-identity payload — allow it through the hydration
        # strip in {#apply_attributes!}.
        return with_authdata_trust { Parse::User.build body.merge(response.result) }
      end

      case response.code
      when Parse::Response::ERROR_USERNAME_MISSING
        raise Parse::Error::UsernameMissingError, response
      when Parse::Response::ERROR_PASSWORD_MISSING
        raise Parse::Error::PasswordMissingError, response
      when Parse::Response::ERROR_USERNAME_TAKEN
        raise Parse::Error::UsernameTakenError, response
      when Parse::Response::ERROR_EMAIL_TAKEN
        raise Parse::Error::EmailTakenError, response
      end
      raise Parse::Client::ResponseError, response
    end

    # @!visibility private
    # Silently strips {SERVER_CONTROLLED_KEYS} from +body+ in place. Used
    # by {.create}, {#signup!}, and {#signup_create} as defense-in-depth so
    # caller-supplied values for fields that Parse Server is meant to
    # control (currently just +emailVerified+) never reach the wire.
    # @return [Hash, Object] the same +body+ object, mutated.
    def self.strip_server_controlled_keys!(body)
      return body unless body.is_a?(Hash)
      SERVER_CONTROLLED_KEYS.each do |k|
        body.delete(k)
        body.delete(k.to_s)
      end
      body
    end

    # @!visibility private
    # Raises +ArgumentError+ if +body+ carries keys that would let an
    # attacker turn +Parse::User.create+ into an account-takeover sink.
    # Skipped when called through the SDK's federated-identity wrapper
    # ({.autologin_service}), which deliberately supplies +authData+ and
    # is responsible for its provenance.
    def self.assert_create_body_safe!(body)
      return unless body.is_a?(Hash)
      unsafe = body.each_key.select do |k|
        ks = k.is_a?(String) ? k.to_sym : k
        UNSAFE_CREATE_KEYS.include?(ks)
      end
      unless unsafe.empty?
        raise ArgumentError,
              "Refusing Parse::User.create with #{unsafe.inspect}. " \
              "These keys can be used for account takeover via federated-id " \
              "linking. Use Parse::User.autologin_service for federated " \
              "flows, or pass authData via that wrapper."
      end
    end

    # Automatically and implicitly signup a user if it did not already exists and
    # authenticates them (login) using third-party authentication data. May raise exceptions
    # similar to `create` depending on what you provide the _body_ parameter.
    # @param service_name [Symbol] the name of the service key (ex. :facebook)
    # @param auth_data [Hash] the specific service data to place in the user's auth-data for this service.
    # @param body [Hash] any additional User related fields or properties when signing up this User record.
    # @return [User] a logged in user, or nil.
    # @see User.create
    def self.autologin_service(service_name, auth_data, body: {})
      # Trust-mark this call so {.assert_create_body_safe!} permits the
      # +authData+ that we are explicitly responsible for here. The
      # marker is consumed inside {.create} before forwarding to the
      # server.
      body = body.merge({
        authData: { service_name => auth_data },
        __parse_stack_trusted_authdata: true,
      })
      self.create(body)
    end

    # Create and log in a new anonymous user via the
    # +authData.anonymous+ provider. The returned user instance has a
    # +session_token+ and an objectId, and {#anonymous?} returns true.
    # Later, after the user has chosen a username and password, upgrade
    # the account in-place with {#upgrade_anonymous!}.
    #
    # Parse Server requires the anonymous-provider payload to include a
    # client-generated +id+; this helper produces one via
    # +SecureRandom.uuid+ so callers don't have to hand-roll the
    # +authData+ shape.
    #
    # @return [User] a freshly-created, logged-in anonymous user.
    # @see #upgrade_anonymous!
    def self.anonymous_signup
      autologin_service(:anonymous, { id: SecureRandom.uuid })
    end

    # This method will signup a new user using the parameters below. The required fields
    # to create a user in Parse is the _username_ and _password_ fields. The _email_ field is optional.
    # Both _username_ and _email_ (if provided), must be unique. At a minimum, it is recommended you perform
    # a query using the supplied _username_ first to verify do not already have an account with that username.
    # This method will raise all the exceptions from the similar `create` method.
    # @see User.create
    def self.signup(username, password, email = nil, body: {})
      body = body.merge({ username: username, password: password })
      body[:email] = email if email.present?
      self.create(body)
    end

    # Login and return a Parse::User with this username/password combination.
    # @param username [String] the user's username
    # @param password [String] the user's password
    # @return [User] a logged in user for the provided username. Returns nil otherwise.
    # @see .login!
    def self.login(username, password)
      response = client.login(username.to_s, password.to_s)
      return nil unless response.success?
      # Self-fetch trust: the login response IS the authenticating user;
      # any returned authData belongs to them.
      with_authdata_trust { Parse::User.build(response.result) }
    end

    # Login and return a Parse::User with this username/password combination,
    # raising on failure instead of returning nil. Mirrors the
    # `find_by_username!` / `find!` conventions: callers who treat an
    # unsuccessful login as an exceptional condition shouldn't have to
    # build their own `raise if .nil?` boilerplate around every call site.
    #
    # @param username [String] the user's username.
    # @param password [String] the user's password.
    # @return [User] the logged-in user.
    # @raise [Parse::Error::AuthenticationError] when Parse Server rejects
    #   the credentials, the request is rate-limited at the server, or the
    #   response is otherwise unsuccessful.
    # @see .login
    def self.login!(username, password)
      response = client.login(username.to_s, password.to_s)
      if response.success?
        # Self-fetch trust: see {.login}.
        with_authdata_trust { Parse::User.build(response.result) }
      else
        raise Parse::Error::AuthenticationError,
              "Parse::User.login! failed for #{username.inspect}: " \
              "#{response.error || "HTTP #{response.http_status}"} (code=#{response.code.inspect})"
      end
    end

    # Request a password reset for a registered email.
    # @example
    #  user = Parse::User.first
    #
    #  # pass a user object
    #  Parse::User.request_password_reset user
    #  # or email
    #  Parse::User.request_password_reset("user@example.com")
    # @param email [String] The user's email address.
    # @return [Boolean] True/false if successful.
    def self.request_password_reset(email)
      email = email.email if email.is_a?(Parse::User)
      return false if email.blank?
      response = client.request_password_reset(email)
      response.success?
    end

    # Same as `session!` but returns nil if a user was not found or sesion token was invalid.
    # @return [User] the user matching this active token, otherwise nil.
    # @see #session!
    def self.session(token, opts = {})
      self.session! token, opts
    rescue Parse::Error::InvalidSessionTokenError
      nil
    end

    # Return a Parse::User for this active session token.
    # @raise [InvalidSessionTokenError] Invalid session token.
    # @raise [ArgumentError] when `opts` smuggles a conflicting
    #   `:session_token` key — the positional `token` argument is the
    #   only source of truth; rejecting the kwarg prevents a silent
    #   override that would authenticate as a different user.
    # @return [User] the user matching this active token
    # @see #session
    def self.session!(token, opts = {})
      if opts.is_a?(Hash) && (opts.key?(:session_token) || opts.key?("session_token"))
        raise ArgumentError,
              "Parse::User.session! takes the session token as its positional " \
              "argument; do not also pass it via opts[:session_token]"
      end
      # support Parse::Session objects
      token = token.session_token if token.respond_to?(:session_token)
      response = client.current_user(token, **opts)
      return nil unless response.success?
      # Self-fetch trust: `/users/me` returns the row owned by the
      # supplied session token, so authData here is that user's own.
      with_authdata_trust { Parse::User.build(response.result) }
    end

    # Block-scoped sugar around {Parse.with_session}: runs the block
    # with this user's `session_token` as the ambient session token for
    # the current fiber. Every Parse call inside the block that doesn't
    # explicitly pass `session_token:` or `use_master_key: true` will be
    # sent as this user.
    # @yield runs the block with the user's session in ambient scope.
    # @return [Object] the block's return value.
    # @raise [Parse::Error::AuthenticationError] when the user has no
    #   session token attached.
    # @example
    #   user = Parse::User.login!("alice", "pw")
    #   user.with_session do
    #     Post.all                # scoped to alice
    #     post.save               # scoped to alice
    #   end
    def with_session(&block)
      raise ArgumentError, "Parse::User#with_session requires a block" unless block_given?
      unless @session_token.is_a?(String) && !@session_token.empty?
        raise Parse::Error::AuthenticationError,
              "Parse::User#with_session requires an authenticated session — " \
              "obtain the instance via login/signup or call `user.session_token = '...'` first"
      end
      Parse.with_session(@session_token, &block)
    end

    # If the current session token for this instance is nil, this method finds
    # the most recent active Parse::Session token for this user and applies it to the instance.
    # The user instance will now be authenticated and logged in with the selected session token.
    # Useful if you need to call save or destroy methods on behalf of a logged in user.
    # @return [String] The session token or nil if no session was found for this user.
    def any_session!
      unless @session_token.present?
        _active_session = active_sessions(restricted: false, order: :updated_at.desc).first
        self.session_token = _active_session.session_token if _active_session.present?
      end
      @session_token
    end

    # =========================================================================
    # Session Management Methods
    # =========================================================================

    # Logout from all sessions, effectively signing out on all devices.
    # Optionally keep the current session active.
    #
    # **Self-guard.** Requires the user instance to carry a session token —
    # i.e. to have been obtained via login/signup or attached via
    # {#session_token=}. Without this, `user.id = victim_id;
    # user.logout_all!` could revoke another user's sessions if the
    # deployment has loose `_Session` write CLP. The guard fails closed
    # in the SDK so the deployment's CLP isn't the only line of defense.
    #
    # @param keep_current [Boolean] if true, keeps the current session active (default: false)
    # @return [Integer] the number of sessions revoked
    # @raise [Parse::Error::AuthenticationError] if the user has no session token
    # @example
    #   # Logout from all devices
    #   user.logout_all!
    #
    #   # Logout from all devices except current
    #   user.logout_all!(keep_current: true)
    def logout_all!(keep_current: false)
      return 0 unless id.present?
      require_self_session!("logout_all!")
      current_token = @session_token
      # Self-scope the _Session query: in client mode the ambient client
      # has no auth, so the query must carry this user's session token to
      # be authorized against /classes/_Session. Master-key mode ignores
      # the ambient since the master key still wins.
      count = Parse.with_session(current_token) do
        # Always revoke the OTHER sessions first under the live token —
        # destroying the calling session mid-loop invalidates the token
        # and the remaining deletes 401. Then, if not keeping current,
        # close the calling session via the dedicated logout endpoint.
        n = Parse::Session.revoke_all_for_user(self, except: current_token)
        unless keep_current
          begin
            Parse.client.logout(current_token)
            n += 1
          rescue Parse::Error::InvalidSessionTokenError
            # The calling session was already gone (server-side TTL or
            # concurrent revoke). Idempotent: count what we destroyed.
          end
        end
        n
      end
      @session_token = nil unless keep_current
      @session = nil unless keep_current
      count
    end

    # Get the count of active (non-expired) sessions for this user.
    # Requires an authenticated session (see {#logout_all!} for the rationale).
    # @return [Integer] the number of active sessions
    # @raise [Parse::Error::AuthenticationError] if the user has no session token
    # @example
    #   count = user.active_session_count
    #   puts "User is logged in on #{count} devices"
    def active_session_count
      return 0 unless id.present?
      require_self_session!("active_session_count")
      Parse.with_session(@session_token) do
        Parse::Session.active_count_for_user(self)
      end
    end

    # Get all active sessions for this user.
    # Requires an authenticated session (see {#logout_all!} for the rationale).
    # @return [Array<Parse::Session>] array of active session objects
    # @raise [Parse::Error::AuthenticationError] if the user has no session token
    # @example
    #   user.sessions.each do |session|
    #     puts "Session created: #{session.created_at}"
    #   end
    def sessions
      return [] unless id.present?
      require_self_session!("sessions")
      Parse.with_session(@session_token) do
        Parse::Session.for_user(self).all
      end
    end

    # Check if this user has multiple active sessions (logged in on multiple devices).
    # @return [Boolean] true if user has more than one active session
    # @example
    #   if user.multi_session?
    #     puts "User is logged in on multiple devices"
    #   end
    def multi_session?
      active_session_count > 1
    end

    # Return the transitive upward closure of role names this user
    # inherits permissions from.
    #
    # ## Authorization
    #
    # The role graph is privileged data: Parse Server's `_Role` class
    # ships with `acl_policy :private` precisely so anonymous clients
    # cannot enumerate role memberships. This method therefore routes
    # through the mongo-direct fast path under an EXPLICIT
    # authorization scope.
    #
    # By default, `as:` is set to `self` — the user instance itself,
    # meaning "I (this user) am asking about my own roles". The scope
    # is resolved via {Parse::ACLScope} and CLP is enforced against
    # `_Role`: the call succeeds iff the user's permission set
    # (`["*", user.id, "role:..."]`) is permitted to `find` on
    # `_Role`. Under Parse Server's default `_Role` CLP (master-only,
    # which {Parse::Role}'s `acl_policy :private` does not change),
    # the user's scope is NOT permitted, so this call raises
    # {Parse::CLPScope::Denied}. Apps that have explicitly opened
    # `_Role` CLP for authenticated users (e.g. `find:
    # { requiresAuthentication: true }`) will have the call succeed.
    #
    # Callers performing privileged work (computing ACL permission
    # sets, e.g. server-side filters) should pass `master: true` to
    # bypass the CLP check.
    #
    # **Breaking change:** Previously this method bypassed the
    # authorization check entirely (callers could construct a
    # `Parse::User` with any objectId via
    # `Parse::User.new.tap { |u| u.id = victim_id }` and enumerate
    # the victim's roles). The new contract is explicit-auth-required;
    # use `master: true` for the previous behavior.
    #
    # @param max_depth [Integer] maximum BFS depth (default: 10).
    # @param master [Boolean] when +true+, bypass `_Role` CLP and run
    #   the role-graph lookup under master mode. Use for ACL-building
    #   code paths inside the SDK or in admin tooling.
    # @param as [Parse::User, Parse::Pointer, nil] caller-scope. When
    #   `nil`, defaults to `self` (the user-asking-about-their-own-roles
    #   case). Pass a different user to ask "what would this caller
    #   see when introspecting this user's roles?"; the scope's
    #   permission set is checked against `_Role` CLP.
    # @return [Set<String>] role names (no +role:+ prefix). Empty set
    #   when the user has no objectId yet or holds no roles.
    # @raise [Parse::CLPScope::Denied] when the scope cannot `find`
    #   on `_Role` under the current CLP.
    # @example
    #   # User reading their own roles (subject to _Role CLP):
    #   permission_set = (["*", user.id] + user.acl_roles.map { |n| "role:#{n}" }).uniq
    #   # Admin/SDK-internal code building ACL filters:
    #   permission_set = (["*", user.id] + user.acl_roles(master: true).map { |n| "role:#{n}" }).uniq
    def acl_roles(max_depth: 10, master: false, as: nil)
      return Set.new unless id.is_a?(String) && !id.empty?
      # Default `as:` to self so the common "user reading their own
      # roles" case works without ceremony when _Role CLP permits the
      # user. The CLP check + scope resolution happens inside
      # Parse::Role.all_for_user → Parse::MongoDB.role_names_for_user.
      effective_as = as.nil? && master != true ? self : as
      Parse::Role.all_for_user(
        self, max_depth: max_depth, master: master, as: effective_as,
      )
    end

    private

    # Self-guard for session-scoped instance methods. Fails closed when
    # the user instance carries no `@session_token`, preventing the
    # `Parse::User.new.tap { |u| u.id = victim_id }` attack on any
    # method that derives its authorization from the user's identity
    # alone. See {#logout_all!} for the full rationale.
    # @raise [Parse::Error::AuthenticationError] when no session token is attached.
    def require_self_session!(method_name)
      return if @session_token.is_a?(String) && !@session_token.empty?
      raise Parse::Error::AuthenticationError,
            "Parse::User##{method_name} requires an authenticated session — " \
            "obtain the instance via login/signup or call `user.session_token = '...'` first"
    end

    # Keys that {#signup_create} will accept from a `POST /parse/users`
    # response body and feed through {#set_attributes!}. `sessionToken`
    # is the operative output of the signup endpoint; `emailVerified` is
    # the only other field Parse Server commonly emits and is harmless to
    # apply. All other keys are dropped, even if the server response
    # contains them — this blocks a compromised or MITM'd Parse Server
    # from planting `authData`, `_rperm`, `_wperm`, `roles`, or other
    # security-sensitive fields into the in-memory user object via the
    # save-as-signup path. `objectId`, `createdAt`, and `updatedAt` are
    # extracted directly into the corresponding `@`-vars below and so do
    # not need to appear in this list.
    SIGNUP_RESPONSE_APPLY_KEYS = %w[sessionToken emailVerified].freeze

    # Strict matcher for a client-supplied `objectId` that the SDK could
    # plausibly have generated via Parse::Core::ParseReference. Used by
    # {.signup_body_self_only_acl_safe?} to gate the narrow whitelist of
    # client-supplied ACL+objectId pairs allowed through the signup body.
    PARSE_OBJECT_ID_FORMAT = /\A[A-Za-z0-9]{10}\z/.freeze

    # True when the signup-body `objectId` and `ACL` together describe the
    # safe self-only ownership pattern that {acl_policy} produces under
    # `owner: :self`: the body has a client-assigned `objectId` matching
    # the Parse-id format, and the ACL has exactly one entry granting
    # read+write to that same objectId. Any deviation — multiple keys, a
    # non-self key, a `*` (public) entry, a `role:` entry, missing or
    # extra permissions — fails the check and the strip-everything fallback
    # in {#signup_create} / {#signup!} runs as before.
    # @param body [Hash] signup request body, with symbol or string keys.
    # @return [Boolean]
    # @api private
    def self.signup_body_self_only_acl_safe?(body)
      return false unless body.is_a?(Hash)
      oid = body[:objectId] || body["objectId"]
      acl = body[:ACL] || body["ACL"]
      return false unless oid.is_a?(String) && oid.match?(PARSE_OBJECT_ID_FORMAT)
      return false unless acl.is_a?(Hash) && acl.size == 1
      perms = acl[oid] || acl[oid.to_s]
      return false unless perms.is_a?(Hash)
      normalized = perms.transform_keys(&:to_s)
      normalized == { "read" => true, "write" => true }
    end

    # Body of {#create} when signup-on-save applies. Mirrors the inherited
    # Parse::Object create path but uses `create_user` (signup endpoint)
    # instead of `create_object`, and so picks up the `sessionToken` that
    # Parse Server only emits on the signup endpoint. Errors are not
    # promoted to typed exceptions here (see {#signup!} for that variant);
    # the response's success flag is returned so the caller's `save` /
    # `save!` handles the failure via the standard `RecordNotSaved` path.
    def signup_create
      run_callbacks :create do
        body = attribute_updates
        # Strip server-managed and special fields from the request body.
        # createdAt/updatedAt are always stripped (purely server-managed).
        # objectId/ACL are normally stripped too (to prevent a caller
        # planting a permissive ACL or a colliding objectId), but the
        # narrow self-only ownership pattern produced by
        # `acl_policy ..., owner: :self` is allowed through so the user
        # can be created with self-R/W-only ACL in a single roundtrip.
        if self.class.signup_body_self_only_acl_safe?(body)
          body.except!(:createdAt, :updatedAt, "createdAt", "updatedAt")
        else
          body.except!(*Parse::Properties::BASE_FIELD_MAP.flatten)
        end
        self.class.strip_server_controlled_keys!(body)
        # Anonymous signup: do NOT forward the caller's session token to
        # POST /parse/users. The caller may be authenticated for an
        # unrelated reason (e.g., an admin app session running a signup
        # flow on behalf of someone else), but the user being created is
        # by definition someone new. Forwarding `_session_token` makes
        # Cloud Code `beforeSave(_User)` see `request.user = caller`,
        # which an integrator can mistake for "the new user". The signup
        # endpoint authenticates by the signup itself, not by a prior
        # session — pass `nil` explicitly. Master key continues to flow
        # via the normal authentication middleware when configured.
        res = client.create_user(body, session_token: nil)
        unless res.error?
          result = res.result
          @id = result[Parse::Model::OBJECT_ID] || @id
          @created_at = result["createdAt"] || @created_at
          @updated_at = result["updatedAt"] || result["createdAt"] || @updated_at
          # Plaintext password is no longer needed locally; the server
          # has it hashed. Direct ivar assignment avoids re-dirtying the
          # field.
          @password = nil
          set_attributes!(result.slice(*SIGNUP_RESPONSE_APPLY_KEYS))
          # Promote the freshly-applied session token into `@_session_token`
          # so any in-flight after_create callback that calls back through
          # the SDK authenticates as the just-signed-up user. Without this,
          # the after_create `_assign_<field>!` callback installed by
          # `parse_reference` (and any other after_create hook that issues
          # an `update!`) reads `_session_token` (actions.rb:732) and finds
          # nil — `client.update_object(..., session_token: nil)` then
          # silently falls back to the master key under any configuration
          # that supplies one (client.rb:682-687 only attaches the session
          # token when `present?`; `DISABLE_MASTER_KEY` is not set on the
          # nil branch). The result was a user-scoped PUT silently
          # escalated to master-key authority, bypassing CLP and
          # `request.user` checks in `beforeSave` cloud code. Promoting
          # the new user's own session token here scopes the follow-up
          # update to the just-created user — the appropriate authority
          # for writes to their own row. The outer `save` zeroes
          # `@_session_token` again at actions.rb:830, so the promotion
          # is bounded by this in-flight save. The trust boundary here
          # is identical to the existing `SIGNUP_RESPONSE_APPLY_KEYS`
          # contract: the SDK already trusts `sessionToken` from a signup
          # response (it has to, to honor the signup contract); this fix
          # routes that same token to the in-flight auth context.
          @_session_token = @session_token if @session_token.present?
          # Clear dirty state BEFORE the `after_create` callback chain
          # fires. If a subclass declares `parse_reference` (default
          # field name with `precompute: false`), the after_create
          # `_assign_<field>!` callback issues an `update!` from inside
          # this `run_callbacks :create` block — and `attribute_updates`
          # would otherwise still carry `password` as dirty with a nil
          # current value, serializing as `password: { __op: "Delete" }`.
          # Parse Server's `_User` write path feeds that hash to
          # `@node-rs/bcrypt`, which raises
          # `Value is non of these types TypedArray<u8>, String`. Same
          # cleanup as `signup!`, just timed so the after_create
          # callbacks see a clean dirty set.
          changes_applied!
          clear_partial_fetch_state!
        end
        puts "Error creating #{self.parse_class}: #{res.error}" if res.error?
        res.success?
      end
    end
  end
end
