# encoding: UTF-8
# frozen_string_literal: true

require "digest"
require_relative "provider"

module Parse
  module Embeddings
    # Deterministic, zero-network embedding provider for tests.
    #
    # Vectors are derived from a SHA-256 of `(model_name, input_type, input)`:
    # the same input always produces the same vector, different inputs
    # produce different vectors, and `:search_query` vs `:search_document`
    # produce different vectors for the same string (so cache-key bugs and
    # input-type confusion in higher layers surface in tests rather than
    # only against Cohere / Voyage in production).
    #
    # Output is unit-normalized so similarity tests don't need to know
    # the magnitude of the seed expansion.
    #
    # @example zero-config
    #   Parse::Embeddings.provider(:fixture).embed_text(["hello"])
    #   # => [[0.012, -0.043, ...]]   # length == 64 (default)
    #
    # @example custom dimensions
    #   provider = Parse::Embeddings::Fixture.new(dimensions: 1536)
    #   Parse::Embeddings.register(:openai_stub, provider)
    class Fixture < Provider
      DEFAULT_DIMENSIONS = 64
      DEFAULT_MODEL_NAME = "fixture-deterministic"
      # Matches Parse::Vector::MAX_DIMENSIONS — keeps a runaway test
      # constructor (`Fixture.new(dimensions: 10_000_000)`) from hanging
      # the suite on the SHA-256 chain expansion.
      MAX_DIMENSIONS = 16_384

      # @param dimensions [Integer] output vector width (1..16384). Choose
      #   to match the production provider you're stubbing.
      # @param model_name [String] identifier persisted to `embedding_meta`
      #   and used in cache keys.
      def initialize(dimensions: DEFAULT_DIMENSIONS, model_name: DEFAULT_MODEL_NAME)
        unless dimensions.is_a?(Integer) && dimensions.positive?
          raise ArgumentError,
                "Parse::Embeddings::Fixture: dimensions must be a positive Integer (got #{dimensions.inspect})."
        end
        if dimensions > MAX_DIMENSIONS
          raise ArgumentError,
                "Parse::Embeddings::Fixture: dimensions #{dimensions} exceeds MAX_DIMENSIONS (#{MAX_DIMENSIONS})."
        end
        @dimensions = dimensions
        @model_name = model_name.to_s
      end

      def dimensions
        @dimensions
      end

      def model_name
        @model_name
      end

      def normalize?
        true
      end

      def supports_input_type?
        true
      end

      # @param strings [Array<String>] inputs.
      # @param input_type [Symbol] `:search_query` or `:search_document`
      #   (or any symbol — Fixture treats them as independent seeds).
      # @return [Array<Array<Float>>] one unit vector per input.
      def embed_text(strings, input_type: :search_document)
        unless strings.is_a?(Array)
          raise ArgumentError,
                "Parse::Embeddings::Fixture#embed_text expects Array<String> (got #{strings.class})."
        end
        return [] if strings.empty?
        type_tag = input_type.to_s
        # Validate inputs BEFORE entering the instrument block so a
        # caller-shape error isn't recorded as a successful embed in
        # AS::N. The fixture has no network call, but emitting the
        # event keeps subscriber wiring uniform across providers —
        # operators developing against the Fixture see the same event
        # tree they'll see in production against OpenAI.
        strings.each do |s|
          unless s.is_a?(String)
            raise ArgumentError,
                  "Parse::Embeddings::Fixture#embed_text element must be String (got #{s.class})."
          end
        end
        instrument_embed(strings.length, input_type) do |_emit_payload|
          vectors = strings.map { |s| seeded_unit_vector("#{@model_name}\0#{type_tag}\0#{s}") }
          validate_response!(strings.length, vectors)
        end
      end

      private

      # Expand a UTF-8 input string into `dimensions` deterministic floats
      # in [-1, 1], then unit-normalize. The expansion stretches a
      # SHA-256 by chaining successive digests of (prev_digest || input)
      # so we get >32 bytes of entropy without depending on Ruby OpenSSL
      # specifics. Floats are derived from 32-bit unsigned big-endian
      # slices, mapped to [-1, 1].
      def seeded_unit_vector(seed_input)
        needed_bytes = @dimensions * 4
        bytes = +""
        digest = Digest::SHA256.digest(seed_input)
        while bytes.bytesize < needed_bytes
          bytes << digest
          digest = Digest::SHA256.digest(digest + seed_input)
        end
        bytes = bytes.byteslice(0, needed_bytes)
        words = bytes.unpack("N*") # @dimensions × Integer in [0, 2^32)
        scale = 2.0 / 0xFFFFFFFF
        floats = words.map { |w| (w * scale) - 1.0 }
        norm = Math.sqrt(floats.inject(0.0) { |a, f| a + (f * f) })
        # Defensive: degenerate zero vector is astronomically unlikely
        # from SHA-256 output, but guard so a downstream similarity
        # division never sees 1/0.
        if norm.zero?
          floats[0] = 1.0
          norm = 1.0
        end
        floats.map { |f| f / norm }
      end
    end
  end
end
