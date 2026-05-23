# encoding: UTF-8
# frozen_string_literal: true

require "uri"

module Parse
  module API
    # Helpers for safely interpolating user-controlled segments into REST
    # paths. Every site that builds a request URL via raw string
    # interpolation (`"functions/#{name}"`, `"schemas/#{className}"`, etc.)
    # should route the name through one of these helpers first so a caller
    # passing `"../classes/_User?where=%7B%7D"` cannot traverse to a
    # different endpoint and read it with whatever credentials the outer
    # request was authorized to send.
    module PathSegment
      module_function

      # Parse identifier pattern: starts with a letter or underscore (Parse
      # uses leading underscore for system classes like `_User`,
      # `_Session`, `_Role`), then alphanumerics and underscores. Matches
      # the documented Parse class/field/function/job naming rules.
      IDENTIFIER_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze

      # Validate a Parse identifier (class name, function name, job name,
      # field name) and return it unchanged. Identifiers are already
      # path-safe under the strict pattern, so no percent-encoding is
      # needed; we just refuse anything that violates the shape.
      #
      # @param value the identifier to validate (anything responding to
      #   `to_s`).
      # @param kind [String] human-readable name for error messages.
      # @return [String] the validated identifier.
      # @raise [ArgumentError] if blank, contains a slash, contains a dot,
      #   or otherwise fails the pattern.
      def identifier!(value, kind: "name")
        s = value.to_s
        if s.empty?
          raise ArgumentError, "#{kind} must not be empty"
        end
        unless IDENTIFIER_PATTERN.match?(s)
          raise ArgumentError,
            "#{kind} #{s.inspect} contains characters that are not allowed in " \
            "a Parse identifier. Names must match /\\A[A-Za-z_][A-Za-z0-9_]*\\z/."
        end
        s
      end

      # Validate and percent-encode a less-restrictive path segment, used
      # for file names which can contain hyphens, periods, and other
      # filename-safe characters but must never contain a literal `/`,
      # `..`, or NUL/control characters.
      #
      # @param value the segment to validate.
      # @param kind [String] human-readable name for error messages.
      # @return [String] percent-encoded segment safe for path interpolation.
      # @raise [ArgumentError] if blank, contains a slash, is a path-
      #   traversal token, or contains control characters.
      def file!(value, kind: "filename")
        s = value.to_s
        if s.empty?
          raise ArgumentError, "#{kind} must not be empty"
        end
        if s.include?("/") || s == ".." || s == "."
          raise ArgumentError,
            "#{kind} #{s.inspect} contains path-traversal characters " \
            "(`/`, `.`, or `..`). Names must be a single path segment."
        end
        if s.match?(/[\x00-\x1F\x7F]/)
          raise ArgumentError, "#{kind} #{s.inspect} contains control characters"
        end
        URI.encode_www_form_component(s)
      end
    end
  end
end
