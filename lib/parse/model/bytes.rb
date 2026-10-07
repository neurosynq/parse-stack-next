# encoding: UTF-8
# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/object"
require_relative "model"
require "base64"

module Parse

  # Support for the Bytes type in Parse
  class Bytes < Model
    # The default attributes in a Parse Bytes hash.
    ATTRIBUTES = { __type: :string, base64: :string }.freeze
    # @return [String] the base64 string representing the content
    attr_accessor :base64
    # @return [TYPE_BYTES]
    def self.parse_class; TYPE_BYTES; end
    # @return [TYPE_BYTES]
    def parse_class; self.class.parse_class; end

    alias_method :__type, :parse_class

    # initialize with a base64 string or a Bytes object
    # @param bytes [String] The content as base64 string.
    def initialize(bytes = "")
      @base64 = (bytes.is_a?(Bytes) ? bytes.base64 : bytes).dup
    end

    # @!attribute attributes
    # Supports for mass assignment of values and encoding to JSON.
    # @return [ATTRIBUTES]
    def attributes
      ATTRIBUTES
    end

    # Base64 encode and set the instance contents. Uses strict (RFC 4648)
    # encoding: `Base64.encode64` inserts a newline every 60 characters,
    # which Parse Server stores verbatim in the Bytes column.
    # @param str the string to encode
    def encode(str)
      @base64 = Base64.strict_encode64(str.to_s)
    end

    # Get the content as decoded base64 bytes
    def decoded
      Base64.decode64(@base64 || "")
    end

    # Mass-assign the base64 content from a base64 String, a Parse Bytes
    # hash (`{"__type" => "Bytes", "base64" => "..."}`), or another
    # {Parse::Bytes}.
    # @param a [String, Hash, Parse::Bytes]
    def attributes=(a)
      if a.is_a?(Bytes)
        @base64 = a.base64.dup
      elsif a.is_a?(String)
        @base64 = a.dup
      elsif a.is_a?(Hash)
        @base64 = a["base64"] || a[:base64] || @base64
      end
    end

    # Two Parse::Bytes objects are equal if they have the same base64 signature
    def ==(u)
      return false unless u.is_a?(self.class)
      @base64 == u.base64
    end
  end
end
