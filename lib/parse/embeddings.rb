# encoding: UTF-8
# frozen_string_literal: true

require "monitor"
require "uri"
require "ipaddr"

module Parse
  # Pluggable embedding-provider registry for `:vector` properties and
  # the upcoming `find_similar(text:)` / `Parse::Retrieval.retrieve`
  # surfaces.
  #
  # Text-only providers shipped:
  #
  # * {Fixture}   — deterministic, zero-network. Auto-registered as
  #   `:fixture` so tests can call `Parse::Embeddings.provider(:fixture)`
  #   with no setup.
  # * {OpenAI}    — text-embedding-3-{small,large} and ada-002.
  # * {Cohere}    — embed-{english,multilingual}-v3.0 and `*-light-v3.0`.
  #   Distinguishes `:search_query` / `:search_document` at the wire.
  # * {Voyage}    — voyage-4 family (incl. open-weight `voyage-4-nano`),
  #   voyage-3 family, voyage-code-3, voyage-finance-2, voyage-law-2.
  #   Distinguishes input types.
  # * {Jina}      — jina-embeddings-v3/v4/v5 (text + omni-text mode),
  #   jina-code-embeddings-{0.5b,1.5b}. Matryoshka via `dimensions:`.
  # * {Qwen}      — qwen3-embedding-{0.6b,4b,8b} via Alibaba Cloud
  #   DashScope compatible-mode. All Matryoshka. The same checkpoints
  #   are open-weight on Hugging Face (Apache 2.0) for self-hosting
  #   behind {LocalHTTP}.
  # * {LocalHTTP} — generic OpenAI-compatible client for Ollama,
  #   LM Studio, vLLM, etc. Configure-time SSRF gate; requires
  #   `allow_private_endpoint: true` to talk to localhost.
  #
  # Image / multimodal embedding (`embed_image`) is a forthcoming
  # feature — the {Provider#embed_image} hook is defined but only the
  # multimodal-capable providers will override it.
  #
  # == Registration
  #
  # Two equivalent forms. {.register} is the canonical one-liner and
  # what every example in the gem uses; {.configure} is the block form
  # for registering several providers at once or for Rails-style
  # initializers. Both end up at the same {ProviderRegistry}, so pick
  # whichever reads better in context.
  #
  # @example canonical: register one provider
  #   Parse::Embeddings.register(:openai,
  #     Parse::Embeddings::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY")))
  #
  # @example block form for several providers
  #   Parse::Embeddings.configure do |c|
  #     c.providers[:openai] = Parse::Embeddings::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY"))
  #     c.providers[:openai_large] = Parse::Embeddings::OpenAI.new(
  #       api_key: ENV.fetch("OPENAI_API_KEY"), model: "text-embedding-3-large")
  #   end
  #
  # @example lookup
  #   Parse::Embeddings.provider(:openai)   # => the registered instance
  #   Parse::Embeddings.provider(:fixture)  # => default Fixture, zero-config
  module Embeddings
    # Common superclass for every embeddings-layer exception. Concrete
    # providers (OpenAI, Cohere, Voyage, …) should raise subclasses of
    # this so retry middleware and caller `rescue` chains have a single
    # target. Inherits from {StandardError}, not {Parse::Error}, because
    # embedding providers are external HTTP boundaries — their failures
    # are distinct from Parse Server protocol errors.
    class Error < StandardError; end

    # Raised when a provider returns a response that doesn't satisfy the
    # contract (wrong length, NaN, ±Inf, non-Array, wrong-width vector,
    # non-Float/Integer elements). See {Provider#validate_response!}.
    class InvalidResponseError < Error; end

    # Raised when {Embeddings.provider} is called with an unknown name
    # and no built-in default exists for that key. Remains an
    # {ArgumentError} (not an {Error}) so config-time mistakes are
    # distinguishable from runtime provider failures.
    class ProviderNotRegistered < ArgumentError; end

    # Raised when {Embeddings.trust_provider_url_fetch=} is assigned
    # anything other than the deliberate-opt-in sentinel String, or
    # when {.validate_image_url!} is called while the toggle is still
    # off. Sentinel-gated opt-in mirrors {Parse::Object.acl_off_confirm}
    # — a plain `true` is refused, preventing accidental enablement
    # via `Parse::Embeddings.trust_provider_url_fetch = ENV['SOMETHING']`
    # that an operator never intended to set. The only accepted value
    # is the exact frozen String `"PROVIDER_EGRESS_VERIFIED"`.
    #
    # Threat model: image-URL forwarding hands an attacker-controlled
    # URL (chat input, document field, agent tool argument) to a
    # third-party provider that will then issue an HTTP request from
    # its own network. Even with the SDK's CIDR / port / host
    # allowlist enforced at validation time, the provider's actual
    # fetch happens later (DNS-rebinding window) and can follow
    # redirects the SDK never saw. Forcing operators to set a sentinel
    # that explicitly names the egress risk makes it impossible to
    # enable accidentally.
    class ConfirmationRequired < Error; end

    # Raised when {.validate_image_url!} rejects an input URL. Carries
    # a `:reason` String so retry / logging code can branch on the
    # specific failure mode (`:scheme`, `:port`, `:userinfo`, `:host_blocked`,
    # `:host_not_allowlisted`, `:dns_rebound`, `:parse`).
    class InvalidImageURL < Error
      # @return [Symbol] failure-mode tag.
      attr_reader :reason
      def initialize(reason, message)
        @reason = reason
        super(message)
      end
    end
  end
