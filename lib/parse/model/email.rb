# encoding: UTF-8
# frozen_string_literal: true

require_relative "model"

module Parse
  # This class provides email validation for Parse properties.
  # It wraps a string value and provides validation according to RFC 5322.
  #
  # When declaring a property of type :email, the framework will automatically add a validation
  # to ensure the email is either nil or a valid email address format.
  #
  # @example
  #   class Contact < Parse::Object
  #     property :email, :email
  #     property :work_email, :email, required: true
  #   end
  #
  #   contact = Contact.new
  #   contact.email = "user@example.com"
  #   contact.email.valid?     # => true
  #   contact.email.local      # => "user"
  #   contact.email.domain     # => "example.com"
  #
  #   contact.email = "invalid"
  #   contact.email.valid?     # => false
  #
  # @version 3.0.0
  class Email
    # RFC 5322 compliant email regex (simplified but robust version)
    # This regex validates most common email formats while avoiding catastrophic backtracking.
    # For stricter validation, consider using a dedicated email validation library.
    EMAIL_REGEX = /\A[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\z/

    # Common disposable email domains (for optional filtering)
    DISPOSABLE_DOMAINS = %w[
      mailinator.com guerrillamail.com tempmail.com throwaway.email
      10minutemail.com fakeinbox.com trashmail.com
    ].freeze

    # @return [String] the raw input value
    attr_reader :raw

    # @return [String] the normalized email address (or nil if invalid input)
    attr_reader :address

    # Creates a new Email instance.
    #
    # @overload new(address)
    #   @param address [String] an email address
    #   @return [Parse::Email]
    # @overload new(email)
    #   @param email [Parse::Email] another Email instance to copy
    #   @return [Parse::Email]
    #
    # @example
    #   Parse::Email.new("user@example.com")
    #   Parse::Email.new("  USER@EXAMPLE.COM  ")  # Will normalize
    def initialize(value)
      @raw = nil
      @address = nil

      if value.is_a?(String)
        @raw = value
        @address = normalize(value)
      elsif value.is_a?(Parse::Email)
        @raw = value.raw
        @address = value.address
      elsif value.respond_to?(:to_s) && !value.nil?
        @raw = value.to_s
        @address = normalize(@raw)
      end
    end

    # Normalize an email address.
    # - Strips whitespace
    # - Converts to lowercase
    #
    # @param value [String] the email string
    # @return [String, nil] the normalized email or nil if blank
    def normalize(value)
      return nil if value.blank?
      value.to_s.strip.downcase
    end

    # @return [String, nil] the normalized email address
    def to_s
      @address
    end

    # @return [String, nil] the email address for JSON serialization
    def as_json(*args)
      @address
    end

    # Check if this email address is valid.
    #
    # @return [Boolean] true if the email is valid format
    #
    # @example
    #   Parse::Email.new("user@example.com").valid?  # => true
    #   Parse::Email.new("invalid").valid?           # => false
    def valid?
      return false if @address.blank?
      EMAIL_REGEX.match?(@address)
    end

    # Get the local part of the email (before @).
    #
    # @return [String, nil] the local part or nil if invalid
    #
    # @example
    #   Parse::Email.new("user@example.com").local  # => "user"
    def local
      return nil unless valid?
      @address.split("@").first
    end

    # Get the domain part of the email (after @).
    #
    # @return [String, nil] the domain or nil if invalid
    #
    # @example
    #   Parse::Email.new("user@example.com").domain  # => "example.com"
    def domain
      return nil unless valid?
      @address.split("@").last
    end

    # Get the top-level domain (TLD) of the email.
    #
    # @return [String, nil] the TLD or nil if invalid
    #
    # @example
    #   Parse::Email.new("user@example.com").tld  # => "com"
    #   Parse::Email.new("user@example.co.uk").tld  # => "uk"
    def tld
      d = domain
      return nil unless d
      d.split(".").last
    end

    # Check if this email is from a disposable email service.
    # Note: This is a basic check against a small list. For production use,
    # consider using a dedicated disposable email detection service.
    #
    # @return [Boolean] true if the domain is a known disposable email provider
    #
    # @example
    #   Parse::Email.new("user@mailinator.com").disposable?  # => true
    #   Parse::Email.new("user@gmail.com").disposable?       # => false
    def disposable?
      d = domain
      return false unless d
      DISPOSABLE_DOMAINS.include?(d)
    end

    # Format the email with the local part obscured for privacy.
    #
    # @return [String, nil] the masked email or nil if invalid
    #
    # @example
    #   Parse::Email.new("username@example.com").masked  # => "u***e@example.com"
    def masked
      return nil unless valid?
      l = local
      d = domain
      return nil unless l && d

      if l.length <= 2
        "#{l[0]}*@#{d}"
      else
        "#{l[0]}#{"*" * [l.length - 2, 3].min}#{l[-1]}@#{d}"
      end
    end

    # Check equality with another email.
    #
    # @param other [Parse::Email, String] the other email
    # @return [Boolean] true if the emails are equal
    def ==(other)
      if other.is_a?(Parse::Email)
        @address == other.address
      elsif other.is_a?(String)
        @address == normalize(other)
      else
        false
      end
    end

    # @return [Boolean] true if the email is blank/nil
    def blank?
      @address.blank?
    end

    # @return [Boolean] true if the email is present
    def present?
      !blank?
    end

    # Type casting support for Parse properties.
    # This allows the property system to convert values to Email instances.
    #
    # @param value [Object] the value to typecast
    # @return [Parse::Email, nil] the Email instance or nil
    # @api private
    def self.typecast(value)
      return nil if value.nil?
      return value if value.is_a?(Parse::Email)
      Parse::Email.new(value)
    end
  end
end
