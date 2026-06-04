# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Retrieval
    # A single retrieved passage: one chunk of one source document,
    # carrying the document's vector-search score and (optionally
    # projected) source record.
    #
    # Produced by {Parse::Retrieval.retrieve}. Because embedding is
    # one-vector-per-record (see {Parse::Core::EmbedManaged}), every
    # chunk split from a document shares that document's single score —
    # the chunking is presentation-only, applied after retrieval.
    #
    # @!attribute [r] id
    #   @return [String] stable synthetic chunk id, `"<objectId>#<index>"`.
    # @!attribute [r] score
    #   @return [Float, nil] the parent document's Atlas vectorSearchScore,
    #     already quantized when the caller requested it.
    # @!attribute [r] content
    #   @return [String] the chunk text.
    # @!attribute [r] source
    #   @return [Hash] the parent document record. When the producer
    #     supplied a `source_transform:` (the agent tool does, projecting
    #     through `field_allowlist`), this is the projected/redacted form.
    # @!attribute [r] metadata
    #   @return [Hash] presentation metadata: `:chunk_index`,
    #     `:chunk_count`, `:chunks_truncated`, and any producer-supplied
    #     signals (e.g. `:token_chunking_degraded`).
    class Chunk
      attr_reader :id, :score, :content, :source, :metadata

      # @param id [String]
      # @param score [Float, nil]
      # @param content [String]
      # @param source [Hash]
      # @param metadata [Hash]
      def initialize(id:, content:, source:, score: nil, metadata: {})
        @id = id.to_s
        @score = score
        @content = content
        @source = source
        @metadata = metadata
        freeze
      end

      # @return [Hash] plain-Hash form for tool output / JSON.
      def to_h
        {
          id: @id,
          score: @score,
          content: @content,
          source: @source,
          metadata: @metadata,
        }
      end

      # Value equality on the identifying triple — convenient for tests
      # and de-duplication. `source`/`metadata` are intentionally not
      # part of identity.
      def ==(other)
        other.is_a?(Chunk) &&
          other.id == @id &&
          other.score == @score &&
          other.content == @content
      end
      alias eql? ==

      def hash
        [@id, @score, @content].hash
      end
    end
  end
end
