# encoding: UTF-8
# frozen_string_literal: true

require "monitor"

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
        CONFIG_MUTEX.synchronize { @configuration = nil }
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
