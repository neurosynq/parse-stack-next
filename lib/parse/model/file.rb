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

    # Regular expression that matches the old legacy Parse hosted file name
    LEGACY_FILE_RX = /^tfss-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}-/
    # The default attributes in a Parse File hash.
    ATTRIBUTES = { __type: :string, name: :string, url: :string }.freeze

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
    # Assign the file's URL. Routes through the same
    # {Parse::File.sanitize_hydrated_url} validator that hydration uses,
    # so caller-supplied URLs (e.g. `parse_file.url = params[:url]`) get
    # the same trusted-host check as JSON-hydrated rows.
    # @param value [String, nil] the URL to assign.
    def url=(value)
      @url = Parse::File.sanitize_hydrated_url(value, fallback: @url, name: @name)
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
        @url = name.url
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

    # A File object is considered saved if the basename of the URL and the name parameters are equal
    # @return [Boolean] true if this file has already been saved.
    def saved?
      @url.present? && @name.present? && @name == File.basename(@url)
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
    def attributes=(h)
      raw_url = nil
      if h.is_a?(String)
        raw_url = h
        @name = File.basename(h)
      elsif h.is_a?(Hash)
        raw_url = h[FIELD_URL] || h[:url]
        @name = h[FIELD_NAME] || h[:name] || @name
      end
      @url = Parse::File.sanitize_hydrated_url(raw_url, fallback: @url, name: @name)
    end

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
    def inspect
      "<Parse::File @name='#{@name}' @mime_type='#{@mime_type}' @contents=#{@contents.nil?} @url='#{@url}'>"
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
  # Determines if the hash contains Parse File json metadata fields. This is determined whether
  # the key `__type` exists and is of type `__File` and whether the `name` field matches the File.basename
  # of the `url` field.
  #
  # @return [Boolean] True if this hash contains Parse file metadata.
  def parse_file?
    url = self[Parse::File::FIELD_URL]
    name = self[Parse::File::FIELD_NAME]
    (count == 2 || self["__type"] == Parse::File.parse_class) &&
    url.present? && name.present? && name == ::File.basename(url)
  end
end
