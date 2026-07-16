# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Middleware
    # Shared query-string credential redactor for the logging and
    # profiling middlewares. Kept in ONE place so the two sanitizers
    # cannot drift — a credential that leaks through one but not the
    # other is exactly the failure mode this consolidation prevents.
    #
    # The previous per-middleware sanitizer only redacted three exact
    # param names (`sessionToken` / `masterKey` / `apiKey`). A credential
    # carried under any other name — `token`, `access_token`,
    # `client_secret`, `password`, a CloudFront `Signature` /
    # `Key-Pair-Id`, an S3 `X-Amz-Signature`, etc. — sailed through into
    # logs and `Parse.recent_profiles`. This redacts the VALUE of any
    # query param whose name looks credential-bearing, while leaving the
    # known-safe Parse query params (and other non-sensitive params)
    # visible for debuggability.
    module URLRedaction
      # Parse (and a couple of CloudFront) query params that contain a
      # sensitive-looking substring but are NOT secrets — protect them
      # from over-redaction. Compared case-insensitively.
      SAFE_QUERY_PARAMS = %w[
        keys
        excludekeys
        redirectclassnameforkey
      ].freeze

      # A query param whose (case-insensitive) name matches this is
      # treated as credential-bearing and has its value replaced with
      # +[FILTERED]+, unless the name is in {SAFE_QUERY_PARAMS}.
      SENSITIVE_NAME = /(?:token|key|secret|password|passwd|pwd|signature|\bsig\b|auth|credential|policy)/i

      REDACTED = "[FILTERED]"

      module_function

      # @param url [String, #to_s] a request URL (with or without a query string)
      # @return [String] the URL with credential-bearing query values redacted
      def sanitize(url)
        str = url.to_s
        # Possessive quantifiers (`++` / `*+`) so the param-name and value
        # runs never backtrack: on a pathological URL (a long run of
        # non-delimiter chars with no `=`) the greedy form would rescan
        # super-linearly (polynomial ReDoS on caller-supplied URLs flowing
        # into log/profile redaction). The excluded-delimiter classes make
        # the match unambiguous, so possessive matching is identical to the
        # greedy match for every real query string.
        str.gsub(/([?&])([^=&#]++)=([^&#]*+)/) do
          sep = Regexp.last_match(1)
          name = Regexp.last_match(2)
          value = Regexp.last_match(3)
          if sensitive?(name)
            "#{sep}#{name}=#{REDACTED}"
          else
            "#{sep}#{name}=#{value}"
          end
        end
      end

      # @param name [String] a raw (possibly percent-encoded) query-param name
      # @return [Boolean]
      def sensitive?(name)
        decoded = decode_name(name)
        return false if SAFE_QUERY_PARAMS.include?(decoded.downcase)
        !SENSITIVE_NAME.match(decoded).nil?
      end

      # Percent-decode a query-param NAME so a credential carried under an
      # encoded name is matched by its decoded spelling. Servers decode
      # `session%54oken` to `sessionToken` before reading it, so matching
      # the raw name alone lets an encoded credential name slip past
      # redaction.
      #
      # ONLY ASCII escapes (`%00`–`%7F`, i.e. first hex digit 0–7) are
      # decoded. Credential keywords are ASCII, so that is sufficient — and
      # decoding a high byte (`%C3`, `%FF`) would splice a lone
      # continuation/lead byte into the (UTF-8) name and yield an
      # invalid-encoding string that raises in the downstream `#downcase` /
      # `#match`. High-byte escapes are therefore left literal. `+` and
      # other bytes are untouched (param names don't use form-encoding).
      # The decoded form is used ONLY for the sensitivity decision;
      # {.sanitize} still emits the original spelling.
      #
      # @param name [String] a raw query-param name
      # @return [String] the ASCII-percent-decoded name (always valid if
      #   +name+ was)
      def decode_name(name)
        name.gsub(/%([0-7][0-9A-Fa-f])/) { Regexp.last_match(1).to_i(16).chr }
      end
    end
  end
end
