# encoding: UTF-8
# frozen_string_literal: true

require "base64"
require "uri"

module Parse
  module Embeddings
    # SDK-side image download for the bytes-fetch embedding path (v5.5).
    #
    # Where the URL-forwarding path (v5.1) hands a validated URL to the
    # embedding provider and lets the provider issue its own fetch, the
    # bytes path downloads the image through the SDK's own SSRF-hardened
    # primitive ({Parse::File.safe_open_url} — CIDR blocks, port
    # allowlist, DNS-rebinding re-check, size caps, timeouts; NO parallel
    # SSRF mechanism is introduced here), verifies the content, and
    # forwards the bytes to the provider as a base64 data URI.
    #
    # == Content verification (closes NEW-NET-4, "File MIME laundering")
    #
    # The HTTP `Content-Type` header is **never trusted**. The MIME type
    # is determined exclusively by magic-byte sniffing of the leading
    # bytes ({.sniff_mime}), then:
    #
    # 1. The sniffed type must be in {Parse::Embeddings.allowed_image_types}
    #    (default: JPEG / PNG / GIF / WebP).
    # 2. When the URL path carries a recognized image extension, the
    #    extension's implied type must AGREE with the sniffed type —
    #    a `.png` URL serving JPEG bytes (or an `.html` payload with an
    #    image extension) is refused as a laundering attempt.
    #
    # Unknown magic bytes are always refused: there is no fallthrough to
    # header- or extension-derived typing.
    #
    # == EXIF stripping (default ON)
    #
    # User-uploaded photos commonly carry GPS coordinates and device
    # serial numbers in EXIF. Forwarding those to a third-party embedding
    # provider is a PII egress, so metadata is stripped by default:
    #
    # * JPEG — APP1 segments (Exif and XMP) are removed.
    # * PNG  — `eXIf` chunks are removed.
    # * WebP — `EXIF` / `XMP ` RIFF chunks are removed and the VP8X
    #   EXIF/XMP flag bits cleared.
    # * GIF  — no EXIF container; pass-through.
    #
    # Callers that need orientation metadata preserved opt out per call
    # with `exif_strip: false` (the `embed_image source: :bytes`
    # directive forwards its own `exif_strip:` declaration).
    module ImageFetch
      # Raised when downloaded bytes fail content verification — unknown
      # magic bytes, sniffed type outside the allowlist, or an
      # extension / magic-byte disagreement. Carries a `:reason` tag
      # (`:unknown_magic`, `:type_not_allowed`, `:extension_mismatch`,
      # `:empty`) so callers can branch on the failure mode.
      class InvalidImageType < Parse::Embeddings::Error
        # @return [Symbol] failure-mode tag.
        attr_reader :reason
        def initialize(reason, message)
          @reason = reason
          super(message)
        end
      end

      # Value object for a fetched-and-verified image. `mime_type` is the
      # SNIFFED type (never the server-reported `Content-Type`). The
      # provider adapters consume this via {#to_data_uri}.
      FetchedImage = Struct.new(:bytes, :mime_type, :url, keyword_init: true) do
        # @return [String] `data:<mime>;base64,<payload>` for provider wire bodies.
        def to_data_uri
          "data:#{mime_type};base64,#{Base64.strict_encode64(bytes)}"
        end

        # Keep multi-MB image payloads out of exception messages and logs.
        def inspect
          "#<Parse::Embeddings::ImageFetch::FetchedImage mime_type=#{mime_type.inspect} " \
          "bytes=#{bytes.respond_to?(:bytesize) ? bytes.bytesize : 0} url=#{url.inspect}>"
        end
        alias_method :to_s, :inspect
      end

      # MIME types the bytes path accepts by default. Operators extend
      # via {Parse::Embeddings.allowed_image_types=}. SVG is deliberately
      # absent — it is active content (script-capable), not a bitmap.
      DEFAULT_ALLOWED_IMAGE_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze

      # URL-path extensions whose implied MIME type is cross-checked
      # against the sniffed type. Extensions not listed here are ignored
      # (the magic bytes alone govern).
      EXTENSION_MIME = {
        ".jpg"  => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".jpe"  => "image/jpeg",
        ".png"  => "image/png",
        ".gif"  => "image/gif",
        ".webp" => "image/webp",
      }.freeze

      module_function

      # Determine an image's MIME type from its leading magic bytes.
      # The first ~16 bytes are sufficient for every supported format.
      # Returns nil for anything unrecognized — callers must treat nil
      # as a refusal, never fall back to header/extension typing.
      #
      # @param bytes [String] raw image bytes (at least the first 16).
      # @return [String, nil] sniffed MIME type, or nil when unknown.
      def sniff_mime(bytes)
        return nil unless bytes.is_a?(String) && bytes.bytesize >= 12
        b = bytes.byteslice(0, 16).force_encoding(Encoding::BINARY)
        return "image/jpeg" if b.start_with?("\xFF\xD8\xFF".b)
        return "image/png"  if b.start_with?("\x89PNG\r\n\x1A\n".b)
        return "image/gif"  if b.start_with?("GIF87a".b) || b.start_with?("GIF89a".b)
        if b.start_with?("RIFF".b) && b.byteslice(8, 4) == "WEBP".b
          return "image/webp"
        end
        nil
      end

      # Download, verify, and (by default) EXIF-strip an image.
      #
      # The URL is validated through
      # {Parse::Embeddings.validate_image_url!} in `:fetch` mode — host
      # allowlist ({Parse::Embeddings.allowed_image_hosts}, deny-all when
      # empty), obfuscated-IP-literal screen, port allowlist, CIDR check
      # — but WITHOUT the {Parse::Embeddings.trust_provider_url_fetch=}
      # sentinel, because no URL is forwarded to a third party: the SDK
      # itself performs the fetch through {Parse::File.safe_open_url}.
      #
      # @param url [String] image URL (host must be allowlisted).
      # @param allow_insecure [Boolean] permit `http://` (local dev only).
      # @param exif_strip [Boolean] strip EXIF/XMP metadata (default true).
      # @param max_bytes [Integer, nil] additional size cap below
      #   {Parse::File.max_remote_size}; nil applies only the global cap.
      # @return [FetchedImage] verified bytes + sniffed MIME type.
      # @raise [Parse::Embeddings::InvalidImageURL] URL validation failure.
      # @raise [InvalidImageType] content verification failure.
      # @raise [ArgumentError] from {Parse::File.safe_open_url} (SSRF /
      #   size / timeout refusals).
      def fetch!(url, allow_insecure: false, exif_strip: true, max_bytes: nil)
        canonical = Parse::Embeddings.validate_image_url!(
          url, allow_insecure: allow_insecure, mode: :fetch,
        )
        # Push `max_bytes` INTO the fetch so the download aborts mid-stream
        # once the cap is exceeded, rather than buffering the whole
        # (globally-capped) body first and rejecting after. The post-read
        # check below is retained as belt-and-suspenders for transports
        # that can't enforce the streaming cap.
        io = Parse::File.safe_open_url(canonical, max_bytes: max_bytes)
        begin
          bytes = io.read
        ensure
          io.close if io.respond_to?(:close)
        end
        bytes = bytes.to_s.dup.force_encoding(Encoding::BINARY)

        if max_bytes && bytes.bytesize > Integer(max_bytes)
          raise ArgumentError,
                "Parse::Embeddings::ImageFetch: image exceeds max_bytes " \
                "(#{bytes.bytesize} > #{Integer(max_bytes)})."
        end

        mime = verify!(bytes, url: canonical)
        bytes = strip_metadata(bytes, mime) if exif_strip
        FetchedImage.new(bytes: bytes, mime_type: mime, url: canonical)
      end

      # Verify raw bytes: sniff the magic, check the allowlist, and
      # cross-check the URL extension. Public so the upload-side
      # validation path can reuse the same check.
      #
      # @param bytes [String] raw image bytes.
      # @param url [String, nil] source URL for the extension cross-check
      #   (nil skips it — e.g. caller-supplied byte payloads).
      # @return [String] the sniffed MIME type.
      # @raise [InvalidImageType]
      def verify!(bytes, url: nil)
        if bytes.nil? || bytes.empty?
          raise InvalidImageType.new(:empty,
            "Parse::Embeddings::ImageFetch: downloaded body is empty.")
        end
        mime = sniff_mime(bytes)
        if mime.nil?
          raise InvalidImageType.new(:unknown_magic,
            "Parse::Embeddings::ImageFetch: leading bytes match no supported image " \
            "format (JPEG/PNG/GIF/WebP). The Content-Type header is not consulted — " \
            "unrecognized content is refused outright.")
        end
        allowed = Parse::Embeddings.allowed_image_types
        unless allowed.include?(mime)
          raise InvalidImageType.new(:type_not_allowed,
            "Parse::Embeddings::ImageFetch: sniffed type #{mime.inspect} is not in " \
            "Parse::Embeddings.allowed_image_types (#{allowed.inspect}).")
        end
        ext_mime = extension_mime(url)
        if ext_mime && ext_mime != mime
          raise InvalidImageType.new(:extension_mismatch,
            "Parse::Embeddings::ImageFetch: URL extension implies #{ext_mime.inspect} " \
            "but the magic bytes are #{mime.inspect} — refusing MIME-laundered content.")
        end
        mime
      end

      # @!visibility private
      # MIME type implied by the URL path's extension, or nil when the
      # extension is absent / unrecognized. Only the URI *path* is
      # consulted — a dot in the hostname (`https://cdn.v2.example.com/blob`)
      # must not be mistaken for an extension. Unparseable URLs skip the
      # cross-check (magic-byte verification still applies).
      def extension_mime(url)
        return nil unless url.is_a?(String)
        path = begin
          URI.parse(url).path.to_s
        rescue URI::InvalidURIError
          return nil
        end
        dot = path.rindex(".")
        return nil if dot.nil?
        EXTENSION_MIME[path[dot..].to_s.downcase]
      end

      # Strip embedded metadata for the formats that carry it. Unknown /
      # metadata-free formats pass through unchanged. Never raises on a
      # malformed container — falls back to the original bytes (the
      # provider will reject genuinely corrupt input) — but the fallback
      # is no longer silent: a container the walker could not parse may
      # still carry EXIF/XMP to a third-party provider, so the
      # PII-egress protection not running is warned about.
      #
      # @param bytes [String] verified image bytes.
      # @param mime [String] sniffed MIME type.
      # @return [String] bytes with metadata removed.
      def strip_metadata(bytes, mime)
        stripped =
          case mime
          when "image/jpeg" then strip_jpeg_app1(bytes)
          when "image/png"  then strip_png_exif(bytes)
          when "image/webp" then strip_webp_metadata(bytes)
          else return bytes
          end
        # The format walkers return the *original object* when they bail
        # on a structure they cannot parse; a successful walk always
        # returns a fresh copy (even when nothing was removed).
        if stripped.equal?(bytes)
          warn "[Parse::Embeddings::ImageFetch] could not parse the #{mime} " \
               "container for metadata stripping; passing bytes through with " \
               "embedded EXIF/XMP (if any) intact."
        end
        stripped
      rescue StandardError
        warn "[Parse::Embeddings::ImageFetch] metadata stripping raised while " \
             "parsing the #{mime} container; passing bytes through with " \
             "embedded EXIF/XMP (if any) intact."
        bytes
      end

      # @!visibility private
      # Remove APP1 (0xFFE1) segments — Exif and XMP both ride in APP1 —
      # by walking the JPEG marker stream up to SOS and copying every
      # other segment verbatim. Entropy-coded data after SOS is appended
      # untouched.
      def strip_jpeg_app1(bytes)
        b = bytes
        return b unless b.byteslice(0, 2) == "\xFF\xD8".b
        out = +"\xFF\xD8".b
        pos = 2
        len = b.bytesize
        while pos + 4 <= len
          return bytes unless b.getbyte(pos) == 0xFF
          marker = b.getbyte(pos + 1)
          # Standalone markers (RST/SOI/EOI/TEM) carry no length, but none
          # legally appear between SOI and SOS in the header stream.
          break if marker == 0xD9 # EOI with no SOS — malformed; bail to copy
          seg_len = (b.getbyte(pos + 2) << 8) | b.getbyte(pos + 3)
          return bytes if seg_len < 2
          if marker == 0xDA # SOS — header walk ends; copy the rest verbatim
            out << b.byteslice(pos, len - pos)
            return out
          end
          out << b.byteslice(pos, 2 + seg_len) unless marker == 0xE1
          pos += 2 + seg_len
        end
        # No SOS found — structurally odd; return the original untouched.
        bytes
      end

      # @!visibility private
      # Remove `eXIf` chunks from a PNG chunk stream. Chunk layout:
      # 4-byte length, 4-byte type, payload, 4-byte CRC. A truncated
      # chunk bails to the original `bytes` object — an `eXIf` chunk
      # past the abort point would otherwise slip through, and the
      # identity check in strip_metadata only warns on the original.
      def strip_png_exif(bytes)
        sig_len = 8
        b = bytes
        out = b.byteslice(0, sig_len).dup
        pos = sig_len
        len = b.bytesize
        while pos + 8 <= len
          chunk_len = (b.getbyte(pos) << 24) | (b.getbyte(pos + 1) << 16) |
                      (b.getbyte(pos + 2) << 8) | b.getbyte(pos + 3)
          type = b.byteslice(pos + 4, 4)
          total = 8 + chunk_len + 4
          return bytes if pos + total > len
          out << b.byteslice(pos, total) unless type == "eXIf".b
          pos += total
          break if type == "IEND".b
        end
        # Trailing bytes after IEND (uncommon) are dropped with the copy;
        # a sub-header tail (< 8 bytes) cannot hold another chunk.
        out
      end

      # @!visibility private
      # Remove `EXIF` / `XMP ` chunks from a WebP RIFF container, patch
      # the RIFF size field, and clear the VP8X EXIF/XMP flag bits so the
      # header stays consistent with the chunk list. A truncated chunk
      # bails to the original `bytes` object — an `EXIF` / `XMP ` chunk
      # past the abort point would otherwise slip through, and the
      # identity check in strip_metadata only warns on the original.
      def strip_webp_metadata(bytes)
        b = bytes
        out_chunks = +"".b
        pos = 12 # past "RIFF" + size + "WEBP"
        len = b.bytesize
        while pos + 8 <= len
          type = b.byteslice(pos, 4)
          chunk_len = b.getbyte(pos + 4) | (b.getbyte(pos + 5) << 8) |
                      (b.getbyte(pos + 6) << 16) | (b.getbyte(pos + 7) << 24)
          padded = chunk_len + (chunk_len.odd? ? 1 : 0)
          total = 8 + padded
          return bytes if pos + 8 + chunk_len > len
          unless type == "EXIF".b || type == "XMP ".b
            chunk = b.byteslice(pos, [total, len - pos].min).dup
            if type == "VP8X".b && chunk.bytesize >= 9
              flags = chunk.getbyte(8)
              chunk.setbyte(8, flags & ~0x0C) # clear EXIF (0x08) + XMP (0x04)
            end
            out_chunks << chunk
          end
          pos += total
        end
        riff_size = 4 + out_chunks.bytesize # "WEBP" + chunks
        out = +"RIFF".b
        out << [riff_size].pack("V")
        out << "WEBP".b
        out << out_chunks
        out
      end
    end
  end
end