end

# Provider must load before OpenAI (which references it as superclass)
# and before ProviderRegistry below (which type-checks against it).
require_relative "embeddings/provider"

module Parse
  module Embeddings
    # Hash subclass that enforces {Provider} membership at assignment
    # time. Without this, `configuration.providers[:openai] = "anything"`
    # would silently bypass {Embeddings.register}'s type-check and let a
    # duck-typed object skip {Provider#validate_response!} — defeating
    # the whole boundary contract.
    class ProviderRegistry < Hash
      def []=(name, provider)
        unless provider.is_a?(Provider)
          raise ArgumentError,
                "Parse::Embeddings::ProviderRegistry: #{name.inspect} expects a " \
                "Parse::Embeddings::Provider instance (got #{provider.class})."
        end
        super(name.to_sym, provider)
      end
      alias_method :store, :[]=
    end

    # Configuration container yielded to {Embeddings.configure}.
    class Configuration
      # @return [ProviderRegistry] type-checked provider registry.
      attr_reader :providers

      def initialize
        @providers = ProviderRegistry.new
      end
    end

    # Monitor guarding {Embeddings.configuration} memoization and
    # {Embeddings.register} writes. MRI's GVL would normally absorb
    # the race on `@configuration ||= ...`, but JRuby and TruffleRuby
    # can produce two `Configuration` instances when two threads race
    # at boot (and lose any provider written to the loser). A Monitor
    # (rather than a Mutex) is used so that `register` — which holds
    # the lock and then calls `configuration` — can re-enter without
    # deadlocking on the first-touch allocation path.
    CONFIG_MUTEX = Monitor.new

    class << self
      # Block form for registering multiple providers at once. Prefer
      # the one-liner {.register} when adding a single provider; this
      # form pays off when an initializer needs to set several or to
      # mutate the registry conditionally.
      #
      # @yieldparam config [Configuration]
      # @return [Configuration]
      def configure
        yield configuration if block_given?
        configuration
      end

      # @return [Configuration] the singleton configuration object.
      def configuration
        # Double-checked memoization. The fast path is a single ivar
        # read; the slow path enters the mutex only when the
        # configuration is unallocated.
        @configuration || CONFIG_MUTEX.synchronize { @configuration ||= Configuration.new }
      end

      # Canonical one-liner: register a single provider under `name`.
      # Overwrites any previous registration. Use {.configure} for
      # multi-provider blocks.
      #
      # @param name [Symbol, String]
      # @param provider [Provider]
      # @return [Provider] the registered provider.
      def register(name, provider)
        unless provider.is_a?(Provider)
          raise ArgumentError,
                "Parse::Embeddings.register: #{name.inspect} expects a Parse::Embeddings::Provider " \
                "instance (got #{provider.class})."
        end
        CONFIG_MUTEX.synchronize do
          configuration.providers[name.to_sym] = provider
        end
      end

      # Look up a registered provider.
      #
      # **Zero-config fallback:** `:fixture` returns a default
      # {Fixture} instance (64-dim, deterministic) when nothing is
      # registered. Every other name raises {ProviderNotRegistered}.
      # Tests can rely on `provider(:fixture)` working out of the box;
      # production code must register what it uses.
      #
      # @param name [Symbol, String]
      # @return [Provider]
      # @raise [ProviderNotRegistered] when the name is unknown.
      def provider(name)
        # Avoid blindly `to_sym`-ing the caller's input. An LLM tool or
        # webhook handler that pipes its `name:` argument through here
        # would otherwise let a remote caller grow the symbol table at
        # will. Ruby 3.2+ GCs symbols so the practical impact is small,
        # but a string-matched lookup costs nothing and closes the gap.
        if name.is_a?(Symbol)
          return configuration.providers[name] if configuration.providers.key?(name)
          key_string = name.to_s
        else
          key_string = name.to_s
          found = configuration.providers.keys.find { |k| k.to_s == key_string }
          return configuration.providers[found] if found
        end
        if key_string == "fixture"
          CONFIG_MUTEX.synchronize do
            return configuration.providers[:fixture] ||= Fixture.new
          end
        end
        raise ProviderNotRegistered,
              "Parse::Embeddings.provider(#{name.inspect}): no provider registered. " \
              "Register one via Parse::Embeddings.register(#{name.inspect}, …)."
      end

      # Names of currently-registered providers (does NOT include the
      # implicit `:fixture` fallback unless it's been instantiated).
      #
      # @return [Array<Symbol>]
      def registered_provider_names
        configuration.providers.keys
      end

      # Reset the entire registry — intended for test teardown only.
      # Production code should never call this; use {.register} to
      # override a single provider.
      #
      # @return [void]
      def reset!
        CONFIG_MUTEX.synchronize do
          @configuration = nil
          @allowed_image_hosts = nil
          @allowed_image_types = nil
          @trust_provider_url_fetch = nil
        end
      end

      # =======================================================================
      # Image-URL forwarding (v5.1) — SSRF-gated egress to provider boundaries
      # =======================================================================

      # The sentinel value that {.trust_provider_url_fetch=} requires.
      # An exact match unlocks {.validate_image_url!} for URL forwarding
      # to embedding providers. Any other value is refused with
      # {ConfirmationRequired}. The constant is frozen so callers
      # cannot mutate it in-place.
      TRUST_PROVIDER_URL_FETCH_SENTINEL = "PROVIDER_EGRESS_VERIFIED"

      # Configure the host allowlist that {.validate_image_url!} checks
      # an incoming image URL's host against. Entries that begin with
      # `.` match suffixes (`.cdn.example.com` matches
      # `images.cdn.example.com` and `cdn.example.com` itself);
      # entries without a leading `.` are exact-match.
      #
      # **Empty allowlist means "deny all".** This is the opposite
      # default from {Parse::File.allowed_remote_hosts} (where empty
      # means "any public host"). The asymmetry is deliberate: image
      # URLs that reach {.validate_image_url!} typically originate from
      # attacker-controlled inputs (chat queries, agent tool args,
      # user-submitted document fields), so opening the surface
      # requires an explicit operator declaration of which CDNs are
      # trusted.
      #
      # @example Trust two CDN hostnames
      #   Parse::Embeddings.allowed_image_hosts = [
      #     "images.example-cdn.com",
      #     ".cloudfront.net",   # any *.cloudfront.net host
      #   ]
      #
      # @param hosts [Array<String>] hostnames or `.suffix` patterns.
      # @return [Array<String>]
      def allowed_image_hosts=(hosts)
        unless hosts.is_a?(Array) && hosts.all? { |h| h.is_a?(String) && !h.empty? }
          raise ArgumentError,
                "Parse::Embeddings.allowed_image_hosts= expects Array<String> of " \
                "non-empty hostnames or '.suffix' patterns (got #{hosts.inspect})."
        end
        CONFIG_MUTEX.synchronize { @allowed_image_hosts = hosts.dup.freeze }
      end

      # @return [Array<String>] currently-configured image-host allowlist (frozen).
      def allowed_image_hosts
        @allowed_image_hosts ||= [].freeze
      end

      # Configure the MIME types the bytes-fetch path accepts after
      # magic-byte sniffing (see {ImageFetch.verify!}). Defaults to
      # {ImageFetch::DEFAULT_ALLOWED_IMAGE_TYPES} (JPEG / PNG / GIF /
      # WebP). The sniffed type — never the `Content-Type` header — is
      # checked against this list, so adding a type here only matters
      # when {ImageFetch.sniff_mime} can recognize its magic bytes.
      #
      # @param types [Array<String>] MIME type strings.
      # @return [Array<String>]
      def allowed_image_types=(types)
        unless types.is_a?(Array) && !types.empty? &&
               types.all? { |t| t.is_a?(String) && t.include?("/") }
          raise ArgumentError,
                "Parse::Embeddings.allowed_image_types= expects a non-empty Array of " \
                "MIME type Strings (got #{types.inspect})."
        end
        CONFIG_MUTEX.synchronize { @allowed_image_types = types.dup.freeze }
      end

      # @return [Array<String>] MIME allowlist for the bytes-fetch path (frozen).
      def allowed_image_types
        @allowed_image_types ||= ImageFetch::DEFAULT_ALLOWED_IMAGE_TYPES
      end

      # Sentinel-gated opt-in for forwarding image URLs to embedding
      # providers. Assign the exact {TRUST_PROVIDER_URL_FETCH_SENTINEL}
      # String to unlock; any other value (including `true`, `1`,
      # `"true"`, or a non-matching String) raises
      # {ConfirmationRequired}. Reset to `nil` to disable.
      #
      # @param value [String, nil] {TRUST_PROVIDER_URL_FETCH_SENTINEL} or nil.
      # @raise [ConfirmationRequired] on any other value.
      def trust_provider_url_fetch=(value)
        if value.nil?
          CONFIG_MUTEX.synchronize { @trust_provider_url_fetch = nil }
          return
        end
        unless value.is_a?(String) && value == TRUST_PROVIDER_URL_FETCH_SENTINEL
          raise ConfirmationRequired,
                "Parse::Embeddings.trust_provider_url_fetch= requires the exact sentinel " \
                "String #{TRUST_PROVIDER_URL_FETCH_SENTINEL.inspect}. Plain `true` and " \
                "other values are refused — forwarding image URLs to a third-party " \
                "provider lets that provider issue an HTTP request from its own network " \
                "with attacker-controllable host/path. Set the sentinel only after you " \
                "have configured Parse::Embeddings.allowed_image_hosts AND reviewed the " \
                "provider's documented egress behavior (DNS rebinding window, redirect " \
                "policy)."
        end
        CONFIG_MUTEX.synchronize { @trust_provider_url_fetch = value }
      end

      # @return [Boolean] whether image-URL forwarding is currently unlocked.
      def trust_provider_url_fetch?
        @trust_provider_url_fetch == TRUST_PROVIDER_URL_FETCH_SENTINEL
      end

      # Validate an image URL for forwarding to an embedding provider.
      # Returns the canonicalized URL String on success; raises
      # {InvalidImageURL} or {ConfirmationRequired} on failure.
      #
      # Validation layers (in order):
      # 1. {.trust_provider_url_fetch?} sentinel must be set. Without
      #    it, no URL — public or private — is forwarded.
      # 2. URL parses as `https://` (or `http://` if `allow_insecure:`
      #    is true; only intended for local development).
      # 3. No userinfo (basic-auth credentials in the URL).
      # 4. Port is in {Parse::File.allowed_remote_ports}.
      # 5. Host resolves only to addresses NOT in
      #    {Parse::File::BLOCKED_CIDRS} (CIDR check via
      #    `Parse::File.assert_host_allowed!`). The same primitive is
      #    used by {Parse::File.safe_open_url}, so the SSRF mechanism
      #    is shared.
      # 6. Host matches {.allowed_image_hosts}. Empty allowlist denies
      #    every host — see {.allowed_image_hosts=} for rationale.
      #
      # The DNS-rebinding window between this validation and the
      # provider's own fetch is the residual risk that
      # {.trust_provider_url_fetch=} forces the operator to acknowledge.
      #
      # @param url [String] image URL.
      # @param allow_insecure [Boolean] permit `http://` (default
      #   false). Only meaningful for local development / container-
      #   internal CDN proxies.
      # @param mode [Symbol] `:forward` (default) validates for
      #   URL-forwarding to a provider and requires the
      #   {.trust_provider_url_fetch=} sentinel. `:fetch` validates for
      #   the SDK's OWN download through {Parse::File.safe_open_url}
      #   (the v5.5 bytes path) and skips the sentinel — no URL is
      #   forwarded to a third party, so the provider-egress
      #   acknowledgment doesn't apply. Every other layer (host
      #   allowlist deny-by-default, obfuscated-IP screen, port
      #   allowlist, CIDR resolution check) is identical in both modes.
      # @return [String] canonicalized URL (`URI.parse(url).to_s`).
      # @raise [ConfirmationRequired] when the sentinel is unset (`:forward` mode).
      # @raise [InvalidImageURL] on any other validation failure.
      def validate_image_url!(url, allow_insecure: false, mode: :forward)
        unless mode == :fetch || trust_provider_url_fetch?
          hint =
            if allowed_image_hosts.empty?
              " First populate Parse::Embeddings.allowed_image_hosts with the CDN " \
              "hostnames you trust (currently empty — every host would be denied " \
              "even after the sentinel is set)."
            else
              ""
            end
          raise ConfirmationRequired,
                "Parse::Embeddings.validate_image_url! refused: image-URL forwarding is " \
                "disabled. Set Parse::Embeddings.trust_provider_url_fetch = " \
                "#{TRUST_PROVIDER_URL_FETCH_SENTINEL.inspect} to enable it.#{hint}"
        end

        unless url.is_a?(String) && !url.empty?
          raise InvalidImageURL.new(:parse,
            "Parse::Embeddings.validate_image_url!: url must be a non-empty String " \
            "(got #{url.class}).")
        end

        uri = begin
          URI.parse(url)
        rescue URI::InvalidURIError => e
          raise InvalidImageURL.new(:parse,
            "Parse::Embeddings.validate_image_url!: invalid URL (#{e.message}).")
        end

        valid_schemes = allow_insecure ? %w[http https] : %w[https]
        unless valid_schemes.include?(uri.scheme)
          raise InvalidImageURL.new(:scheme,
            "Parse::Embeddings.validate_image_url!: scheme must be #{valid_schemes.join(' or ')} " \
            "(got #{uri.scheme.inspect}). Forwarding non-HTTPS image URLs to a provider " \
            "leaks any embedded query-string secrets in cleartext.")
        end

        if uri.userinfo
          raise InvalidImageURL.new(:userinfo,
            "Parse::Embeddings.validate_image_url!: URL must not include userinfo " \
            "credentials. Embedding providers will forward the full URL in their fetch " \
            "and may log it.")
        end

        # `uri.hostname` returns the IDNA-decoded form WITHOUT IPv6
        # brackets, where `uri.host` keeps the brackets. Using
        # `hostname` makes the allowlist comparison work uniformly for
        # IPv6 literals (operators write `::1`, not `[::1]`) and
        # matches the form `Parse::File.assert_host_allowed!` expects.
        host = uri.hostname
        if host.nil? || host.empty?
          raise InvalidImageURL.new(:parse,
            "Parse::Embeddings.validate_image_url!: URL is missing a host.")
        end

        # Reject non-canonical IPv4 forms (decimal `2130706433`,
        # octal `0177.0.0.1`, hex `0x7f.0.0.1`) before they reach
        # resolution. Most stacks' Resolv returns [] for these, so
        # they'd be blocked anyway — but via the resolution-failure
        # branch (`:parse` reason) rather than the CIDR branch, which
        # makes the failure mode look like a benign typo when it's
        # actually an obfuscated-localhost SSRF attempt. Explicitly
        # tagging the failure as `:host_blocked` keeps operator logs
        # honest. We allow exactly: dotted-quad IPv4 (4 decimal
        # octets), bracketed-or-bare IPv6 (parsed by IPAddr), and
        # DNS hostnames (anything containing a letter or non-numeric
        # character).
        if ip_shaped_but_not_canonical?(host)
          raise InvalidImageURL.new(:host_blocked,
            "Parse::Embeddings.validate_image_url!: host #{host.inspect} is an obfuscated " \
            "or non-canonical IP literal. Use dotted-quad IPv4 (a.b.c.d) or canonical IPv6. " \
            "Decimal/octal/hex IP forms are refused to prevent localhost-bypass attempts.")
        end

        # **Image-host allowlist runs BEFORE the resolver hop.** Round-2
        # audit (LOW finding #3) noted that a caller passing N URLs to
        # a public `embed_image` API could amplify DNS traffic at ~N×
        # before the allowlist filtered them out — the pure-string
        # match is cheap, the resolution is a syscall. Allowlist-first
        # ordering eliminates the amplification surface.
        allowed = allowed_image_hosts
        if allowed.empty?
          raise InvalidImageURL.new(:host_not_allowlisted,
            "Parse::Embeddings.validate_image_url!: Parse::Embeddings.allowed_image_hosts " \
            "is empty — every image URL is denied. Add the CDN hostnames you trust before " \
            "forwarding image URLs to a provider.")
        end
        permitted = allowed.any? do |entry|
          if entry.start_with?(".")
            host.downcase.end_with?(entry.downcase) ||
              host.casecmp(entry[1..]).zero?
          else
            host.casecmp(entry).zero?
          end
        end
        unless permitted
          raise InvalidImageURL.new(:host_not_allowlisted,
            "Parse::Embeddings.validate_image_url!: host #{host.inspect} not in " \
            "Parse::Embeddings.allowed_image_hosts (#{allowed.inspect}).")
        end

        # Port allowlist runs after the host allowlist (cheap string
        # check first). Reuses Parse::File's port allowlist — same
        # threat model (internal-port probing via DNS rebinding).
        port = uri.port || (uri.scheme == "https" ? 443 : 80)
        require_relative "model/file"
        unless Parse::File.allowed_remote_ports.include?(port)
          raise InvalidImageURL.new(:port,
            "Parse::Embeddings.validate_image_url!: port #{port} not in " \
            "Parse::File.allowed_remote_ports.")
        end

        # CIDR + DNS resolution last — most expensive (syscall). An
        # allowlisted CDN hostname pointing at a private IP (DNS
        # poisoning / hostile-allowlist-entry / first-party rebind)
        # is the residual surface this catches. Delegates to
        # Parse::File's shared SSRF primitive.
        begin
          Parse::File.assert_host_allowed!(host)
        rescue ArgumentError => e
          tag = e.message.include?("private/internal address") ? :host_blocked : :parse
          raise InvalidImageURL.new(tag,
            "Parse::Embeddings.validate_image_url!: #{e.message}")
        end

        # Return the canonicalized URL so callers store/forward
        # exactly what was validated, not the raw input.
        uri.to_s
      end

      # @api private
      # Return true when `host` looks like an obfuscated IP literal —
      # rejecting hex (`0x7f.0.0.1`), octal-leading-zero (`0177.0.0.1`),
      # decimal-blob (`2130706433`), and IPv4 short-forms (`127.1`,
      # `127.0.1`) BEFORE they reach DNS resolution. Anything that's
      # clearly a hostname (contains a letter) falls through; canonical
      # dotted-quad IPv4 and canonical IPv6 fall through; everything
      # else is treated as obfuscated.
      #
      # Round-2 audit identified two bypasses in the prior version:
      # (1) `0x7f.0.0.1` passed the `[a-zA-Z]` early-out because of
      # the `x`, and (2) bare-digit hostnames like `127.1` were
      # accepted as DNS hostnames. This rewrite makes the check
      # whitelist-shaped: explicit accept for canonical IPv4 / IPv6 /
      # alpha-containing hostnames; explicit reject for hex prefix and
      # any pure digits-and-dots that isn't a canonical 4-octet form.
      def ip_shaped_but_not_canonical?(host)
        # Hex prefix anywhere in the host (`0x7f`, `0.0X7f.0.1`) →
        # obfuscated. Case-insensitive `x`.
        return true if host =~ /(\A|\.)0[xX]/

        # Strict canonical dotted-quad IPv4: exactly 4 decimal octets,
        # 0..255, no leading zeros (except `0` itself).
        if host =~ /\A\d+(?:\.\d+){3}\z/
          octets = host.split(".")
          return true if octets.any? { |s| s.length > 1 && s.start_with?("0") }  # octal
          return true if octets.map(&:to_i).any? { |o| o > 255 }                 # > 255
          return false
        end

        # Numeric-only with dots but not 4 octets (`127.1`, `1.2.3`,
        # `1.2.3.4.5`) → IPv4 short-form / oversized. Refuse.
        return true if host =~ /\A\d+(?:\.\d+)+\z/

        # Pure-digit single label (`2130706433`, `0`, `42`) → decimal
        # IP blob. Refuse.
        return true if host =~ /\A\d+\z/

        # Anything else: try parsing as IPv6 (canonical IPv6 literals
        # like `::1`, `2001:db8::1`, `::ffff:1.2.3.4` succeed; the
        # CIDR check downstream catches private ranges including
        # IPv4-mapped IPv6 of private IPv4).
        begin
          IPAddr.new(host)
          false
        rescue IPAddr::InvalidAddressError
          # Not an IP, not numeric-shaped → must be a hostname.
          # Resolver downstream will validate or reject.
          false
        end
      end
    end
  end
end

# Concrete providers — loaded after Error / Provider / ProviderRegistry
# so their class bodies can reference those constants.
require_relative "embeddings/fixture"
require_relative "embeddings/openai"
require_relative "embeddings/cohere"
require_relative "embeddings/voyage"
require_relative "embeddings/jina"
require_relative "embeddings/qwen"
require_relative "embeddings/local_http"
require_relative "embeddings/spend_cap"
require_relative "embeddings/image_fetch"
require_relative "embeddings/cache"
require_relative "embeddings/batch_embedder"
