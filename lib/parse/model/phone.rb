# encoding: UTF-8
# frozen_string_literal: true

require_relative "model"

# Try to load phonelib for enhanced validation
begin
  require "phonelib"
  PHONELIB_AVAILABLE = true
rescue LoadError
  PHONELIB_AVAILABLE = false
end

module Parse
  # This class provides E.164 phone number validation and formatting for Parse properties.
  # E.164 is the international telephone numbering format that ensures worldwide uniqueness.
  #
  # Format: +[country code][subscriber number]
  # - Must start with +
  # - Country code: 1-3 digits (cannot start with 0)
  # - Subscriber number: remaining digits
  # - Total length: 8-15 digits (including country code)
  #
  # == Enhanced Validation with phonelib
  #
  # For comprehensive phone number validation (including carrier validation, number type
  # detection, and accurate country-specific rules), add the `phonelib` gem to your Gemfile:
  #
  #   gem 'phonelib'
  #
  # When phonelib is available, Parse::Phone will use Google's libphonenumber data for:
  # - Accurate validation for all countries and territories
  # - Number type detection (mobile, landline, toll-free, etc.)
  # - Carrier information
  # - Proper formatting per country standards
  #
  # Without phonelib, basic E.164 format validation is used (sufficient for most use cases).
  #
  # @example Basic usage
  #   class Contact < Parse::Object
  #     property :mobile, :phone
  #     property :work_phone, :phone, required: true
  #   end
  #
  #   contact = Contact.new
  #   contact.mobile = "+14155551234"
  #   contact.mobile.valid?        # => true
  #   contact.mobile.country_code  # => "1"
  #   contact.mobile.national      # => "4155551234"
  #
  #   contact.mobile = "invalid"
  #   contact.mobile.valid?        # => false
  #
  #   contact.mobile = "+1 (415) 555-1234"  # Automatically cleaned
  #   contact.mobile.to_s          # => "+14155551234"
  #
  # @example With phonelib (enhanced features)
  #   phone = Parse::Phone.new("+14155551234")
  #   phone.phone_type    # => :mobile (requires phonelib)
  #   phone.carrier       # => "Verizon" (requires phonelib)
  #   phone.possible?     # => true (quick check, requires phonelib)
  #
  # @version 3.0.0
  class Phone
    # E.164 format regex (strict validation for fallback mode)
    # - Starts with +
    # - Country code: 1-3 digits, cannot start with 0
    # - Total digits: 8-15 (E.164 max is 15 digits total including country code)
    E164_REGEX = /\A\+[1-9]\d{6,14}\z/

    # Regex to strip non-digit characters (except +)
    STRIP_NON_DIGITS = /[^\d+]/

    class << self
      # Check if phonelib is available for enhanced validation
      # @return [Boolean] true if phonelib gem is loaded
      def phonelib_available?
        PHONELIB_AVAILABLE
      end

      # Type casting support for Parse properties.
      # This allows the property system to convert values to Phone instances.
      #
      # @param value [Object] the value to typecast
      # @return [Parse::Phone, nil] the Phone instance or nil
      # @api private
      def typecast(value)
        return nil if value.nil?
        return value if value.is_a?(Parse::Phone)
        Parse::Phone.new(value)
      end
    end

    # @return [String] the raw input value
    attr_reader :raw

    # @return [String] the normalized E.164 formatted number (or nil if invalid input)
    attr_reader :number

    # Creates a new Phone instance.
    #
    # @overload new(number)
    #   @param number [String] a phone number (will be normalized to E.164)
    #   @return [Parse::Phone]
    # @overload new(phone)
    #   @param phone [Parse::Phone] another Phone instance to copy
    #   @return [Parse::Phone]
    #
    # @example
    #   Parse::Phone.new("+14155551234")
    #   Parse::Phone.new("1-415-555-1234")  # Will add + prefix
    #   Parse::Phone.new("+1 (415) 555-1234")  # Will clean formatting
    def initialize(value)
      @raw = nil
      @number = nil
      @phonelib_phone = nil

      if value.is_a?(String)
        @raw = value
        @number = normalize(value)
      elsif value.is_a?(Parse::Phone)
        @raw = value.raw
        @number = value.number
      elsif value.respond_to?(:to_s) && !value.nil?
        @raw = value.to_s
        @number = normalize(@raw)
      end

      # Parse with phonelib if available
      @phonelib_phone = Phonelib.parse(@number) if PHONELIB_AVAILABLE && @number
    end

    # Normalize a phone number string to E.164 format.
    # Removes all non-digit characters except leading +.
    #
    # @param value [String] the phone number string
    # @return [String, nil] the normalized number or nil if invalid
    def normalize(value)
      return nil if value.blank?

      # Remove all non-digit characters except +
      cleaned = value.to_s.gsub(STRIP_NON_DIGITS, "")

      # If it doesn't start with +, add it
      cleaned = "+#{cleaned}" unless cleaned.start_with?("+")

      # Return the cleaned value (may still be invalid, but we store it)
      cleaned
    end

    # @return [String, nil] the E.164 formatted phone number
    def to_s
      @number
    end

    # @return [String, nil] the E.164 formatted phone number for JSON serialization
    def as_json(*args)
      @number
    end

    # Check if this phone number is valid E.164 format.
    # When phonelib is available, uses comprehensive validation.
    # Otherwise, uses basic E.164 regex validation.
    #
    # @return [Boolean] true if the phone number is valid
    #
    # @example
    #   Parse::Phone.new("+14155551234").valid?  # => true
    #   Parse::Phone.new("invalid").valid?       # => false
    #   Parse::Phone.new("+1").valid?            # => false (too short)
    def valid?
      return false if @number.blank?

      if PHONELIB_AVAILABLE && @phonelib_phone
        @phonelib_phone.valid?
      else
        E164_REGEX.match?(@number)
      end
    end

    # Check if the phone number is possibly valid (quick check).
    # This is faster than full validation and useful for input feedback.
    # Falls back to valid? when phonelib is not available.
    #
    # @return [Boolean] true if the number could be valid
    def possible?
      return false if @number.blank?

      if PHONELIB_AVAILABLE && @phonelib_phone
        @phonelib_phone.possible?
      else
        valid?
      end
    end

    # Check if the phone number is invalid.
    #
    # @return [Boolean] true if the phone number is definitely invalid
    def invalid?
      !valid?
    end

    # Get the country code portion of the phone number.
    #
    # @return [String, nil] the country code (without +) or nil if invalid
    #
    # @example
    #   Parse::Phone.new("+14155551234").country_code  # => "1"
    #   Parse::Phone.new("+442071234567").country_code # => "44"
    def country_code
      return nil unless valid?

      if PHONELIB_AVAILABLE && @phonelib_phone
        @phonelib_phone.country_code
      else
        extract_country_code_fallback
      end
    end

    # Get the two-letter ISO country code.
    # Requires phonelib for accurate detection.
    #
    # @return [String, nil] the ISO 3166-1 alpha-2 country code (e.g., "US", "GB")
    #
    # @example
    #   Parse::Phone.new("+14155551234").country  # => "US" (with phonelib)
    def country
      return nil unless PHONELIB_AVAILABLE && @phonelib_phone&.valid?
      @phonelib_phone.country
    end

    # Get the national (subscriber) number without country code.
    #
    # @return [String, nil] the national number or nil if invalid
    #
    # @example
    #   Parse::Phone.new("+14155551234").national  # => "4155551234"
    def national
      return nil unless valid?

      if PHONELIB_AVAILABLE && @phonelib_phone
        @phonelib_phone.national(false)&.gsub(/\D/, "")
      else
        cc = country_code
        return nil unless cc
        @number[(cc.length + 1)..]  # Skip + and country code
      end
    end

    # Get the phone number type (mobile, landline, etc.).
    # Requires phonelib for type detection.
    #
    # @return [Symbol, nil] the number type (:mobile, :fixed_line, :toll_free, etc.)
    #
    # @example
    #   Parse::Phone.new("+14155551234").phone_type  # => :mobile (with phonelib)
    def phone_type
      return nil unless PHONELIB_AVAILABLE && @phonelib_phone&.valid?
      types = @phonelib_phone.types
      types.first if types.any?
    end

    # Check if this is a mobile phone number.
    # Requires phonelib for accurate detection.
    #
    # @return [Boolean, nil] true if mobile, false if not, nil if unknown
    def mobile?
      type = phone_type
      return nil if type.nil?
      [:mobile, :fixed_or_mobile].include?(type)
    end

    # Get the carrier name for this phone number.
    # Requires phonelib and may not be available for all numbers.
    #
    # @return [String, nil] the carrier name or nil
    def carrier
      return nil unless PHONELIB_AVAILABLE && @phonelib_phone&.valid?
      @phonelib_phone.carrier
    end

    # Get the geographic area for this phone number.
    # Requires phonelib and may not be available for mobile numbers.
    #
    # @return [String, nil] the geographic area or nil
    def geo_name
      return nil unless PHONELIB_AVAILABLE && @phonelib_phone&.valid?
      @phonelib_phone.geo_name
    end

    # Get the country/region name for this phone number's country code.
    #
    # @return [String, nil] the country/region name or nil if unknown
    #
    # @example
    #   Parse::Phone.new("+14155551234").country_name  # => "United States"
    #   Parse::Phone.new("+442071234567").country_name # => "United Kingdom"
    def country_name
      if PHONELIB_AVAILABLE && @phonelib_phone&.valid?
        iso_code = @phonelib_phone.country
        ISO_COUNTRY_NAMES[iso_code] if iso_code
      else
        cc = country_code
        FALLBACK_COUNTRY_NAMES[cc] if cc
      end
    end

    # Format the phone number for display.
    # When phonelib is available, uses proper country-specific formatting.
    # Otherwise, provides basic formatted version.
    #
    # @param format [Symbol] :international (default), :national, or :e164
    # @return [String, nil] formatted number or nil if invalid
    #
    # @example
    #   Parse::Phone.new("+14155551234").formatted             # => "+1 415-555-1234"
    #   Parse::Phone.new("+14155551234").formatted(:national)  # => "(415) 555-1234"
    def formatted(format = :international)
      return nil unless valid?

      if PHONELIB_AVAILABLE && @phonelib_phone
        case format
        when :national
          @phonelib_phone.national
        when :e164
          @phonelib_phone.e164
        else
          @phonelib_phone.international
        end
      else
        format_fallback
      end
    end

    # Check equality with another phone number.
    #
    # @param other [Parse::Phone, String] the other phone number
    # @return [Boolean] true if the numbers are equal
    def ==(other)
      if other.is_a?(Parse::Phone)
        @number == other.number
      elsif other.is_a?(String)
        @number == normalize(other)
      else
        false
      end
    end

    # @return [Boolean] true if the phone number is blank/nil
    def blank?
      @number.blank?
    end

    # @return [Boolean] true if the phone number is present
    def present?
      !blank?
    end

    # Get validation errors for this phone number.
    # Useful for providing user feedback.
    #
    # @return [Array<String>] array of error messages
    def errors
      return [] if valid?
      return ["Phone number is required"] if @number.blank?

      if PHONELIB_AVAILABLE && @phonelib_phone
        result = []
        # Phonelib uses impossible? for basic length/format check
        if @phonelib_phone.impossible?
          sanitized = @phonelib_phone.sanitized
          result << "Phone number is too short" if sanitized.length < 7
          result << "Phone number is too long" if sanitized.length > 15
        end
        result << "Invalid phone number format" if result.empty?
        result
      else
        ["Invalid E.164 phone number format"]
      end
    end

    private

    # ISO 3166-1 alpha-2 country codes to names (for phonelib mode)
    ISO_COUNTRY_NAMES = {
      "AF" => "Afghanistan", "AL" => "Albania", "DZ" => "Algeria",
      "AR" => "Argentina", "AU" => "Australia", "AT" => "Austria",
      "BE" => "Belgium", "BR" => "Brazil", "CA" => "Canada",
      "CL" => "Chile", "CN" => "China", "CO" => "Colombia",
      "CZ" => "Czech Republic", "DK" => "Denmark", "EG" => "Egypt",
      "FI" => "Finland", "FR" => "France", "DE" => "Germany",
      "GR" => "Greece", "HU" => "Hungary", "IN" => "India",
      "ID" => "Indonesia", "IR" => "Iran", "IE" => "Ireland",
      "IL" => "Israel", "IT" => "Italy", "JP" => "Japan",
      "KZ" => "Kazakhstan", "KE" => "Kenya", "MY" => "Malaysia",
      "MX" => "Mexico", "MA" => "Morocco", "MM" => "Myanmar",
      "NL" => "Netherlands", "NZ" => "New Zealand", "NG" => "Nigeria",
      "NO" => "Norway", "PK" => "Pakistan", "PH" => "Philippines",
      "PL" => "Poland", "PT" => "Portugal", "RO" => "Romania",
      "RU" => "Russia", "SA" => "Saudi Arabia", "SG" => "Singapore",
      "SK" => "Slovakia", "ZA" => "South Africa", "KR" => "South Korea",
      "ES" => "Spain", "LK" => "Sri Lanka", "SE" => "Sweden",
      "CH" => "Switzerland", "TH" => "Thailand", "TN" => "Tunisia",
      "TR" => "Turkey", "AE" => "UAE", "GB" => "United Kingdom",
      "US" => "United States", "VN" => "Vietnam",
    }.freeze

    # Fallback country code extraction when phonelib is not available
    FALLBACK_COUNTRY_CODES = %w[
      1 7 20 27 30 31 32 33 34 36 39 40 41 43 44 45 46 47 48 49
      51 52 53 54 55 56 57 58 60 61 62 63 64 65 66 81 82 84 86
      90 91 92 93 94 95 98 212 213 216 218 220 221 222 223 224
      225 226 227 228 229 230 231 232 233 234 235 236 237 238
      239 240 241 242 243 244 245 246 247 248 249 250 251 252
      253 254 255 256 257 258 260 261 262 263 264 265 266 267
      268 269 290 291 297 298 299 350 351 352 353 354 355 356
      357 358 359 370 371 372 373 374 375 376 377 378 379 380
      381 382 383 385 386 387 389 420 421 423 500 501 502 503
      504 505 506 507 508 509 590 591 592 593 594 595 596 597
      598 599 670 672 673 674 675 676 677 678 679 680 681 682
      683 685 686 687 688 689 690 691 692 850 852 853 855 856
      880 886 960 961 962 963 964 965 966 967 968 970 971 972
      973 974 975 976 977 992 993 994 995 996 998
    ].freeze

    # Fallback country names for basic validation mode
    FALLBACK_COUNTRY_NAMES = {
      "1" => "North America",
      "7" => "Russia/Kazakhstan",
      "20" => "Egypt",
      "27" => "South Africa",
      "30" => "Greece",
      "31" => "Netherlands",
      "32" => "Belgium",
      "33" => "France",
      "34" => "Spain",
      "36" => "Hungary",
      "39" => "Italy",
      "40" => "Romania",
      "41" => "Switzerland",
      "43" => "Austria",
      "44" => "United Kingdom",
      "45" => "Denmark",
      "46" => "Sweden",
      "47" => "Norway",
      "48" => "Poland",
      "49" => "Germany",
      "52" => "Mexico",
      "54" => "Argentina",
      "55" => "Brazil",
      "56" => "Chile",
      "57" => "Colombia",
      "60" => "Malaysia",
      "61" => "Australia",
      "62" => "Indonesia",
      "63" => "Philippines",
      "64" => "New Zealand",
      "65" => "Singapore",
      "66" => "Thailand",
      "81" => "Japan",
      "82" => "South Korea",
      "84" => "Vietnam",
      "86" => "China",
      "90" => "Turkey",
      "91" => "India",
      "92" => "Pakistan",
      "93" => "Afghanistan",
      "94" => "Sri Lanka",
      "95" => "Myanmar",
      "98" => "Iran",
      "212" => "Morocco",
      "213" => "Algeria",
      "216" => "Tunisia",
      "234" => "Nigeria",
      "254" => "Kenya",
      "351" => "Portugal",
      "353" => "Ireland",
      "358" => "Finland",
      "420" => "Czech Republic",
      "421" => "Slovakia",
      "966" => "Saudi Arabia",
      "971" => "UAE",
      "972" => "Israel",
    }.freeze

    def extract_country_code_fallback
      return nil unless @number&.start_with?("+")
      digits = @number[1..]

      # Try longest match first (3-digit codes)
      [3, 2, 1].each do |len|
        code = digits[0, len]
        return code if FALLBACK_COUNTRY_CODES.include?(code)
      end

      # Default to first digit for unknown codes
      digits[0, 1]
    end

    def format_fallback
      cc = country_code
      nat = national
      return @number unless cc && nat

      case cc
      when "1" # North America: +1 415-555-1234
        if nat.length == 10
          "+#{cc} #{nat[0, 3]}-#{nat[3, 3]}-#{nat[6, 4]}"
        else
          @number
        end
      when "44" # UK: +44 20 7123 4567
        "+#{cc} #{nat[0, 2]} #{nat[2, 4]} #{nat[6..]}"
      else
        # Generic: +CC NNNNNNNNNN
        "+#{cc} #{nat}"
      end
    end
  end
end
