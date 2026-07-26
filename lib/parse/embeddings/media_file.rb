# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Embeddings
    # A file-backed image or video input that is **streamed** into the
    # request body rather than read into memory.
    #
    # This is the memory-safe counterpart to
    # {ImageFetch::FetchedImage}, which holds raw bytes. A MediaFile
    # holds only a path, a sniffed MIME type, and a byte count; the
    # bytes are read and base64-encoded incrementally by
    # {StreamingBody} while the request is being written to the socket.
    # Peak memory stays at {StreamingBody::READ_CHUNK} no matter how
    # large the file is, which is what makes video viable on a small
    # dyno.
    #
    # Only the first 16 bytes are read at construction time, to sniff
    # the container. The `Content-Type` header and the filename
    # extension are never consulted.
    #
    # @example stream a local image
    #   img = Parse::Embeddings::MediaFile.image("diagram.png")
    #   provider.embed_image([img])
    #
    # @example stream a local video
    #   clip = Parse::Embeddings::MediaFile.video("demo.mp4")
    #   provider.embed_video([clip])
    class MediaFile
      # Voyage documents 20 MB per image and 20 MB per video.
      # Overridable via {Parse::Embeddings.max_media_bytes=}.
      DEFAULT_MAX_MEDIA_BYTES = 20 * 1024 * 1024

      # Raised when a file exceeds {Parse::Embeddings.max_media_bytes}.
      class TooLarge < Parse::Embeddings::Error; end

      # @return [String] absolute path to the backing file.
      attr_reader :path
      # @return [String] sniffed MIME type.
      attr_reader :mime_type
      # @return [Integer] size in bytes, captured at construction.
      attr_reader :byte_size
      # @return [Symbol] `:image` or `:video`.
      attr_reader :kind

      class << self
        # Wrap a local image file. Verifies the magic bytes against
        # {Parse::Embeddings.allowed_image_types}.
        #
        # @param path [String]
        # @return [MediaFile]
        # @raise [ImageFetch::InvalidImageType]
        def image(path)
          header = read_header(path)
          mime = ImageFetch.sniff_mime(header)
          if mime.nil?
            raise ImageFetch::InvalidImageType.new(:unknown_magic,
              "Parse::Embeddings::MediaFile.image: #{path} matches no supported image " \
              "format (JPEG/PNG/GIF/WebP).")
          end
          allowed = Parse::Embeddings.allowed_image_types
          unless allowed.include?(mime)
            raise ImageFetch::InvalidImageType.new(:type_not_allowed,
              "Parse::Embeddings::MediaFile.image: sniffed type #{mime.inspect} is not in " \
              "Parse::Embeddings.allowed_image_types (#{allowed.inspect}).")
          end
          new(path: path, mime_type: mime, kind: :image)
        end

        # Wrap a local video file. Verifies the magic bytes against
        # {Parse::Embeddings.allowed_video_types}.
        #
        # @param path [String]
        # @return [MediaFile]
        # @raise [VideoSource::InvalidVideoType]
        def video(path)
          header = read_header(path)
          new(path: path, mime_type: VideoSource.verify!(header), kind: :video)
        end

        private

        # Read only enough bytes to sniff a container. Deliberately
        # tiny — the whole point of this class is to never hold the
        # file. A file shorter than this is passed through as-is so the
        # sniffers can reject it with their own error.
        def read_header(path)
          unless ::File.file?(path)
            raise ArgumentError,
                  "Parse::Embeddings::MediaFile: #{path.inspect} is not a readable file."
          end
          ::File.open(path, "rb") { |f| f.read(16).to_s }
        end
      end

      def initialize(path:, mime_type:, kind:)
        @path = ::File.expand_path(path)
        @mime_type = mime_type
        @kind = kind
        @byte_size = ::File.size(@path)
        if @byte_size.zero?
          raise ArgumentError,
                "Parse::Embeddings::MediaFile: #{path.inspect} is empty."
        end
        cap = Parse::Embeddings.max_media_bytes
        if @byte_size > cap
          raise TooLarge,
                "Parse::Embeddings::MediaFile: #{path.inspect} is #{@byte_size} bytes, over " \
                "the #{cap}-byte limit (Parse::Embeddings.max_media_bytes). Voyage rejects " \
                "media above 20 MB — downscale or re-encode before embedding."
        end
      end

      # The `data:` URI prefix that precedes the streamed base64 in the
      # wire body. The payload itself is never concatenated here.
      #
      # @return [String]
      def data_uri_prefix
        "data:#{mime_type};base64,"
      end

      # Segment descriptor consumed by {StreamingBody}.
      #
      # @return [Hash]
      def stream_segment
        { path: @path, size: @byte_size }
      end

      def inspect
        "#<Parse::Embeddings::MediaFile kind=#{@kind} mime_type=#{@mime_type.inspect} " \
        "bytes=#{@byte_size} path=#{@path.inspect}>"
      end
      alias_method :to_s, :inspect
    end
  end
end
