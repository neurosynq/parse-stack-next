# encoding: UTF-8
# frozen_string_literal: true

require_relative "../two_factor_auth"
require_relative "../model/phone"

module Parse
  module MFA
    # User extension module that adds MFA capabilities to Parse::User.
    #
    # This module integrates with Parse Server's built-in MFA adapter,
    # which stores MFA data in the user's authData.mfa field.
    #
    # == Parse Server Configuration Required
    #
    # Your Parse Server must have MFA enabled in the auth configuration:
    #
    #   {
    #     auth: {
    #       mfa: {
    #         enabled: true,
    #         options: ["TOTP"],
    #         digits: 6,
    #         period: 30,
    #         algorithm: "SHA1"
    #       }
    #     }
    #   }
    #
    # @see Parse::MFA
    module UserExtension
      extend ActiveSupport::Concern

      # Class methods added to Parse::User
      module ClassMethods
        # Login a user with username, password, and MFA token.
        #
        # This method handles the Parse Server MFA "additional" policy,
        # which requires both standard credentials AND an MFA token.
        #
        # @param username [String] The username
        # @param password [String] The password
        # @param mfa_token [String] The TOTP code from authenticator app or recovery code
        # @return [User, nil] The logged in user or nil if failed
        # @raise [Parse::MFA::VerificationError] If MFA token is invalid
        # @raise [Parse::MFA::RequiredError] If MFA is required but token not provided
        #
        # @example
        #   user = Parse::User.login_with_mfa("john", "password123", "123456")
        def login_with_mfa(username, password, mfa_token)
          raise MFA::RequiredError, "MFA token is required" if mfa_token.blank?

          response = client.login_with_mfa(username, password, mfa_token)
          return nil unless response.success?

          # Self-fetch trust: an MFA login returns the authenticating
          # user's own row, so authData here is legitimately theirs.
          Parse::User.with_authdata_trust { Parse::User.build(response.result) }
        rescue Parse::Client::ResponseError => e
          if e.message.include?("Invalid MFA token") || e.message.include?("Missing additional authData")
            raise MFA::VerificationError, e.message
          end
          raise
        end

        # Check if a user requires MFA for login.
        #
        # This queries the user's authData.mfa status using the afterFind hook
        # which returns { status: "enabled" } or { status: "disabled" }.
        #
        # @param username [String] The username to check
        # @return [Boolean] True if MFA is required
        #
        # @example
        #   if Parse::User.mfa_required?("john")
        #     # Show MFA input field
        #   end
        def mfa_required?(username)
          user = where(username: username).first
          return false unless user

          user.mfa_enabled?
        end
      end

      # Check if MFA is enabled for this user.
      #
      # @return [Boolean] True if MFA is enabled
      def mfa_enabled?
        return false unless auth_data.is_a?(Hash)
        return false unless auth_data["mfa"].is_a?(Hash)

        # Parse Server's afterFind returns { status: "enabled" } for enabled MFA
        mfa_data = auth_data["mfa"]
        mfa_data["status"] == "enabled" || mfa_data["secret"].present? || mfa_data["mobile"].present?
      end

      # Get the MFA status for this user.
      #
      # @return [Symbol] :enabled, :disabled, or :unknown
      def mfa_status
        return :unknown unless auth_data.is_a?(Hash)
        return :disabled unless auth_data["mfa"].is_a?(Hash)

        mfa_data = auth_data["mfa"]
        if mfa_data["status"]
          mfa_data["status"].to_sym
        elsif mfa_data["secret"].present? || mfa_data["mobile"].present?
          :enabled
        else
          :disabled
        end
      end

      # Setup TOTP-based MFA for this user.
      #
      # This sends the secret and verification token to Parse Server,
      # which validates the TOTP and stores the secret securely.
      #
      # @param secret [String] Base32-encoded TOTP secret (generate with MFA.generate_secret)
      # @param token [String] Current TOTP code for verification (user enters from app)
      # @return [String, nil] Recovery codes (comma-separated) - SAVE THESE!
      #   May be nil if the Parse Server response does not include them.
      # @raise [Parse::MFA::VerificationError] If token is invalid
      # @raise [Parse::MFA::AlreadyEnabledError] If MFA is already enabled
      # @raise [ArgumentError] If secret or token is blank
      #
      # @example
      #   secret = Parse::MFA.generate_secret
      #   # Show QR code to user: Parse::MFA.qr_code(secret, user.email)
      #   # User scans and enters code from authenticator app
      #   recovery = user.setup_mfa!(secret: secret, token: "123456")
      #   puts "Save these recovery codes: #{recovery}"
      def setup_mfa!(secret:, token:)
        raise ArgumentError, "Secret is required" if secret.blank?
        raise ArgumentError, "Token is required" if token.blank?
        # Refresh authData from the server before gating on mfa_enabled?
        # so a stale in-memory user does not bypass the local guard. This
        # narrows the race window from "any time the user object is alive"
        # to "one round-trip" — it does not eliminate TOCTOU. Full
        # elimination requires the Parse Server MFA adapter to reject
        # re-setup when authData.mfa.status == "enabled".
        fetch if id.present?
        raise MFA::AlreadyEnabledError if mfa_enabled?

        # Validate secret length (Parse Server requires minimum 20 chars)
        if secret.length < 20
          raise ArgumentError, "Secret must be at least 20 characters (got #{secret.length})"
        end

        auth_data_payload = {
          mfa: {
            secret: secret,
            token: token,
          },
        }

        response = client.update_user(id, { authData: auth_data_payload }, opts: { session_token: session_token })

        if response.error?
          if response.result.to_s.include?("Invalid MFA")
            raise MFA::VerificationError, response.result.to_s
          end
          raise Parse::Client::ResponseError, response
        end

        # Parse Server returns recovery codes in the response
        recovery = response.result["recovery"] || response.result["authDataResponse"]&.dig("mfa", "recovery")

        # Refresh auth_data
        fetch

        recovery
      end

      # Setup SMS-based MFA for this user.
      #
      # This initiates SMS MFA setup by registering the mobile number.
      # Parse Server will send an SMS with a verification code.
      #
      # @param mobile [String, Parse::Phone] Phone number in E.164 format (e.g., "+14155551234")
      # @return [Boolean] True if SMS was sent
      # @raise [ArgumentError] If mobile is blank or invalid format
      #
      # @example
      #   user.setup_sms_mfa!(mobile: "+14155551234")
      #   # User receives SMS, then call confirm_sms_mfa!
      def setup_sms_mfa!(mobile:)
        raise ArgumentError, "Mobile number is required" if mobile.blank?

        # Use Parse::Phone for validation
        phone = mobile.is_a?(Parse::Phone) ? mobile : Parse::Phone.new(mobile)
        unless phone.valid?
          raise ArgumentError, "Invalid mobile number format. Must be E.164 format: +[country code][number] (e.g., +14155551234)"
        end

        mobile = phone.to_s  # Use normalized E.164 format

        # Same TOCTOU narrowing as #setup_mfa!: refresh authData before
        # the guard so a stale in-memory user cannot bypass the check.
        # See #setup_mfa! for the residual-risk caveat.
        fetch if id.present?
        raise MFA::AlreadyEnabledError if mfa_enabled?

        auth_data_payload = {
          mfa: {
            mobile: mobile,
          },
        }

        response = client.update_user(id, { authData: auth_data_payload }, opts: { session_token: session_token })

        if response.error?
          raise Parse::Client::ResponseError, response
        end

        true
      end

      # Confirm SMS MFA setup with the received code.
      #
      # @param mobile [String, Parse::Phone] The mobile number that was used in setup (E.164 format)
      # @param token [String] The SMS code received
      # @return [Boolean] True if confirmed successfully
      # @raise [Parse::MFA::VerificationError] If token is invalid or expired
      #
      # @example
      #   user.confirm_sms_mfa!(mobile: "+14155551234", token: "123456")
      def confirm_sms_mfa!(mobile:, token:)
        raise ArgumentError, "Mobile number is required" if mobile.blank?
        raise ArgumentError, "Token is required" if token.blank?

        # Use Parse::Phone for validation
        phone = mobile.is_a?(Parse::Phone) ? mobile : Parse::Phone.new(mobile)
        unless phone.valid?
          raise ArgumentError, "Invalid mobile number format. Must be E.164 format: +[country code][number] (e.g., +14155551234)"
        end

        mobile = phone.to_s  # Use normalized E.164 format

        auth_data_payload = {
          mfa: {
            mobile: mobile,
            token: token,
          },
        }

        response = client.update_user(id, { authData: auth_data_payload }, opts: { session_token: session_token })

        if response.error?
          if response.result.to_s.include?("Invalid MFA token")
            raise MFA::VerificationError, response.result.to_s
          end
          raise Parse::Client::ResponseError, response
        end

        # Refresh auth_data
        fetch

        true
      end

      # Disable MFA for this user.
      #
      # This requires a valid current MFA token (TOTP or recovery code)
      # to verify the user's identity before disabling MFA.
      #
      # @param current_token [String] Current TOTP code or recovery code
      # @return [Boolean] True if disabled successfully
      # @raise [Parse::MFA::VerificationError] If token is invalid
      # @raise [Parse::MFA::NotEnabledError] If MFA is not enabled
      #
      # @example
      #   user.disable_mfa!(current_token: "123456")
      def disable_mfa!(current_token:)
        raise MFA::NotEnabledError, "MFA is not enabled for this user" unless mfa_enabled?
        raise ArgumentError, "Current token is required" if current_token.blank?

        # To disable, we need to update authData.mfa with the old token for validation
        # and then set it to null
        auth_data_payload = {
          mfa: {
            old: current_token,
            secret: nil,  # Setting to nil disables TOTP
          },
        }

        response = client.update_user(id, { authData: auth_data_payload }, opts: { session_token: session_token })

        if response.error?
          if response.result.to_s.include?("Invalid MFA token")
            raise MFA::VerificationError, response.result.to_s
          end
          raise Parse::Client::ResponseError, response
        end

        # Refresh auth_data
        fetch

        true
      end

      # Disable MFA using the configured master key. This bypasses MFA
      # verification entirely, so the caller must prove (out-of-band) that
      # the operator initiating the disable is authorized to do so.
      #
      # The +authorized_by:+ keyword is required and must be a
      # {Parse::User} (or {Parse::Pointer} to a User) representing the
      # operator performing the override. The caller is responsible for
      # verifying that operator's privileges (e.g. via a role check). An
      # optional +admin_role:+ argument lets this method enforce a role
      # membership check on the operator using the existing role-hierarchy
      # support; when given, the operator must belong to the role (or any
      # of its child roles) or +ForbiddenError+ is raised.
      #
      # @param authorized_by [Parse::User, Parse::Pointer] the operator
      #   performing the override. Required.
      # @param admin_role [Parse::Role, String, nil] optional role (or role
      #   name) that +authorized_by+ must belong to.
      # @return [Boolean] True if disabled successfully.
      # @raise [ArgumentError] when +authorized_by:+ is missing or not a User.
      # @raise [Parse::MFA::ForbiddenError] when +admin_role+ is supplied
      #   and the operator is not a member.
      #
      # @example Caller-verified authorization
      #   user.disable_mfa_master_key!(authorized_by: current_admin)
      #
      # @example Library-enforced role check
      #   user.disable_mfa_master_key!(authorized_by: current_admin,
      #                                admin_role: "Admin")
      def disable_mfa_master_key!(authorized_by:, admin_role: nil)
        operator = authorized_by
        unless operator.is_a?(Parse::User) ||
               (operator.is_a?(Parse::Pointer) && operator.parse_class == Parse::User.parse_class)
          raise ArgumentError,
                "disable_mfa_master_key! requires authorized_by: to be a Parse::User " \
                "or Parse::Pointer to a User (got #{operator.class})"
        end
        if operator.respond_to?(:id) && operator.id.blank?
          raise ArgumentError, "authorized_by: User must be persisted (have an objectId)"
        end

        if admin_role
          role = admin_role.is_a?(Parse::Role) ? admin_role : Parse::Role.find_by_name(admin_role.to_s)
          if role.nil?
            raise MFA::ForbiddenError,
                  "authorized_by user is not authorized: admin role " \
                  "#{admin_role.inspect} not found"
          end
          operator_id = operator.id
          authorized = role.all_users.any? { |u| u.id == operator_id }
          unless authorized
            raise MFA::ForbiddenError,
                  "authorized_by user #{operator_id} is not a member of " \
                  "role #{role.name.inspect}"
          end
        end

        auth_data_payload = { mfa: nil }
        response = client.update_user(id, { authData: auth_data_payload }, opts: { use_master_key: true })

        if response.error?
          raise Parse::Client::ResponseError, response
        end

        # Refresh auth_data
        fetch

        true
      end

      # @deprecated Use {#disable_mfa_master_key!} with an explicit
      #   +authorized_by:+ argument. The old name had no authorization gate
      #   and acted as a one-call IDOR primitive when invoked on an
      #   attacker-controlled user instance.
      def disable_mfa_admin!(*args, **kwargs)
        warn "[DEPRECATION] `disable_mfa_admin!` is deprecated; use " \
             "`disable_mfa_master_key!(authorized_by: <admin user>)`."
        disable_mfa_master_key!(*args, **kwargs)
      end

      # Login this user instance with password and MFA token.
      #
      # @param password [String] The password
      # @param mfa_token [String] The TOTP code or recovery code
      # @return [Boolean] True if login successful
      # @raise [Parse::MFA::RequiredError] If MFA required but not provided
      # @raise [Parse::MFA::VerificationError] If MFA token is invalid
      #
      # @example
      #   user = Parse::User.first
      #   user.login_with_mfa!("password123", "123456")
      def login_with_mfa!(password, mfa_token = nil)
        response = client.login_with_mfa(username.to_s, password.to_s, mfa_token)
        apply_attributes!(response.result)
        session_token.present?
      rescue Parse::Client::ResponseError => e
        if e.message.include?("Missing additional authData")
          raise MFA::RequiredError, "MFA token is required for this account"
        elsif e.message.include?("Invalid MFA token")
          raise MFA::VerificationError, e.message
        end
        raise
      end

      # Generate a provisioning URI for this user.
      #
      # Use this to create a QR code for the user to scan with their
      # authenticator app.
      #
      # @param secret [String] The TOTP secret
      # @param issuer [String] Optional custom issuer name
      # @return [String] otpauth:// URI
      #
      # @example
      #   secret = Parse::MFA.generate_secret
      #   uri = user.mfa_provisioning_uri(secret, issuer: "MyApp")
      def mfa_provisioning_uri(secret, issuer: nil)
        account_name = email.presence || username.presence || id
        MFA.provisioning_uri(secret, account_name, issuer: issuer)
      end

      # Generate a QR code for MFA setup.
      #
      # @param secret [String] The TOTP secret
      # @param issuer [String] Optional custom issuer name
      # @param format [Symbol] Output format (:svg, :png, :ascii)
      # @return [String] QR code in specified format
      #
      # @example
      #   secret = Parse::MFA.generate_secret
      #   qr_svg = user.mfa_qr_code(secret, issuer: "MyApp")
      #   # Render in HTML: <%= raw qr_svg %>
      def mfa_qr_code(secret, issuer: nil, format: :svg)
        account_name = email.presence || username.presence || id
        MFA.qr_code(secret, account_name, issuer: issuer, format: format)
      end
    end

    # Not enabled error
    class NotEnabledError < Parse::Error
      def initialize(message = "MFA is not enabled for this user")
        super(message)
      end
    end
  end

  # Reopen User class to include MFA extension
  class User
    include MFA::UserExtension
  end
end
