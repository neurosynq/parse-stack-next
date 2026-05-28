# encoding: UTF-8
# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/object"
require_relative "model"
require "open-uri"
require "ipaddr"
require "resolv"

module Parse
  # This class represents a Parse file pointer. `Parse::File` has helper
  # methods to upload Parse files directly to Parse and manage file
  # associations with your classes.
  # @example
  #  file = File.open("file_path.jpg")
  #  contents = file.read
  #  file = Parse::File.new("myimage.jpg", contents , "image/jpeg")
  #  file.saved? # => false
  #  file.save
  #
  #  file.url # https://files.parsetfss.com/....
  #
  #  # or create and upload a remote file (auto-detected mime type)
  #  file = Parse::File.create(some_url)
  #
  #
  # @note The default MIME type for all files is _image/jpeg_. This can be default
  #       can be changed by setting a value to `Parse::File.default_mime_type`.
  class File < Model
    # Raised when a `Parse::File` is hydrated with a `url:` whose host is
    # outside {Parse::File.trusted_url_hosts} and the
    # {Parse::File.untrusted_url_policy} is `:raise`. The default policy
    # is `:warn`, so this exception is opt-in via integrator
    # configuration.
    class UntrustedHostError < Parse::Error; end

    # Raised when caller code attempts to assign a presigned / signed URL
    # to {#url}. The `@url` field is reserved for stable canonical URLs;
    # short-TTL signed URLs must come from {#download_url} (added in a
    # later phase) and never be cached on the instance. Fail-loud so the
    # leak vector is caught at the point of error rather than discovered
    # in logs or a CDN access trail.
    class SignedUrlError < Parse::Error; end


    # Regular expression that matches the old legacy Parse hosted file name
    LEGACY_FILE_RX = /^tfss-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}-/
    # The default attributes in a Parse File hash. Matches the Parse
    # Server file-pointer wire format `{__type, name, url}`. The `key`
    # field on `Parse::File` is in-memory only (not persisted to Parse
    # Server because the server normalizes embedded file pointers and
    # strips unknown fields); see {#key}.
    ATTRIBUTES = { __type: :string, name: :string, url: :string }.freeze
    # Query-string parameter names that mark a URL as a presigned /
    # signed URL — i.e. one whose POSSESSION grants temporary
    # capability. Used by {.url_signature_param?} (the detection
    # predicate behind the URL normalization point) and exposed
    # publicly so downstream apps wiring custom strict-mode checks
    # can iterate the same list the SDK does. Detection is
    # case-insensitive.
    SIGNATURE_QUERY_PARAMS = %w[
      X-Amz-Signature
      X-Amz-Credential
      X-Amz-Security-Token
      AWSAccessKeyId
      Key-Pair-Id
    ].freeze

    # @!visibility private
    # Default cap on remote-fetched file size (50 MiB). Override via
    # +Parse::File.max_remote_size+.
    DEFAULT_MAX_REMOTE_SIZE = 50 * 1024 * 1024
    # @!visibility private
    # Default read/open timeout for remote fetches in seconds.
    DEFAULT_REMOTE_TIMEOUT = 10
    # @!visibility private
    # CIDR ranges that must never be reachable from Parse::File URL fetches
    # (loopback, link-local, private, multicast, broadcast, cloud-metadata,
    # CGNAT, IPv6 ULA/link-local, IPv4-mapped IPv6). Refer to RFC 1918 /
    # 6890 / 6598 / 4193 / 4291.
    BLOCKED_CIDRS = [
      "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
      "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.168.0.0/16",
      "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32",
      # Alibaba Cloud metadata service (public-IP-space but well-known
      # cloud-metadata endpoint that must not be reachable from SDK fetches).
      "100.100.100.200/32",
      "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8", "::ffff:0:0/96"
    ].map { |c| IPAddr.new(c) }.freeze
    # Restrictive port allowlist for Parse::File URL fetches. By default
    # only the standard HTTP/HTTPS ports are permitted. Operators may
    # extend +Parse::File.allowed_remote_ports+ for legitimate non-standard
    # CDN ports.
    DEFAULT_ALLOWED_REMOTE_PORTS = [80, 443, 8080, 8443].freeze
    # @return [String] the name of the file including extension (if any)
    attr_accessor :name

    # Assign the file's URL.
    #
    # Routes through the single normalization point
    # {#normalize_and_store_url}, which is also called by
    # {#attributes=} on hydration. The rule (see s3_adapter_plan.md
    # rev 3, D1/D2) applies uniformly to every writer:
    #
    # - Signed URLs (query string carries `X-Amz-Signature` /
    #   `X-Amz-Credential` / `X-Amz-Security-Token` / `AWSAccessKeyId` /
    #   `Key-Pair-Id`) are silently normalized: the query string is
    #   stripped, the bare canonical URL is stored in `@url`, the
    #   original signed URL is stashed in `@presigned_url` with its
    #   data-driven expiry parsed from the query params themselves
    #   (`X-Amz-Date + X-Amz-Expires` for SigV4, `Expires` for legacy /
    #   CloudFront).
    # - Trusted-host check via {.sanitize_hydrated_url} still applies.
    # - The `@key` cache is invalidated — URL reassignment may point at
    #   a different storage location.
    #
    # No raise on signed URLs. The Wave A {SignedUrlError} class is
    # still defined for downstream apps that want stricter
    # enforcement (e.g. operators who can guarantee Parse Server is
    # NOT configured with `S3FilesAdapter` and want presigned URLs to
    # raise instead of normalize), but the built-in SDK writers do
    # not raise it. Asymmetric behavior between writers (raise here,
    # accept there) was an explicit anti-goal in rev 3 — it grows
    # footguns through `assign_attributes` / serializer round-trips.
    #
    # @param value [String, nil] the URL to assign.
    def url=(value)
      normalize_and_store_url(value)
    end

    # @return [Object] the contents of the file.
    attr_accessor :contents

    # @return [String] the mime-type of the file whe
    attr_accessor :mime_type

    # @return [Model::TYPE_FILE]
    def self.parse_class; TYPE_FILE; end
    # @return [Model::TYPE_FILE]
    def parse_class; self.class.parse_class; end

    alias_method :__type, :parse_class
    # @!visibility private
    FIELD_NAME = "name"
    # @!visibility private
    FIELD_URL = "url"
    class << self

      # @return [String] the default mime-type
      attr_writer :default_mime_type

      # @return [Boolean] whether to force all urls to be https.
      attr_writer :force_ssl

      # @return [String] The default mime type for created instances. Default: _'image/jpeg'_
      def default_mime_type
        @default_mime_type ||= "image/jpeg"
      end

      # @return [Boolean] When set to true, it will make all calls to File#url
      def force_ssl
        @force_ssl ||= false
      end

      # @return [Integer] Maximum byte size for a remote URL fetch via
      #   +Parse::File.create+ / +Parse::File.new(url)+.
      attr_writer :max_remote_size
      def max_remote_size
        @max_remote_size ||= DEFAULT_MAX_REMOTE_SIZE
      end

      # @return [Integer] Read/open timeout (seconds) for remote URL fetches.
      attr_writer :remote_timeout
      def remote_timeout
        @remote_timeout ||= DEFAULT_REMOTE_TIMEOUT
      end

      # @return [Array<String>] Optional host allowlist. When non-empty, only
      #   hostnames whose DNS resolution matches an entry are permitted as
      #   sources for remote URL fetches. Wildcards via leading "." (e.g.
      #   ".example.com" matches "files.example.com"). Default: empty (any
      #   public host is allowed; private hosts are always denied).
      attr_writer :allowed_remote_hosts
      def allowed_remote_hosts
        @allowed_remote_hosts ||= []
      end

      # @return [Array<String>] Allowlist of HOSTS permitted in a `Parse::File`
      #   `url` field at hydration time. When set, any attempt to assign a
      #   `url` whose host is not on the list raises `Parse::File::UntrustedHostError`
      #   (or warns and clears when `untrusted_url_policy = :warn`). Defaults
      #   to:
      #
      #   - `files.parsetfss.com` (legacy Parse hosted files)
      #   - Anything in `Parse::File.trusted_url_hosts`
      #   - Anything matching `parse_hosted_file?` (the `tfss-` filename
      #     prefix, which can ride on any host)
      #
      #   Integrators with a CDN in front of Parse files add their CDN host:
      #   `Parse::File.trusted_url_hosts << "cdn.example.com"`. Wildcard
      #   entries via leading "." (e.g. `".cdn.example.com"`) match any
      #   subdomain.
      attr_writer :trusted_url_hosts
      def trusted_url_hosts
        @trusted_url_hosts ||= ["files.parsetfss.com"]
      end

      # @return [Symbol] policy applied when an incoming URL carries a
      #   signed-URL signature query parameter (see
      #   {SIGNATURE_QUERY_PARAMS}). One of:
      #
      #   - `:strip` (default) — strip the signature, store the bare
      #     canonical URL in `@url`, stash the original signed URL in
      #     `@presigned_url` with its parsed expiry. The pragmatic
      #     default — operators whose Parse Server is configured with
      #     `S3FilesAdapter(presignedUrl: true)` get a freshly-signed
      #     URL on every read, and the SDK has to accept that.
      #   - `:raise` — refuse the assignment with
      #     {SignedUrlError}. Strict mode for apps that can guarantee
      #     Parse Server is NOT configured with a presigned-URL file
      #     adapter and want any signed URL in `@url` to fail loudly
      #     instead of being silently normalized.
      #
      #   The choice applies uniformly to both caller-side `url=` and
      #   hydration `attributes=` — asymmetric writer behavior was an
      #   explicit anti-goal of the design.
      attr_writer :signed_url_policy
      def signed_url_policy
        @signed_url_policy ||= :strip
      end

      # @return [Symbol] policy when a `Parse::File` is hydrated with a URL
      #   whose host is not in {trusted_url_hosts}. One of:
      #
      #   - `:warn` (default) — emit a single warning per host and accept
      #     the URL anyway (preserves prior behavior; useful while
      #     populating the allowlist).
      #   - `:strip` — keep the file metadata but blank the `@url` so
      #     downstream renderers don't emit `<img src="…">` pointing at
      #     an attacker-controlled host.
      #   - `:raise` — refuse hydration with `UntrustedHostError`.
      #
      #   The default is intentionally non-breaking; integrators ready to
      #   enforce flip the policy explicitly.
      attr_writer :untrusted_url_policy
      def untrusted_url_policy
        @untrusted_url_policy ||= :warn
      end

      # @return [Array<Integer>] Allowed remote ports for URL fetches.
      attr_writer :allowed_remote_ports
      def allowed_remote_ports
        @allowed_remote_ports ||= DEFAULT_ALLOWED_REMOTE_PORTS.dup
      end

      # Regex that matches any HTTP(S) URL carrying an unambiguously
      # AWS-style signed-URL parameter — SigV4 (`X-Amz-*`), legacy
      # SigV2 (`AWSAccessKeyId`), or CloudFront (`Key-Pair-Id`).
      # Designed to be plugged into log scrubbers / `lograge` /
      # `semantic_logger` filters so accidental
      # `Rails.logger.info(file_url)` calls do not leak short-TTL
      # download credentials into log aggregators.
      #
      # Bare `Signature=` and `Policy=` are NOT matched on their own —
      # they collide with too many unrelated app conventions (webhook
      # signatures, privacy_policy fields). CloudFront URLs always
      # carry `Key-Pair-Id` alongside `Signature` / `Policy`, so the
      # `Key-Pair-Id` match catches the whole URL substring.
      #
      # This pattern matches **plain-text** URLs (`&` as the literal
      # query separator). For JSON-encoded log payloads — where `&`
      # is serialized as `\u0026`, common in Sentry / Honeybadger /
      # Rollbar event bodies — use {.log_filter_strict} which accepts
      # both forms.
      #
      # **Out of scope:** CloudFront signed *cookies*
      # (`CloudFront-Policy`, `CloudFront-Signature`,
      # `CloudFront-Key-Pair-Id` set as HTTP cookies rather than
      # query parameters) are a separate auth mechanism and the SDK
      # does not provide leak detection for them. Apps using
      # CloudFront signed cookies must scrub their own cookie
      # logging.
      #
      # Log lines wrapped at fixed widths that split the URL
      # mid-querystring will silently bypass either regex; scrub
      # before line-wrapping.
      #
      # @example Rails — scrub presigned URLs out of all log lines
      #   config.lograge.custom_payload do |controller|
      #     payload = { ... }
      #     payload.transform_values do |v|
      #       v.is_a?(String) ? v.gsub(Parse::File.log_filter, "[FILTERED_PRESIGNED_URL]") : v
      #     end
      #   end
      #
      # @example Rails — `filter_parameters` for params with these names
      #   Rails.application.config.filter_parameters += Parse::File.filter_parameter_names
      #
      # @return [Regexp]
      def log_filter
        @log_filter ||= %r{
          https?://[^\s'"<>]+      # URL prefix
          [?&]                     # query separator
          (?:
            X-Amz-Signature        |
            X-Amz-Credential       |
            X-Amz-Security-Token   |
            X-Amz-Algorithm        |
            X-Amz-Date             |
            X-Amz-Expires          |
            X-Amz-SignedHeaders    |
            AWSAccessKeyId         |
            Key-Pair-Id
          )
          =[^&\s'"<>]+             # signature value
          (?:&[^\s'"<>]*)?         # trailing params
        }xi.freeze
      end

      # Stricter variant of {.log_filter} that ALSO matches the
      # JSON-encoded query separator (`\u0026` for `&`). Use this
      # when scrubbing error-reporter event bodies (Sentry,
      # Honeybadger, Rollbar, Bugsnag) where the URL string has been
      # JSON-encoded once and the literal `&` appears as `\u0026`.
      #
      # @example Sentry beforeSend hook — scrub both shapes
      #   Sentry.init do |config|
      #     config.before_send = ->(event, _hint) {
      #       json = JSON.dump(event.to_hash)
      #       scrubbed = json.gsub(Parse::File.log_filter_strict, "[FILTERED_PRESIGNED_URL]")
      #       JSON.parse(scrubbed)
      #     }
      #   end
      #
      # @return [Regexp]
      def log_filter_strict
        # URL prefix excludes the backslash so it doesn't greedily
        # consume the `\u0026` sequence in JSON-encoded payloads.
        # Separator and trailing-params clauses both accept either
        # form. The literal `\\u0026` in source produces the Regexp
        # source `\\u0026` which matches the 6 characters `\u0026`
        # (not the Unicode escape for `&` — which is what
        # `\u0026` in source would mean).
        @log_filter_strict ||= %r{
          https?://[^\s'"<>\\]+          # URL prefix (excludes \)
          (?:[?&]|\\u0026)               # separator: & or \u0026
          (?:
            X-Amz-Signature        |
            X-Amz-Credential       |
            X-Amz-Security-Token   |
            X-Amz-Algorithm        |
            X-Amz-Date             |
            X-Amz-Expires          |
            X-Amz-SignedHeaders    |
            AWSAccessKeyId         |
            Key-Pair-Id
          )
          =[^&\s'"<>\\]+                 # signature value (excludes \)
          (?:(?:&|\\u0026)[^\s'"<>\\]*)? # trailing params
        }xi.freeze
      end

      # Parameter names operators should add to
      # `Rails.application.config.filter_parameters` so presigned-URL
      # query params are scrubbed from request logs by Rails itself.
      #
      # Defaults are AWS-prefixed only (`X-Amz-*`, `AWSAccessKeyId`,
      # `Key-Pair-Id`) so the list never over-redacts a Rails app's
      # `privacy_policy` / e-signature / `policy_id` form fields. For
      # CloudFront-heavy deployments that need bare `Signature` /
      # `Policy` / `Expires` matched as well, append
      # {.cloudfront_signed_param_names}.
      #
      # @return [Array<Regexp>]
      def filter_parameter_names
        @filter_parameter_names ||= [
          /\AX-Amz-/i,
          /\AAWSAccessKeyId\z/i,
          /\AKey-Pair-Id\z/i,
        ].freeze
      end

      # CloudFront-signed-URL parameter names (`Signature`, `Policy`,
      # `Expires`). Opt-in extension to {.filter_parameter_names} for
      # apps that proxy CloudFront-signed URLs through Rails params.
      #
      # **Out of scope:** CloudFront signed *cookies*
      # (`CloudFront-Policy`, `CloudFront-Signature`,
      # `CloudFront-Key-Pair-Id` set as HTTP cookies rather than
      # query parameters) are a separate auth mechanism — Rails
      # parameter filtering does not see cookies, and the SDK
      # does not provide a separate cookie-filter list. Apps using
      # CloudFront signed cookies must wire their own protection
      # via `ActionDispatch::Cookies::Middleware` filters.
      #
      # WARNING: these names collide with legitimate app params —
      # `policy` (privacy_policy, policy_id), `signature` (DocuSign /
      # webhook signatures), `expires` (any cache-control style field).
      # Append only when the operator has confirmed no such collision
      # exists in the app's request surface.
      #
      # @return [Array<Regexp>]
      def cloudfront_signed_param_names
        @cloudfront_signed_param_names ||= [
          /\ASignature\z/i,
          /\APolicy\z/i,
          /\AExpires\z/i,
        ].freeze
      end

      # True when the URL's query string carries any known signed-URL
      # parameter from {SIGNATURE_QUERY_PARAMS}. Used by the URL
      # normalization point ({Parse::File#normalize_and_store_url}).
      # Uses `String#include?` for cheap substring detection rather
      # than building a Regexp on every assignment.
      #
      # Case-folds the comparison so misbehaving CDNs / reverse
      # proxies that lowercase query-parameter names (rare but real)
      # do not bypass detection. AWS's canonical capitalization is
      # what `SIGNATURE_QUERY_PARAMS` is written in; the case-fold
      # is purely defensive.
      #
      # Known limitations (documented for callers wiring custom
      # strict-mode checks via this predicate):
      #
      # - URL-encoded query separators (`?` written as `%3F`) bypass
      #   the literal `?<param>=` substring match. Decode percent
      #   encoding before passing in if the URL came from a context
      #   that double-encodes.
      # - URL fragments (`#`) before a `?` placeholder do not get
      #   stripped here — `normalize_and_store_url` handles
      #   fragment-aware stripping during the actual URL store.
      #
      # @param url_string [String, nil]
      # @return [Boolean]
      def url_signature_param?(url_string)
        return false unless url_string.is_a?(String)
        return false unless url_string.include?("?") || url_string.include?("&")
        haystack = url_string.downcase
        SIGNATURE_QUERY_PARAMS.any? do |param|
          needle = param.downcase
          haystack.include?("?#{needle}=") || haystack.include?("&#{needle}=")
        end
      end

      # Parse the expiry time (UTC) of a presigned URL directly from
      # its query parameters — the TTL is whatever the issuer chose,
      # NEVER hardcoded SDK-side.
      #
      # Supports:
      # - **SigV4** (`X-Amz-Date=YYYYMMDDTHHMMSSZ` +
      #   `X-Amz-Expires=<seconds>`): expiry = date + expires_seconds.
      # - **SigV2 / CloudFront** (`Expires=<unix-seconds>`): expiry =
      #   the raw timestamp.
      #
      # Returns nil on malformed input — including a regex-valid
      # date string whose component values are out of range
      # (`20260231T120000Z`, leap-second seconds field `60`, day 32,
      # month 13). Hydration of a corrupt row should not abort
      # `attributes=` with an upstream `ArgumentError`; the caller
      # sees the file with `presigned_url_expires_at == nil` and can
      # decide what to do.
      #
      # @param url [String]
      # @return [Time, nil] expiry in UTC, or nil if the URL doesn't
      #   carry parseable presigned-URL expiry data.
      def parse_presigned_expiry(url)
        return nil unless url.is_a?(String)
        query = url.split("?", 2)[1]
        return nil unless query
        params = {}
        query.split("&").each do |pair|
          k, v = pair.split("=", 2)
          params[k] = v if k && v
        end
        if params["X-Amz-Date"] && params["X-Amz-Expires"]
          ts = params["X-Amz-Date"]
          secs = params["X-Amz-Expires"].to_i
          return nil unless secs > 0
          # X-Amz-Date is ISO 8601 basic — YYYYMMDDTHHMMSSZ, always
          # UTC. Manual slice is safer than `Time.strptime` which
          # treats `Z` as a literal and interprets the result in
          # local time.
          m = ts.match(/\A(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z\z/)
          return nil unless m
          begin
            Time.utc(m[1].to_i, m[2].to_i, m[3].to_i,
                     m[4].to_i, m[5].to_i, m[6].to_i) + secs
          rescue ArgumentError
            # Regex-valid but date-component-invalid (day 32, month
            # 13, seconds 60). Return nil rather than propagating up
            # through hydration.
            nil
          end
        elsif params["Expires"]
          unix = params["Expires"].to_i
          return nil if unix <= 0
          Time.at(unix).utc
        end
      end

      # @!visibility private
      # Fetches a remote URL with strict SSRF defenses. Refuses non-HTTP
      # schemes, RFC1918 / loopback / cloud-metadata addresses, oversized
      # bodies, and slow upstreams. Returns the open-uri Tempfile/StringIO
      # the caller can read from.
      #
      # DNS rebinding mitigation: the host is resolved twice — once before
      # the fetch and once via +URI.open+'s underlying resolver. The
      # second-pass addresses are re-validated against +BLOCKED_CIDRS+;
      # any new private/internal IP causes an +ArgumentError+ at progress
      # time so the body cannot be streamed back. (Caveat: this is a
      # best-effort defense — the TCP +connect()+ uses a third resolution
      # that we cannot intercept without a custom socket factory. Operators
      # who need strict guarantees should also enforce egress allowlists
      # at the network layer.)
      # @raise [ArgumentError] on any disallowed input or unsafe target.
      def safe_open_url(url_string)
        uri = begin
          URI.parse(url_string)
        rescue URI::InvalidURIError => e
          raise ArgumentError, "Invalid URL: #{e.message}"
        end
        unless %w[http https].include?(uri.scheme)
          raise ArgumentError, "Parse::File only supports http(s) URLs (got #{uri.scheme.inspect})"
        end
        host = uri.host
        raise ArgumentError, "URL missing host" if host.nil? || host.empty?
        # Reject credentials embedded in the authority component — userinfo
        # has no legitimate purpose for an SDK file fetch and confuses
        # downstream code that inspects file.base_uri later.
        if uri.userinfo
          raise ArgumentError, "Parse::File URL must not include userinfo credentials"
        end
        # Port allowlist — refuses internal-port probing via DNS rebinding +
        # SSH/Redis/Memcached banner exfiltration even if the host clears
        # the CIDR check.
        port = uri.port || (uri.scheme == "https" ? 443 : 80)
        unless allowed_remote_ports.include?(port)
          raise ArgumentError, "Port #{port} not in Parse::File.allowed_remote_ports"
        end
        resolved = assert_host_allowed!(host)

        size_cap = max_remote_size
        timeout = remote_timeout
        uri.open(read_timeout: timeout,
                 open_timeout: timeout,
                 redirect: false,
                 content_length_proc: ->(len) {
                   if len && len > size_cap
                     raise ArgumentError, "Remote file exceeds Parse::File.max_remote_size (#{size_cap} bytes)"
                   end
                   # DNS-rebinding re-check: by the time content_length_proc
                   # fires, the connection has been established. Re-resolve
                   # and refuse if the host now points anywhere private.
                   assert_host_not_rebound!(host, resolved)
                 },
                 progress_proc: ->(transferred) {
                   if transferred > size_cap
                     raise ArgumentError, "Remote file exceeds Parse::File.max_remote_size (#{size_cap} bytes)"
                   end
                 })
      end

      # @!visibility private
      # Validates that +host+ resolves only to public, non-blocked addresses.
      # When +Parse::File.allowed_remote_hosts+ is non-empty, host must also
      # match an allowlist entry.
      # @return [Array<IPAddr>] the addresses that passed validation.
      def assert_host_allowed!(host)
        addrs = resolve_addresses(host)
        if addrs.empty?
          raise ArgumentError, "Could not resolve host #{host}"
        end
        addrs.each do |ip|
          if BLOCKED_CIDRS.any? { |cidr| cidr.include?(ip) }
            raise ArgumentError, "Refusing Parse::File fetch to private/internal address #{ip} for host #{host}"
          end
        end
        unless allowed_remote_hosts.empty?
          permitted = allowed_remote_hosts.any? do |allowed|
            if allowed.start_with?(".")
              host.downcase.end_with?(allowed.downcase) ||
                host.casecmp(allowed[1..]).zero?
            else
              host.casecmp(allowed).zero?
            end
          end
          unless permitted
            raise ArgumentError, "Host #{host} not in Parse::File.allowed_remote_hosts"
          end
        end
        addrs
      end

      # @!visibility private
      # DNS rebinding re-check. Resolves +host+ again and refuses if any
      # currently-resolved address is private or differs from the first
      # resolution. Best-effort: kernel resolver caches and a third
      # resolution at connect-time are out of scope.
      def assert_host_not_rebound!(host, prior_addrs)
        return if prior_addrs.nil? || prior_addrs.empty?
        current = resolve_addresses(host)
        current.each do |ip|
          if BLOCKED_CIDRS.any? { |cidr| cidr.include?(ip) }
            raise ArgumentError, "DNS rebinding detected — host #{host} now resolves to private address #{ip}"
          end
        end
      end

      # @!visibility private
      def resolve_addresses(host)
        # Already an IP literal?
        IPAddr.new(host)
        [IPAddr.new(host)]
      rescue IPAddr::InvalidAddressError
        begin
          Resolv.getaddresses(host).map { |a|
            begin
              IPAddr.new(a)
            rescue StandardError
              nil
            end
          }.compact
        rescue Resolv::ResolvError, Resolv::ResolvTimeout
          []
        end
      end
    end
    # The initializer to create a new file supports different inputs.
    # If the first paramter is a string which starts with 'http', we then download
    # the content of the file (and use the detected mime-type) to set the content and mime_type fields.
    # If the first parameter is a hash, we assume it might be the Parse File hash format which contains url and name fields only.
    # If the first paramter is a Parse::File, then we copy fields over
    # Otherwise, creating a new file requires a name, the actual contents (usually from a File.open("local.jpg").read ) and the mime-type
    # @param name [String]
    # @param contents [Object]
    # @param mime_type [String] Default see default_mime_type
    def initialize(name, contents = nil, mime_type = nil)
      mime_type ||= Parse::File.default_mime_type

      if name.is_a?(String) && name.start_with?("http") #could be url string
        file = Parse::File.safe_open_url(name)
        @contents = file.read
        @name = File.basename file.base_uri.to_s
        @mime_type = file.content_type
      elsif name.is_a?(Hash)
        self.attributes = name
      elsif name.is_a?(::File)
        @contents = contents || name.read
        @name = File.basename name.to_path
      elsif name.is_a?(Parse::File)
        @name = name.name
        # Route through the single URL normalization point so the copy
        # gets the same strip + stash treatment as a caller-side
        # `url=`. Preserve the source's presigned-URL stash
        # post-normalization (normalize resets them; carrying the
        # source's values across keeps the copy semantically
        # equivalent for view-render use cases).
        normalize_and_store_url(name.url)
        @presigned_url = name.presigned_url if name.presigned_url
        @presigned_url_expires_at = name.presigned_url_expires_at if name.presigned_url_expires_at
      else
        @name = name
        @contents = contents
      end
      if @name.blank?
        raise ArgumentError, "Invalid Parse::File initialization with name '#{@name}'"
      end

      @mime_type ||= mime_type
    end

    # This creates a new Parse File Object with from a URL, saves it and returns it
    # @param url [String] A url which will be used to create the file and automatically save it.
    # @return [Parse::File] A newly saved file based on contents of _url_
    def self.create(url)
      url = url.url if url.is_a?(Parse::File)
      file = self.new(url)
      file.save
      file
    end

    # A File object is considered saved when `@url` and `@name` are
    # both present and `@name` matches the basename of `@url`'s path
    # component.
    #
    # The URL's query string is stripped before the basename
    # computation so short-TTL presigned URLs that Parse Server's
    # S3FilesAdapter returns on every read
    # (`https://bucket.s3.../doc.pdf?X-Amz-Signature=...`) don't
    # confuse `File.basename` into including the signature bytes in
    # the comparison.
    #
    # @return [Boolean] true if this file has already been saved.
    def saved?
      return false unless @url.present? && @name.present?
      path_only = @url.sub(/\?.*\z/, "")
      @name == File.basename(path_only)
    end

    # Returns the url string for this Parse::File pointer. If the *force_ssl* option is
    # set to true, it will make sure it returns a secure url.
    # @return [String] the url string for the file.
    def url
      if @url.present? && Parse::File.force_ssl && @url.starts_with?("http://")
        return @url.sub("http://", "https://")
      end
      @url
    end

    # @return [Hash]
    def attributes
      ATTRIBUTES
    end

    # @return [Boolean] Two files are equal if they have the same url
    def ==(u)
      return false unless u.is_a?(self.class)
      @url == u.url
    end

    # Allows mass assignment from a Parse JSON hash.
    #
    # Routes through the single normalization point
    # {#normalize_and_store_url}, identical to {#url=}. Signed URLs
    # (the common Parse-Server-S3 case) are silently stripped and
    # stashed in `@presigned_url`. See rev 3 D2 in
    # s3_adapter_plan.md — asymmetric writer behavior is an explicit
    # anti-goal.
    def attributes=(h)
      raw_url = nil
      if h.is_a?(String)
        raw_url = h
        @name = File.basename(h)
      elsif h.is_a?(Hash)
        raw_url = h[FIELD_URL] || h[:url]
        @name = h[FIELD_NAME] || h[:name] || @name
      end
      normalize_and_store_url(raw_url)
    end

    # @return [String, nil] the last signed URL the SDK saw for this
    #   file's location. Populated by the URL normalization point
    #   ({#normalize_and_store_url}) whenever an incoming URL carries a
    #   recognized signed-URL query parameter. Distinct from `@url`
    #   (which is always the bare canonical URL — see rev 3 D1). The
    #   expiry of this URL is in {#presigned_url_expires_at}; callers
    #   should consult that before handing the URL to a client.
    attr_reader :presigned_url

    # @return [Time, nil] the expiry time (UTC) parsed from the most
    #   recent presigned URL the SDK saw, computed from the URL's own
    #   query parameters (`X-Amz-Date` + `X-Amz-Expires` for SigV4,
    #   `Expires` for SigV2 / CloudFront). The TTL is **never**
    #   hardcoded; whatever Parse Server's S3FilesAdapter (or whoever
    #   issued the URL) chose is what the SDK uses.
    attr_reader :presigned_url_expires_at

    # True when {#presigned_url} is set and not yet expired (with an
    # optional safety buffer so callers can refetch before the URL
    # actually expires server-side).
    #
    # @example Render a presigned URL in a Rails view, refetching when near expiry
    #   if file.presigned_url_valid?
    #     # render directly — buffer absorbs network RTT + retries
    #   else
    #     post.reload
    #     # render post.attachment.presigned_url
    #   end
    #
    # @param buffer [Integer, Float] seconds before
    #   `presigned_url_expires_at` to start treating as expired.
    #   Default 60 seconds — a margin that absorbs network RTT,
    #   client clock skew, and one retry. Tighten via `buffer: 30`
    #   in latency-sensitive paths; loosen via `buffer: 120` for
    #   apps that proxy URLs through additional hops before render.
    # @return [Boolean]
    def presigned_url_valid?(buffer: 60)
      return false if @presigned_url.nil?
      return false if @presigned_url_expires_at.nil?
      (@presigned_url_expires_at - buffer.to_f) > Time.now.utc
    end

    # @!visibility private
    # The single normalization point for any URL assignment. Routes
    # both {#url=} (caller-side) and {#attributes=} (hydration) through
    # the same logic — see rev 3 D2 in s3_adapter_plan.md for the
    # rationale on uniform behavior.
    def normalize_and_store_url(value)
      # Unconditionally invalidate the presigned-URL stash on every
      # URL assignment. Reassignment may point at a different storage
      # location; a stale stashed signed URL would silently lie to
      # downstream callers (e.g. an ERB view that renders
      # `file.presigned_url`). If the new value is itself a signed
      # URL, the stash is repopulated below.
      @presigned_url = nil
      @presigned_url_expires_at = nil

      # Strict-mode hook: operators who can guarantee Parse Server is
      # NOT configured with a presigned-URL file adapter (i.e. signed
      # URLs in `@url` would always indicate a bug) flip the policy
      # via `Parse::File.signed_url_policy = :raise` and get a loud
      # SignedUrlError instead of silent normalization.
      if value.is_a?(String) && Parse::File.url_signature_param?(value)
        if Parse::File.signed_url_policy == :raise
          raise SignedUrlError,
                "Parse::File received a signed URL while " \
                "`signed_url_policy` is `:raise`. The query string " \
                "carries a presigned-URL signature parameter and the " \
                "configured policy refuses to normalize silently. " \
                "Mint signed GET URLs via the storage adapter (server " \
                "mode) or read `file.presigned_url` (client mode) " \
                "instead of assigning them to `@url`."
        end
        # Stash the original signed URL with its data-driven expiry,
        # then strip the query string and store the bare canonical
        # URL in @url. Subsequent reads of `file.url` return the
        # canonical URL; presigned access goes through
        # `presigned_url` (or, in a later release, `download_url`).
        @presigned_url = value
        @presigned_url_expires_at = Parse::File.parse_presigned_expiry(value)
        bare = value.sub(/\?.*\z/, "")
        normalized = Parse::File.sanitize_hydrated_url(bare, fallback: @url, name: @name)
        # If the host check stripped or rejected the URL (`:strip`
        # policy or `:raise` after the signature strip), clear the
        # stash too — leaving an attacker-controlled signed URL in
        # `@presigned_url` while `@url` was refused is a silent leak
        # surface that the host-policy author explicitly chose to
        # avoid.
        if normalized.nil? || normalized != bare
          @presigned_url = nil
          @presigned_url_expires_at = nil
        end
        @url = normalized
      else
        @url = Parse::File.sanitize_hydrated_url(value, fallback: @url, name: @name)
      end
    end
    private :normalize_and_store_url

    # @!visibility private
    # Apply {trusted_url_hosts} / {untrusted_url_policy} to a URL coming
    # in from a Parse JSON hydration. Returns the URL to assign to
    # `@url`, which may be:
    #
    # - `raw` itself when the host is trusted (or `parse_hosted_file?`
    #   matches via the `tfss-` filename prefix, which can ride on any
    #   host),
    # - `fallback` when policy is `:strip`,
    # - raises {UntrustedHostError} when policy is `:raise`.
    #
    # On `:warn`, the URL is accepted but a single warning per host is
    # emitted (deduplicated process-wide). Empty / non-string / non-http
    # values pass through unchanged so callers can clear the field.
    def self.sanitize_hydrated_url(raw, fallback: nil, name: nil)
      return raw if raw.nil?
      return raw unless raw.is_a?(String) && !raw.empty?
      return raw unless raw.start_with?("http://") || raw.start_with?("https://")

      uri = begin
        URI.parse(raw)
      rescue URI::InvalidURIError
        return raw  # malformed URL — leave it alone; downstream code already handles
      end
      host = uri.host.to_s.downcase
      return raw if host.empty?

      # tfss-prefixed filenames can be served from arbitrary hosts (the
      # legacy hosted-files contract). Accept those regardless of host.
      basename = name || File.basename(raw)
      return raw if basename.to_s.start_with?("tfss-")

      return raw if trusted_url_host?(host)

      case untrusted_url_policy
      when :raise
        raise UntrustedHostError,
          "Parse::File URL host #{host.inspect} is not in Parse::File.trusted_url_hosts. " \
          "Add the host to the allowlist or change the policy to :warn/:strip."
      when :strip
        warn_untrusted_url_host_once(host, action: "stripped")
        fallback
      else  # :warn (default)
        warn_untrusted_url_host_once(host, action: "accepted")
        raw
      end
    end

    # @!visibility private
    def self.trusted_url_host?(host)
      trusted_url_hosts.any? do |entry|
        e = entry.to_s.downcase
        next false if e.empty?
        if e.start_with?(".")
          host == e[1..] || host.end_with?(e)
        else
          host == e
        end
      end
    end

    # @!visibility private
    def self.warn_untrusted_url_host_once(host, action:)
      @warned_untrusted_hosts ||= {}
      return if @warned_untrusted_hosts[host]
      @warned_untrusted_hosts[host] = true
      warn "[Parse::File:SECURITY] Untrusted URL host #{host.inspect} " \
           "(#{action}). Add the host to Parse::File.trusted_url_hosts " \
           "to silence this warning. Untrusted hosts in file URL fields " \
           "enable stored phishing, SVG XSS, and open-redirect via " \
           "<img src='…'> rendering."
    end

    # A proxy method for ::File.basename
    # @param file_name [String]
    # @param suffix [String]
    # @return [String] File.basename(file_name)
    # @see ::File.basename
    def self.basename(file_name, suffix = nil)
      if suffix.nil?
        ::File.basename(file_name)
      else
        ::File.basename(file_name, suffix)
      end
    end

    # Save the file by uploading it to Parse and creating a file pointer.
    # @param session_token [String, nil] thread an authenticated user's
    #   session token through the upload. Required when the SDK is running
    #   in client mode against a Parse Server with
    #   `fileUpload.enableForAuthenticatedUser` on (the typical safe
    #   configuration). When nil, the upload uses whatever auth the
    #   default client carries — which for client-mode builds is anonymous.
    # @param use_master_key [Boolean, nil] explicitly opt in or out of
    #   master-key auth for this upload. Defaults to the client's
    #   configured behavior. Pass `false` in client-mode code to assert
    #   that no master key is smuggled into the upload.
    # @return [Boolean] true if successfully uploaded and saved.
    def save(session_token: nil, use_master_key: nil)
      unless saved? || @contents.nil? || @name.nil?
        opts = {}
        opts[:session_token]   = session_token unless session_token.nil?
        opts[:use_master_key]  = use_master_key unless use_master_key.nil?
        response = client.create_file(@name, @contents, @mime_type, **opts)
        unless response.error?
          result = response.result
          @name = result[FIELD_NAME] || File.basename(result[FIELD_URL])
          @url = result[FIELD_URL]
        end
      end
      saved?
    end

    # @return [Boolean] true if this file is hosted by Parse's servers.
    def parse_hosted_file?
      return false if @url.blank?
      ::File.basename(@url).starts_with?("tfss-") || @url.starts_with?("http://files.parsetfss.com")
    end

    # @!visibility private
    # Inspect output deliberately omits `@url` to keep short-TTL
    # adapter-issued URLs (e.g. S3/CloudFront presigned download URLs)
    # out of exception messages, Rails error reports, and log captures.
    # The invariant for the public {url} accessor is that `@url` is
    # always a stable canonical URL — never a signed URL — but `inspect`
    # is conservative on principle: callers who explicitly want the URL
    # ask for `file.url`.
    def inspect
      url_state = @url.present? ? "set" : "blank"
      "<Parse::File @name=#{@name.inspect} @mime_type=#{@mime_type.inspect} " \
      "@contents=#{@contents.nil?} @url=#{url_state}>"
    end

    # @return [String] the url
    # @see #url
    def to_s
      @url
    end
  end
end

# Adds extensions to Hash class.
class Hash
  # Determines whether the hash contains Parse File JSON metadata fields.
  #
  # Accepts the canonical Parse Server file-pointer shapes:
  # - `{name, url}` (count == 2) with `name == File.basename(url path)`
  # - `{__type: "File", name, url}` (any count) with the same basename
  #   equality
  #
  # The URL's query string is stripped before computing basename so
  # short-TTL presigned URLs that Parse Server's S3FilesAdapter returns
  # on every read don't include the signature bytes in the comparison.
  #
  # @return [Boolean] True if this hash contains Parse file metadata.
  def parse_file?
    url = self[Parse::File::FIELD_URL]
    name = self[Parse::File::FIELD_NAME]
    return false unless url.present? && name.present?
    return false unless count == 2 || self["__type"] == Parse::File.parse_class
    path_only = url.sub(/\?.*\z/, "")
    name == ::File.basename(path_only)
  end
end
