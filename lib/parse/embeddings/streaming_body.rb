# encoding: UTF-8
# frozen_string_literal: true

require "base64"

module Parse
  module Embeddings
    # An IO-shaped request body that splices base64-encoded files into
    # a JSON envelope **without ever holding a whole file in memory**.
    #
    # Multimodal endpoints want one JSON document with the media inlined
    # as a `data:` URI. Building that with `to_json` costs roughly 2.4x
    # the media size resident (raw bytes + the 1.33x base64 copy + the
    # serialized JSON String), which is enough to OOM a small dyno on a
    # single moderate video. This class instead emits the body as a
    # stream of segments — literal JSON fragments interleaved with
    # files that are read and encoded {READ_CHUNK} bytes at a time —
    # so peak memory is bounded by the chunk size regardless of how
    # large the media is, and nothing is spilled to disk either.
    #
    # Faraday's net_http adapter assigns any body responding to `#read`
    # to `Net::HTTP::Request#body_stream`, which pulls it incrementally.
    # {#size} is exact, so callers can set `Content-Length` and avoid
    # chunked transfer encoding (which some API gateways reject).
    #
    # Base64 is spliced directly into the JSON string literal with no
    # escaping: the alphabet (`A-Za-z0-9+/=`) contains no character
    # that JSON requires escaping, so this is safe by construction.
    class StreamingBody
      # Bytes read from a source file per fill. MUST stay a multiple of
      # 3 so each chunk encodes to a padding-free base64 block and the
      # concatenation is byte-identical to encoding the whole file at
      # once. Only the final (short) chunk may carry `=` padding.
      READ_CHUNK = 57 * 1024

      # Raised when a segment's file changes size between the
      # {#size} calculation and the actual read, which would desync
      # `Content-Length` from the emitted body.
      class SizeMismatch < Parse::Embeddings::Error; end

      # @param segments [Array<String, Hash>] literal Strings are
      #   emitted verbatim; Hashes of the form
      #   `{ path: String, size: Integer }` are base64-streamed.
      def initialize(segments)
        @segments = segments.map do |seg|
          case seg
          when String then seg.dup.force_encoding(Encoding::BINARY)
          when Hash
            unless seg[:path].is_a?(String) && seg[:size].is_a?(Integer)
              raise ArgumentError,
                    "Parse::Embeddings::StreamingBody: file segment needs :path and :size."
            end
            seg
          else
            raise ArgumentError,
                  "Parse::Embeddings::StreamingBody: segment must be a String or " \
                  "{path:, size:} Hash (got #{seg.class})."
          end
        end
        rewind
      end

      # Exact byte length of the fully-emitted body. Base64 expands
      # every 3 input bytes to 4 output bytes, padded up.
      #
      # @return [Integer]
      def size
        @size ||= @segments.sum do |seg|
          seg.is_a?(String) ? seg.bytesize : 4 * ((seg[:size] + 2) / 3)
        end
      end
      alias_method :length, :size

      # @param len [Integer, nil] bytes wanted; nil reads to the end
      #   (which defeats the memory bound — Net::HTTP always passes a
      #   length, so this is only for completeness).
      # @param out [String, nil] optional output buffer to fill.
      # @return [String, nil] nil once exhausted, per IO#read semantics.
      def read(len = nil, out = nil)
        fill(len)
        if @buffer.empty?
          out&.clear
          return len.nil? ? "" : nil
        end

        chunk =
          if len.nil?
            b = @buffer
            @buffer = +""
            b
          else
            @buffer.slice!(0, len)
          end

        if out
          out.replace(chunk)
          out
        else
          chunk
        end
      end

      # Reset to the start so the body can be replayed (Net::HTTP
      # rewinds `body_stream` when it retries a request).
      #
      # @return [void]
      def rewind
        close
        @buffer = +""
        @index = 0
        @io = nil
        nil
      end

      # @return [void]
      def close
        @io&.close
        @io = nil
        nil
      end

      private

      # Top up @buffer until it holds `len` bytes or the segments run
      # out. Reads at most one READ_CHUNK per iteration, so peak
      # memory is READ_CHUNK * 4/3 plus whatever the caller asked for.
      def fill(len)
        loop do
          return if len && @buffer.bytesize >= len
          return if @index >= @segments.length

          seg = @segments[@index]
          if seg.is_a?(String)
            @buffer << seg
            @index += 1
            next
          end

          @io ||= begin
            f = ::File.open(seg[:path], "rb")
            actual = f.size
            if actual != seg[:size]
              f.close
              raise SizeMismatch,
                    "Parse::Embeddings::StreamingBody: #{seg[:path]} is #{actual} bytes but " \
                    "#{seg[:size]} was declared; the file changed underneath the request."
            end
            f
          end

          data = @io.read(READ_CHUNK)
          if data.nil? || data.empty?
            @io.close
            @io = nil
            @index += 1
            next
          end
          @buffer << Base64.strict_encode64(data)
          # A short read means EOF; close now so the padding lands and
          # the next iteration advances to the following segment.
          if data.bytesize < READ_CHUNK
            @io.close
            @io = nil
            @index += 1
          end
        end
      end
    end
  end
end
