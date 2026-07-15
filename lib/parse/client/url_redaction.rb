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
        str.gsub(/([?&])([^=&#]+)=([^&#]*)/) do
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

      # @param name [String] a raw query-param name
      # @return [Boolean]
      def sensitive?(name)
        return false if SAFE_QUERY_PARAMS.include?(name.downcase)
        !SENSITIVE_NAME.match(name).nil?
      end
    end
  end
end
