# encoding: UTF-8
# frozen_string_literal: true

module Parse
  # Multi-Factor Authentication (MFA) support for Parse Server.
  #
  # This module interfaces with Parse Server's built-in MFA adapter which supports
  # TOTP (Time-based One-Time Password) and SMS-based authentication.
  #
  # == Parse Server Configuration
  #
  # MFA must be enabled in your Parse Server configuration:
  #
  #   {
  #     auth: {
  #       mfa: {
  #         enabled: true,
  #         options: ["TOTP"],  // or ["SMS", "TOTP"]
  #         digits: 6,
  #         period: 30,
  #         algorithm: "SHA1"
  #       }
  #     }
  #   }
  #
  # == TOTP Setup Flow
  #
  # 1. Generate a secret client-side using {MFA.generate_secret}
  # 2. Display QR code to user using {MFA.provisioning_uri} or {MFA.qr_code}
  # 3. User scans QR with authenticator app (Google Authenticator, Authy, etc.)
  # 4. User enters the 6-digit code from their app
  # 5. Call {User#setup_mfa!} with secret and token to enable MFA
  # 6. Store the recovery codes returned - user needs these for account recovery!
  #
  # @example Enable TOTP MFA for a user
  #   # Step 1: Generate secret
  #   secret = Parse::MFA.generate_secret
  #
  #   # Step 2: Show QR code to user
  #   qr_svg = Parse::MFA.qr_code(secret, user.email, issuer: "MyApp")
  #   # render qr_svg in your UI
  #
  #   # Step 3-4: User scans and enters code
  #   token = params[:totp_code]  # "123456" from authenticator app
  #
  #   # Step 5: Enable MFA
  #   recovery_codes = user.setup_mfa!(secret: secret, token: token)
  #   # => "ABC123DEF456..., XYZ789..."
  #
  #   # Step 6: Show recovery codes to user (one time only!)
  #
  # @example Login with MFA
  #   user = Parse::User.login_with_mfa("username", "password", "123456")
  #
  # @see https://github.com/parse-community/parse-server/blob/master/src/Adapters/Auth/mfa.js
  #
  module MFA
    # Error raised when MFA verification fails
    class VerificationError < Parse::Error
      def initialize(message = "Invalid MFA token")
        super(message)
      end
    end

    # Error raised when MFA is required but not provided
    class RequiredError < Parse::Error
      def initialize(message = "MFA token is required for this account")
        super(message)
      end
    end

    # Error raised when MFA is already set up
    class AlreadyEnabledError < Parse::Error
      def initialize(message = "MFA is already set up on this account")
        super(message)
      end
    end

    # Error raised when required gem is not available
    class DependencyError < Parse::Error
      def initialize(gem_name)
        super("The '#{gem_name}' gem is required for this feature. Add to Gemfile: gem '#{gem_name}'")
      end
    end

    # Default configuration
    DEFAULT_CONFIG = {
      issuer: "Parse App",
      digits: 6,
      period: 30,
      algorithm: "SHA1",
      secret_length: 20,  # Minimum required by Parse Server
    }.freeze

    class << self
      # Global MFA configuration
      # @return [Hash]
      def config
        @config ||= DEFAULT_CONFIG.dup
      end

      # Configure MFA settings
      # @yield [config] Configuration hash
      # @example
      #   Parse::MFA.configure do |config|
      #     config[:issuer] = "My App"
      #   end
      def configure
        yield config if block_given?
        config
      end

      # Check if rotp gem is available
      # @return [Boolean]
      def rotp_available?
        require "rotp"
        true
      rescue LoadError
        false
      end

      # Check if rqrcode gem is available
      # @return [Boolean]
      def rqrcode_available?
        require "rqrcode"
        true
      rescue LoadError
        false
      end

      # Generate a new TOTP secret for MFA setup.
      # The secret must be at least 20 characters (Parse Server requirement).
      #
      # @param length [Integer] Secret length (minimum 20)
      # @return [String] Base32-encoded secret
      #
      # @example
      #   secret = Parse::MFA.generate_secret
      #   # => "JBSWY3DPEHPK3PXP4QFAZJ7K"
      def generate_secret(length: nil)
        ensure_rotp!
        length ||= config[:secret_length]
        length = [length, 20].max  # Parse Server requires minimum 20
        ROTP::Base32.random(length)
      end

      # Create a TOTP instance for verification.
      #
      # @param secret [String] Base32-encoded secret
      # @param issuer [String] Optional issuer name
      # @return [ROTP::TOTP]
      def totp(secret, issuer: nil)
        ensure_rotp!
        ROTP::TOTP.new(
          secret,
          issuer: issuer || config[:issuer],
          interval: config[:period],
          digits: config[:digits],
        )
      end

      # Verify a TOTP code locally (for testing/validation before sending to server).
      #
      # @param secret [String] Base32-encoded secret
      # @param code [String] The 6-digit code to verify
      # @return [Boolean] True if valid
      #
      # @example
      #   if Parse::MFA.verify(secret, "123456")
      #     puts "Code is valid!"
      #   end
      def verify(secret, code)
        return false if secret.blank? || code.blank?

        ensure_rotp!
        drift_seconds = config[:period]
        totp_instance = totp(secret)
        totp_instance.verify(code.to_s, drift_behind: drift_seconds, drift_ahead: drift_seconds).present?
      end

      # Get the current TOTP code (for testing/debugging).
      #
      # @param secret [String] Base32-encoded secret
      # @return [String] Current 6-digit code
      def current_code(secret)
        ensure_rotp!
        totp(secret).now
      end

      # Generate provisioning URI for authenticator apps.
      #
      # @param secret [String] Base32-encoded secret
      # @param account_name [String] User identifier (email or username)
      # @param issuer [String] Optional issuer override
      # @return [String] otpauth:// URI
      #
      # @example
      #   uri = Parse::MFA.provisioning_uri(secret, "user@example.com", issuer: "MyApp")
      #   # => "otpauth://totp/MyApp:user@example.com?secret=ABC123&issuer=MyApp"
      def provisioning_uri(secret, account_name, issuer: nil)
        ensure_rotp!
        totp(secret, issuer: issuer).provisioning_uri(account_name)
      end

      # Generate a QR code for the authenticator app.
      #
      # @param secret [String] Base32-encoded secret
      # @param account_name [String] User identifier
      # @param issuer [String] Optional issuer name
      # @param format [Symbol] Output format (:svg, :png, :ascii)
      # @return [String] QR code in specified format
      #
      # @example
      #   svg = Parse::MFA.qr_code(secret, user.email, issuer: "MyApp")
      #   # Render in HTML: <%= raw svg %>
      def qr_code(secret, account_name, issuer: nil, format: :svg)
        ensure_rqrcode!
        uri = provisioning_uri(secret, account_name, issuer: issuer)
        qr = RQRCode::QRCode.new(uri)

        case format
        when :svg
          qr.as_svg(
            color: "000",
            shape_rendering: "crispEdges",
            module_size: 4,
            standalone: true,
          )
        when :png
          qr.as_png(size: 300)
        when :ascii
          qr.as_ansi
        else
          qr.as_svg
        end
      end

      # Build authData hash for MFA setup.
      #
      # @param secret [String] Base32-encoded TOTP secret
      # @param token [String] Current TOTP code for verification
      # @return [Hash] authData for Parse Server
      def build_setup_auth_data(secret:, token:)
        {
          mfa: {
            secret: secret,
            token: token,
          },
        }
      end

      # Build authData hash for MFA login.
      #
      # @param token [String] TOTP code or recovery code
      # @return [Hash] authData for Parse Server
      def build_login_auth_data(token:)
        {
          mfa: {
            token: token,
          },
        }
      end

      # Build authData hash for SMS MFA setup.
      #
      # @param mobile [String] Phone number in E.164 format
      # @return [Hash] authData for Parse Server
      def build_sms_setup_auth_data(mobile:)
        {
          mfa: {
            mobile: mobile,
          },
        }
      end

      # Build authData hash for SMS MFA confirmation.
      #
      # @param mobile [String] Phone number
      # @param token [String] SMS code received
      # @return [Hash] authData for Parse Server
      def build_sms_confirm_auth_data(mobile:, token:)
        {
          mfa: {
            mobile: mobile,
            token: token,
          },
        }
      end

      private

      def ensure_rotp!
        raise DependencyError.new("rotp") unless rotp_available?
      end

      def ensure_rqrcode!
        raise DependencyError.new("rqrcode") unless rqrcode_available?
      end
    end
  end
end
