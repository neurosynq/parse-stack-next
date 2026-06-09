# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"
require "parse/model/file"
require "stringio"

# Unit tests for Parse::Embeddings::ImageFetch — the v5.5 bytes-fetch
# path: magic-byte MIME sniffing (NEW-NET-4 closure: the Content-Type
# header is never consulted), extension cross-check, type allowlist,
# EXIF/XMP stripping, and the fetch! pipeline over a stubbed
# Parse::File.safe_open_url.
class EmbeddingsImageFetchTest < Minitest::Test
  IF = Parse::Embeddings::ImageFetch

  def teardown
    Parse::Embeddings.reset!
  end

  # ---------- fixture builders ----------

  def jpeg_with_exif
    app0 = "\xFF\xE0".b + [16].pack("n") + "JFIF\x00".b + ("\x00".b * 9)
    exif_payload = "Exif\x00\x00".b + ("E".b * 10)
    app1 = "\xFF\xE1".b + [2 + exif_payload.bytesize].pack("n") + exif_payload
    sos = "\xFF\xDA".b + [4].pack("n") + "\x01\x02".b
    entropy = "\x12\x34\x56".b + "\xFF\xD9".b
    "\xFF\xD8".b + app0 + app1 + sos + entropy
  end

  def png_chunk(type, payload)
    [payload.bytesize].pack("N") + type.b + payload.b + "\x00\x00\x00\x00".b
  end

  def png_with_exif
    sig = "\x89PNG\r\n\x1A\n".b
    sig + png_chunk("IHDR", "\x00" * 13) +
      png_chunk("eXIf", "EXIFDATA") +
      png_chunk("IDAT", "\x01\x02\x03") +
      png_chunk("IEND", "")
  end

  def webp_chunk(type, payload)
    chunk = type.b + [payload.bytesize].pack("V") + payload.b
    chunk += "\x00".b if payload.bytesize.odd?
    chunk
  end

  def webp_with_metadata
    vp8x_payload = (0x0C).chr + ("\x00" * 9) # EXIF + XMP flags set
    chunks = webp_chunk("VP8X", vp8x_payload) +
             webp_chunk("VP8 ", "\x01\x02\x03\x04") +
             webp_chunk("EXIF", "EXIFDATA") +
             webp_chunk("XMP ", "<xmp/>")
    "RIFF".b + [4 + chunks.bytesize].pack("V") + "WEBP".b + chunks
  end

  def plain_gif
    "GIF89a".b + ("\x00" * 20)
  end

  # ---------- sniff_mime ----------

  def test_sniffs_jpeg
    assert_equal "image/jpeg", IF.sniff_mime(jpeg_with_exif)
  end

  def test_sniffs_png
    assert_equal "image/png", IF.sniff_mime(png_with_exif)
  end

  def test_sniffs_gif
    assert_equal "image/gif", IF.sniff_mime(plain_gif)
    assert_equal "image/gif", IF.sniff_mime("GIF87a".b + ("\x00" * 10))
  end

  def test_sniffs_webp
    assert_equal "image/webp", IF.sniff_mime(webp_with_metadata)
  end

  def test_sniff_unknown_returns_nil
    assert_nil IF.sniff_mime("<html><body>hi</body></html>")
    assert_nil IF.sniff_mime("%PDF-1.7 ........")
    assert_nil IF.sniff_mime(nil)
    assert_nil IF.sniff_mime("short")
  end

  def test_sniff_riff_but_not_webp_returns_nil
    wav = "RIFF".b + [100].pack("V") + "WAVE".b + ("\x00" * 8)
    assert_nil IF.sniff_mime(wav)
  end

  # ---------- verify! ----------

  def test_verify_returns_sniffed_mime
    assert_equal "image/jpeg", IF.verify!(jpeg_with_exif, url: "https://cdn.example.com/a.jpg")
  end

  def test_verify_refuses_empty
    err = assert_raises(IF::InvalidImageType) { IF.verify!("".b) }
    assert_equal :empty, err.reason
  end

  def test_verify_refuses_unknown_magic
    err = assert_raises(IF::InvalidImageType) { IF.verify!("<html>not an image</html>") }
    assert_equal :unknown_magic, err.reason
  end

  def test_verify_refuses_extension_mismatch
    # PNG bytes served from a .jpg URL — the MIME-laundering shape.
    err = assert_raises(IF::InvalidImageType) do
      IF.verify!(png_with_exif, url: "https://1.1.1.1/photo.jpg")
    end
    assert_equal :extension_mismatch, err.reason
  end

  def test_verify_ignores_unrecognized_extension
    assert_equal "image/png", IF.verify!(png_with_exif, url: "https://cdn.example.com/blob.bin")
    assert_equal "image/png", IF.verify!(png_with_exif, url: "https://cdn.example.com/noext")
  end

  def test_verify_extension_check_ignores_hostname_dots
    # A dot in the hostname must not be read as a file extension — JPEG
    # bytes from a host whose last label spells ".png" are fine when the
    # path itself carries no extension.
    assert_equal "image/jpeg", IF.verify!(jpeg_with_exif, url: "https://evil.png/blob")
    assert_equal "image/jpeg", IF.verify!(jpeg_with_exif, url: "https://cdn.v2.example.com/blob")
    # Path-less URL: the pre-URI split-based check read ".png" out of the
    # hostname here and raised a false :extension_mismatch.
    assert_equal "image/jpeg", IF.verify!(jpeg_with_exif, url: "https://evil.png")
    # ...while a real path extension on such a host still cross-checks.
    err = assert_raises(IF::InvalidImageType) do
      IF.verify!(jpeg_with_exif, url: "https://evil.png/photo.png")
    end
    assert_equal :extension_mismatch, err.reason
  end

  def test_verify_extension_check_ignores_query_string
    err = assert_raises(IF::InvalidImageType) do
      IF.verify!(png_with_exif, url: "https://1.1.1.1/photo.jpg?w=100&h=100")
    end
    assert_equal :extension_mismatch, err.reason
  end

  def test_verify_enforces_type_allowlist
    Parse::Embeddings.allowed_image_types = ["image/png"]
    err = assert_raises(IF::InvalidImageType) do
      IF.verify!(jpeg_with_exif, url: "https://cdn.example.com/a.jpg")
    end
    assert_equal :type_not_allowed, err.reason
  end

  def test_allowed_image_types_rejects_bad_config
    assert_raises(ArgumentError) { Parse::Embeddings.allowed_image_types = [] }
    assert_raises(ArgumentError) { Parse::Embeddings.allowed_image_types = "image/png" }
    assert_raises(ArgumentError) { Parse::Embeddings.allowed_image_types = ["notamime"] }
  end

  # ---------- EXIF stripping ----------

  def test_strip_jpeg_removes_app1_keeps_app0_and_image_data
    original = jpeg_with_exif
    stripped = IF.strip_metadata(original, "image/jpeg")
    refute_includes stripped, "Exif\x00\x00".b
    assert_includes stripped, "JFIF\x00".b
    assert stripped.start_with?("\xFF\xD8".b)
    assert stripped.end_with?("\xFF\xD9".b)
    assert_operator stripped.bytesize, :<, original.bytesize
    # Stripping is idempotent and the result still sniffs as JPEG.
    assert_equal "image/jpeg", IF.sniff_mime(stripped)
    assert_equal stripped, IF.strip_metadata(stripped, "image/jpeg")
  end

  def test_strip_png_removes_exif_chunk_keeps_idat
    original = png_with_exif
    stripped = IF.strip_metadata(original, "image/png")
    refute_includes stripped, "eXIf".b
    assert_includes stripped, "IDAT".b
    assert_includes stripped, "IEND".b
    assert_equal "image/png", IF.sniff_mime(stripped)
  end

  def test_strip_webp_removes_exif_xmp_and_clears_vp8x_flags
    original = webp_with_metadata
    stripped = IF.strip_metadata(original, "image/webp")
    refute_includes stripped, "EXIFDATA".b
    refute_includes stripped, "<xmp/>".b
    assert_includes stripped, "VP8 ".b
    assert_equal "image/webp", IF.sniff_mime(stripped)
    # VP8X flag byte: EXIF (0x08) and XMP (0x04) cleared.
    vp8x_at = stripped.index("VP8X".b)
    refute_nil vp8x_at
    flags = stripped.getbyte(vp8x_at + 8)
    assert_equal 0, flags & 0x0C
    # RIFF size field patched to match the shrunken payload.
    riff_size = stripped.byteslice(4, 4).unpack1("V")
    assert_equal stripped.bytesize - 8, riff_size
  end

  def test_strip_gif_is_passthrough
    assert_equal plain_gif, IF.strip_metadata(plain_gif, "image/gif")
  end

  def test_strip_malformed_jpeg_returns_original_with_warning
    junk = "\xFF\xD8".b + "garbage that is not a marker stream".b
    result = nil
    # The fallback is fail-open by design, but no longer silent: bytes
    # the walker couldn't parse may carry EXIF/XMP to the provider.
    assert_output(nil, /could not parse the image\/jpeg container/) do
      result = IF.strip_metadata(junk, "image/jpeg")
    end
    assert_equal junk, result
  end

  def test_strip_truncated_png_returns_original_with_warning
    # A chunk whose declared length runs past the end of the buffer stops
    # the walk. The walker must bail to the ORIGINAL bytes (not a partial
    # rebuild) so the pass-through warning fires — an eXIf chunk past the
    # abort point would otherwise be forwarded silently.
    sig = "\x89PNG\r\n\x1A\n".b
    truncated = sig + png_chunk("IHDR", "\x00" * 13) +
                [9999].pack("N") + "IDAT".b + "short".b +
                png_chunk("eXIf", "EXIFDATA")
    result = nil
    assert_output(nil, /could not parse the image\/png container/) do
      result = IF.strip_metadata(truncated, "image/png")
    end
    assert_equal truncated, result
  end

  def test_strip_truncated_webp_returns_original_with_warning
    chunks = webp_chunk("VP8 ", "\x01\x02\x03\x04") +
             "ALPH".b + [9999].pack("V") + "short".b +
             webp_chunk("EXIF", "EXIFDATA")
    truncated = "RIFF".b + [4 + chunks.bytesize].pack("V") + "WEBP".b + chunks
    result = nil
    assert_output(nil, /could not parse the image\/webp container/) do
      result = IF.strip_metadata(truncated, "image/webp")
    end
    assert_equal truncated, result
  end

  def test_strip_clean_parse_does_not_warn
    assert_output(nil, "") { IF.strip_metadata(jpeg_with_exif, "image/jpeg") }
    assert_output(nil, "") { IF.strip_metadata(plain_gif, "image/gif") }
  end

  # ---------- fetch! pipeline ----------

  def with_stubbed_download(bytes)
    Parse::File.stub(:safe_open_url, ->(_url) { StringIO.new(bytes) }) do
      yield
    end
  end

  def test_fetch_closes_io_when_read_raises
    Parse::Embeddings.allowed_image_hosts = ["1.1.1.1"]
    io = Class.new(StringIO) do
      def read(*)
        raise IOError, "connection reset mid-body"
      end
    end.new("".b)
    Parse::File.stub(:safe_open_url, ->(_url) { io }) do
      assert_raises(IOError) { IF.fetch!("https://1.1.1.1/a.jpg") }
    end
    assert io.closed?, "the download handle must be closed even when read raises"
  end

  def test_fetch_requires_host_allowlist_but_not_sentinel
    # No trust_provider_url_fetch sentinel set — :fetch mode must work
    # on allowlist alone (the SDK fetches; no provider egress).
    Parse::Embeddings.allowed_image_hosts = ["1.1.1.1"]
    with_stubbed_download(jpeg_with_exif) do
      img = IF.fetch!("https://1.1.1.1/photo.jpg")
      assert_instance_of IF::FetchedImage, img
      assert_equal "image/jpeg", img.mime_type
      refute_includes img.bytes, "Exif\x00\x00".b
    end
  end

  def test_fetch_denies_host_not_in_allowlist
    Parse::Embeddings.allowed_image_hosts = ["1.1.1.1"]
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      IF.fetch!("https://evil.example.net/photo.jpg")
    end
    assert_equal :host_not_allowlisted, err.reason
  end

  def test_fetch_denies_everything_with_empty_allowlist
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      IF.fetch!("https://1.1.1.1/photo.jpg")
    end
    assert_equal :host_not_allowlisted, err.reason
  end

  def test_forward_mode_still_requires_sentinel
    Parse::Embeddings.allowed_image_hosts = ["1.1.1.1"]
    assert_raises(Parse::Embeddings::ConfirmationRequired) do
      Parse::Embeddings.validate_image_url!("https://1.1.1.1/photo.jpg")
    end
  end

  def test_fetch_refuses_laundered_content
    Parse::Embeddings.allowed_image_hosts = ["1.1.1.1"]
    with_stubbed_download("<html>fake image</html>") do
      err = assert_raises(IF::InvalidImageType) do
        IF.fetch!("https://1.1.1.1/photo.jpg")
      end
      assert_equal :unknown_magic, err.reason
    end
  end

  def test_fetch_exif_strip_opt_out
    Parse::Embeddings.allowed_image_hosts = ["1.1.1.1"]
    with_stubbed_download(jpeg_with_exif) do
      img = IF.fetch!("https://1.1.1.1/photo.jpg", exif_strip: false)
      assert_includes img.bytes, "Exif\x00\x00".b
    end
  end

  def test_fetch_enforces_max_bytes
    Parse::Embeddings.allowed_image_hosts = ["1.1.1.1"]
    with_stubbed_download(jpeg_with_exif) do
      assert_raises(ArgumentError) do
        IF.fetch!("https://1.1.1.1/photo.jpg", max_bytes: 4)
      end
    end
  end

  # ---------- FetchedImage ----------

  def test_fetched_image_data_uri_and_safe_inspect
    img = IF::FetchedImage.new(bytes: "\x01\x02".b, mime_type: "image/png",
                               url: "https://cdn.example.com/x.png")
    assert_equal "data:image/png;base64,#{Base64.strict_encode64("\x01\x02".b)}", img.to_data_uri
    refute_includes img.inspect, Base64.strict_encode64("\x01\x02".b)
    assert_includes img.inspect, "image/png"
  end
end
