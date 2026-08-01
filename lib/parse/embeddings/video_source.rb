# encoding: UTF-8
# frozen_string_literal: true

require "base64"

module Parse
  module Embeddings
    # Value objects and magic-byte verification for video inputs to
    # multimodal embedding providers.
    #
    # This mirrors {ImageFetch} deliberately — same sniff-then-verify
    # discipline, same refusal to trust a `Content-Type` header — but
    # it deliberately ships NO byte-holding value object and NO
    # `fetch!` counterpart. Video payloads are large enough that
    # holding one in memory can exhaust a small dyno, so both supported
    # paths avoid it:
    #
    # * **local file** — wrap with {Parse::Embeddings::MediaFile.video},
    #   which reads only the 16-byte header. The bytes are base64-
    #   streamed into the request by {StreamingBody} at send time.
    # * **URL** — pass the URL String straight to `embed_video`, which
    #   validates it through {Parse::Embeddings.validate_image_url!}
    #   (a generic URL-safety guard despite the name: CIDR screen, port
    #   and host allowlist, sentinel-gated egress) and lets the
    #   provider do the fetch. The SDK never downloads the video.
    module VideoSource
      # Raised when bytes fail verification — unknown magic, or a
      # sniffed type outside the allowlist. Carries a `:reason` tag
      # (`:empty`, `:unknown_magic`, `:type_not_allowed`) matching
      # {ImageFetch::InvalidImageType}'s convention.
      class InvalidVideoType < Parse::Embeddings::Error
        # @return [Symbol] failure-mode tag.
        attr_reader :reason

        def initialize(reason, message)
          @reason = reason
          super(message)
        end
      end

      # MIME types accepted by default. Voyage documents MP4 as the
      # only supported video container, and the live API rejects WebM
      # and QuickTime payloads outright — so accepting them here would
      # only trade a clear local error for an opaque provider 400.
      # {.sniff_mime} still *recognizes* those containers so the
      # rejection can name what was actually supplied.
      DEFAULT_ALLOWED_VIDEO_TYPES = %w[video/mp4].freeze

      # ISO Base Media major brands, split by the MIME type they imply.
      # An `ftyp` box alone does NOT mean MP4 — QuickTime and the
      # audio-only profiles share the container — so brands are matched
      # explicitly and an unknown brand sniffs as nil rather than being
      # assumed to be MP4.
      #
      # `M4A` is deliberately absent: it is Apple's audio-only profile,
      # and admitting it here would let an audio file pass as video and
      # be sent to a provider that accepts neither.
      MP4_BRANDS = %w[isom iso2 iso4 iso5 iso6 mp41 mp42 avc1 dash mmp4 M4V].freeze
      QUICKTIME_BRANDS = %w[qt].freeze

      module_function

      # Determine a video's MIME type from its leading magic bytes.
      # Returns nil for anything unrecognized — callers must treat nil
      # as a refusal and never fall back to extension or header typing.
      #
      # @param bytes [String] raw video bytes (at least the first 12).
      # @return [String, nil] sniffed MIME type, or nil when unknown.
      def sniff_mime(bytes)
        return nil unless bytes.is_a?(String) && bytes.bytesize >= 12
        b = bytes.byteslice(0, 16).force_encoding(Encoding::BINARY)

        # Matroska / WebM share an EBML header; WebM is the profile
        # every multimodal provider documents, so report it as WebM.
        return "video/webm" if b.start_with?("\x1A\x45\xDF\xA3".b)

        # ISO Base Media File Format: a size-prefixed `ftyp` box. The
        # 4-byte major brand at offset 8 separates QuickTime from MP4.
        # Unknown brands return nil — guessing "MP4" for an arbitrary
        # ISO-BMFF file sends the provider something it will reject.
        if b.byteslice(4, 4) == "ftyp".b
          brand = b.byteslice(8, 4).to_s.strip
          return "video/quicktime" if QUICKTIME_BRANDS.include?(brand)
          return "video/mp4" if MP4_BRANDS.include?(brand)
          return nil
        end

        nil
      end

      # Sniff the magic bytes and check the allowlist. Only the leading
      # bytes are inspected, so callers may pass a short header slice
      # rather than the whole file — which is what
      # {Parse::Embeddings::MediaFile.video} does.
      #
      # @param bytes [String] leading video bytes (at least 12).
      # @return [String] the sniffed MIME type.
      # @raise [InvalidVideoType]
      def verify!(bytes)
        if bytes.nil? || bytes.empty?
          raise InvalidVideoType.new(:empty,
                                     "Parse::Embeddings::VideoSource: video payload is empty.")
        end
        mime = sniff_mime(bytes)
        if mime.nil?
          raise InvalidVideoType.new(:unknown_magic,
                                     "Parse::Embeddings::VideoSource: leading bytes match no supported video " \
                                     "container (MP4/QuickTime/WebM). The Content-Type header is not consulted — " \
                                     "unrecognized content is refused outright.")
        end
        allowed = Parse::Embeddings.allowed_video_types
        unless allowed.include?(mime)
          raise InvalidVideoType.new(:type_not_allowed,
                                     "Parse::Embeddings::VideoSource: sniffed type #{mime.inspect} is not in " \
                                     "Parse::Embeddings.allowed_video_types (#{allowed.inspect}).")
        end
        mime
      end
    end
  end
end
