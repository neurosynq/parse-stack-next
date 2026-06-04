# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Retrieval
    # Pluggable text-chunking strategies for the retrieval layer.
    #
    # A chunker splits a source document's text into smaller, overlapping
    # windows for presentation. {Parse::Retrieval.retrieve} fetches the
    # top-k whole records via Atlas `$vectorSearch`, then runs each
    # record's text field through a chunker so callers get focused,
    # citable passages rather than whole documents.
    #
    # == Presentation chunking, not embedding chunking
    #
    # Embedding remains one-vector-per-record (see
    # {Parse::Core::EmbedManaged}). Chunking here is purely a
    # *presentation* step applied after retrieval: every chunk produced
    # from a document inherits that document's single vector-search
    # score. The chunker never calls an embedding provider.
    #
    # == Extending
    #
    # {FixedSizeOverlap} is the default and the only strategy shipped.
    # Subclass {Base} for semantic, sentence-aware, or true
    # token-aware chunking:
    #
    #   class SentenceChunker < Parse::Retrieval::Chunker::Base
    #     def chunk(text)
    #       normalize(text).split(/(?<=[.!?])\s+/)
    #     end
    #   end
    #
    #   Parse::Retrieval.retrieve(
    #     query: "onboarding steps",
    #     klass: KnowledgeArticle,
    #     chunker: SentenceChunker.new,
    #   )
    module Chunker
      # Abstract base. Subclasses MUST implement {#chunk}.
      #
      # Subclasses get one free behavior from {Base}: {#chunk_with_meta},
      # which wraps {#chunk} and reports whether the result was capped.
      # {Parse::Retrieval.retrieve} calls {#chunk_with_meta} so it can
      # stamp a truncation signal onto each emitted chunk's metadata.
      class Base
        # @param text [String, nil] source document text.
        # @return [Array<String>] zero or more chunks. MUST return `[]`
        #   for blank/`nil` input.
        # @raise [NotImplementedError] unless overridden.
        def chunk(text)
          raise NotImplementedError, "#{self.class}#chunk must return Array<String>."
        end

        # Wrap {#chunk} with truncation metadata. The default
        # implementation here does NOT cap — it reports the chunk list as
        # produced. {FixedSizeOverlap} overrides this to enforce its
        # `max_chunks_per_document` cap and report the pre-cap count.
        #
        # @param text [String, nil]
        # @return [Hash] `{ chunks: Array<String>, truncated: Boolean,
        #   total_before_truncation: Integer }`.
        def chunk_with_meta(text)
          chunks = Array(chunk(text))
          { chunks: chunks, truncated: false, total_before_truncation: chunks.length }
        end

        # @!visibility private
        # Shared input normalization. Returns `nil` for `nil`,
        # non-String, empty, or whitespace-only input — every concrete
        # `#chunk` treats a `nil` return as "no chunks". A non-String is
        # treated as blank rather than raised so a document with an
        # unexpected non-text value in the chunked field is skipped, not
        # fatal, during retrieval.
        def normalize(text)
          return nil if text.nil?
          return nil unless text.is_a?(String)
          stripped = text.strip
          stripped.empty? ? nil : text
        end
      end

      # Fixed-size sliding-window chunker with overlap.
      #
      # Splits text into windows of `size` units, advancing by
      # `size - overlap` each step so consecutive chunks share `overlap`
      # units of context. `by: :chars` (default) counts characters;
      # `by: :tokens` counts whitespace-delimited tokens (a cheap
      # approximation — there is no model tokenizer here; see the
      # `:tokens` note below).
      #
      #   c = Parse::Retrieval::Chunker::FixedSizeOverlap.new(size: 800, overlap: 100)
      #   c.chunk(long_text) #=> ["…800 chars…", "…overlap+800…", …]
      #
      # == Amplification cap
      #
      # `max_chunks_per_document` (default 200) bounds how many chunks a
      # single document can yield. Beyond the cap the chunker
      # *truncates* — it returns the first `max_chunks_per_document`
      # chunks rather than raising — and {#chunk_with_meta} reports
      # `truncated: true`. This is the DoS guard: a 10 MB field at
      # 800-char windows would otherwise yield ~12,500 chunks.
      #
      # == `:tokens`
      #
      # `by: :tokens` treats `size`/`overlap` as literal whitespace-token
      # counts supplied by the caller. The chunker does NOT consult an
      # embedding provider's `max_input_tokens`; that hint is the
      # caller's concern (see {Parse::Retrieval.retrieve}). The chunker
      # always does exactly what it was constructed with and never
      # silently switches modes.
      class FixedSizeOverlap < Base
        # @return [Integer] window width in `by:` units.
        attr_reader :size
        # @return [Integer] units shared between consecutive windows.
        attr_reader :overlap
        # @return [Symbol] `:chars` or `:tokens`.
        attr_reader :by
        # @return [Integer] hard cap on chunks emitted per document.
        attr_reader :max_chunks_per_document

        # @param size [Integer] window width (> 0).
        # @param overlap [Integer] shared units between windows
        #   (`0 <= overlap < size`).
        # @param by [Symbol] `:chars` (default) or `:tokens`.
        # @param max_chunks_per_document [Integer] cap (> 0, default 200).
        # @raise [ArgumentError] on any out-of-range argument. In
        #   particular `overlap >= size` is refused: a non-shrinking
        #   stride would never advance and would loop forever.
        def initialize(size: 800, overlap: 100, by: :chars, max_chunks_per_document: 200)
          unless size.is_a?(Integer) && size > 0
            raise ArgumentError, "size must be a positive Integer (got #{size.inspect})."
          end
          unless overlap.is_a?(Integer) && overlap >= 0
            raise ArgumentError, "overlap must be a non-negative Integer (got #{overlap.inspect})."
          end
          if overlap >= size
            raise ArgumentError,
                  "overlap (#{overlap}) must be strictly less than size (#{size}); " \
                  "a stride of size - overlap <= 0 would never advance."
          end
          unless %i[chars tokens].include?(by)
            raise ArgumentError, "by must be :chars or :tokens (got #{by.inspect})."
          end
          unless max_chunks_per_document.is_a?(Integer) && max_chunks_per_document > 0
            raise ArgumentError,
                  "max_chunks_per_document must be a positive Integer " \
                  "(got #{max_chunks_per_document.inspect})."
          end
          @size = size
          @overlap = overlap
          @by = by
          @max_chunks_per_document = max_chunks_per_document
          @stride = size - overlap
        end

        # @param text [String, nil]
        # @return [Array<String>] chunks (capped at
        #   {#max_chunks_per_document}). `[]` for blank input.
        def chunk(text)
          chunk_with_meta(text)[:chunks]
        end

        # (see Base#chunk_with_meta)
        def chunk_with_meta(text)
          source = normalize(text)
          return { chunks: [], truncated: false, total_before_truncation: 0 } if source.nil?

          all = (@by == :tokens) ? window_tokens(source) : window_chars(source)
          total = all.length
          if total > @max_chunks_per_document
            { chunks: all.first(@max_chunks_per_document),
              truncated: true,
              total_before_truncation: total }
          else
            { chunks: all, truncated: false, total_before_truncation: total }
          end
        end

        private

        def window_chars(text)
          len = text.length
          out = []
          start = 0
          while start < len
            out << text[start, @size]
            start += @stride
          end
          out
        end

        def window_tokens(text)
          tokens = text.split(/\s+/).reject(&:empty?)
          return [] if tokens.empty?
          out = []
          start = 0
          n = tokens.length
          while start < n
            out << tokens[start, @size].join(" ")
            start += @stride
          end
          out
        end
      end
    end
  end
end
