# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for `Parse::File#key=` cap at 1024 bytes (S3 hard limit)
# and for the JSON serialization round-trip through `as_json` /
# `attributes=` / `Hash#parse_file?`.
#
# The cap closes a memory-amplification vector: a malformed row or a
# buggy adapter that writes a multi-MB string into `@key` would land
# in every `inspect` call, ship to Sentry / log aggregators, and
# amplify into operator pain. The S3 protocol caps object keys at 1024
# bytes, so anything past that is by definition pathological.
#
# The round-trip tests cover the SDK-side serialization path. The
# question of whether Parse Server itself preserves unknown fields on
# the file-pointer wire format is deferred to a docker-backed
# integration test.
class TestFileKeyValidation < Minitest::Test
  def setup
    @original_trusted_hosts = Parse::File.instance_variable_get(:@trusted_url_hosts)
    @original_policy        = Parse::File.instance_variable_get(:@untrusted_url_policy)
    @original_warned        = Parse::File.instance_variable_get(:@warned_untrusted_hosts)
    Parse::File.trusted_url_hosts = ["bucket.s3.amazonaws.com", "files.parsetfss.com"]
    Parse::File.untrusted_url_policy = :raise
  end

  def teardown
    Parse::File.instance_variable_set(:@trusted_url_hosts, @original_trusted_hosts)
    Parse::File.instance_variable_set(:@untrusted_url_policy, @original_policy)
    Parse::File.instance_variable_set(:@warned_untrusted_hosts, @original_warned)
  end

  # ------------------------------------------------------------------
  # key= length cap
  # ------------------------------------------------------------------

  def test_key_setter_accepts_short_key
    file = Parse::File.new("doc.pdf")
    file.key = "tenants/abc/uuid-doc.pdf"
    assert_equal "tenants/abc/uuid-doc.pdf", file.key
  end

  def test_key_setter_accepts_exact_max_length
    file = Parse::File.new("doc.pdf")
    at_limit = "a" * Parse::File::MAX_KEY_BYTESIZE
    file.key = at_limit
    assert_equal at_limit, file.key
  end

  def test_key_setter_refuses_over_limit
    file = Parse::File.new("doc.pdf")
    over_limit = "a" * (Parse::File::MAX_KEY_BYTESIZE + 1)
    err = assert_raises(Parse::File::InvalidKeyError) do
      file.key = over_limit
    end
    assert_match(/exceeds.*1024 bytes/i, err.message)
  end

  def test_key_setter_counts_bytes_not_characters
    # A multibyte UTF-8 character (3 bytes) at the boundary.
    # 341 × 3 = 1023 bytes — under the cap. 342 × 3 = 1026 — over.
    file = Parse::File.new("doc.pdf")
    file.key = "あ" * 341  # under
    assert_equal 1023, file.key.bytesize
    assert_raises(Parse::File::InvalidKeyError) do
      file.key = "あ" * 342  # over
    end
  end

  def test_key_setter_accepts_nil_for_clearing
    file = Parse::File.new("doc.pdf")
    file.key = "tenants/abc/uuid-doc.pdf"
    file.key = nil
    assert_nil file.key
  end

  def test_attributes_hydration_enforces_key_cap
    # Hostile-row defense: a Parse Server response carrying a 2KB key
    # field must raise on hydration rather than silently store
    # a memory-amplification payload that surfaces through inspect.
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    bad = "a" * (Parse::File::MAX_KEY_BYTESIZE + 1)
    assert_raises(Parse::File::InvalidKeyError) do
      file.attributes = {
        "name" => "doc.pdf",
        "url"  => "https://bucket.s3.amazonaws.com/doc.pdf",
        "key"  => bad,
      }
    end
  end

  # ------------------------------------------------------------------
  # as_json round-trip
  # ------------------------------------------------------------------

  def test_as_json_omits_key_for_legacy_parse_hosted_file
    file = Parse::File.new(name: "img.png", contents: nil)
    file.attributes = {
      "name" => "img.png",
      "url"  => "https://files.parsetfss.com/abc/img.png",
    }
    h = file.as_json
    refute h.key?("key"),
           "as_json must NOT include `key` for legacy files; emitting " \
           "`key: nil` would break wire compatibility with the " \
           "{__type, name, url} 3-key Parse Server file-pointer format."
  end

  def test_as_json_includes_key_when_set
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    file.attributes = {
      "name" => "doc.pdf",
      "url"  => "https://bucket.s3.amazonaws.com/tenants/abc/uuid-doc.pdf",
      "key"  => "tenants/abc/uuid-doc.pdf",
    }
    h = file.as_json
    assert_equal "tenants/abc/uuid-doc.pdf", h["key"]
    assert_equal "doc.pdf", h["name"]
    assert_equal "https://bucket.s3.amazonaws.com/tenants/abc/uuid-doc.pdf", h["url"]
    assert_equal Parse::Model::TYPE_FILE, h["__type"]
  end

  def test_as_json_round_trip_preserves_key
    # Build a file, serialize, deserialize into a fresh instance,
    # confirm @key is preserved through the SDK serialization
    # boundary. (Whether Parse Server itself preserves it is a
    # separate docker-backed integration test.)
    original = Parse::File.new(name: "doc.pdf", contents: nil)
    original.attributes = {
      "name" => "doc.pdf",
      "url"  => "https://bucket.s3.amazonaws.com/tenants/abc/uuid-doc.pdf",
      "key"  => "tenants/abc/uuid-doc.pdf",
    }

    wire = original.as_json
    reloaded = Parse::File.new(name: "x", contents: nil)
    reloaded.attributes = wire

    assert_equal original.name, reloaded.name
    assert_equal original.url,  reloaded.url
    assert_equal original.key,  reloaded.key
    assert reloaded.saved?, "round-tripped file must be saved?"
  end

  # ------------------------------------------------------------------
  # Hash#parse_file? recognizes adapter-stored files
  # ------------------------------------------------------------------

  def test_parse_file_predicate_recognizes_canonical_two_key_hash
    h = { "name" => "img.png", "url" => "https://files.parsetfss.com/abc/img.png" }
    assert h.parse_file?
  end

  def test_parse_file_predicate_rejects_canonical_with_basename_mismatch
    # Without __type marker and without `key`, basename equality is
    # still required.
    h = { "name" => "img.png", "url" => "https://files.parsetfss.com/abc/different.png" }
    refute h.parse_file?
  end

  def test_parse_file_predicate_recognizes_adapter_stored_three_key_hash
    # No __type marker, but `key` is present — count == 3 path.
    h = {
      "name" => "doc.pdf",
      "url"  => "https://bucket.s3.amazonaws.com/tenants/abc/uuid-doc.pdf",
      "key"  => "tenants/abc/uuid-doc.pdf",
    }
    assert h.parse_file?,
           "parse_file? must recognize {name, url, key} hash even when " \
           "basename(url) diverges from name"
  end

  def test_parse_file_predicate_recognizes_typed_adapter_stored_hash
    h = {
      "__type" => "File",
      "name"   => "doc.pdf",
      "url"    => "https://bucket.s3.amazonaws.com/tenants/abc/uuid-doc.pdf",
      "key"    => "tenants/abc/uuid-doc.pdf",
    }
    assert h.parse_file?
  end

  def test_parse_file_predicate_recognizes_typed_canonical_hash
    h = {
      "__type" => "File",
      "name"   => "img.png",
      "url"    => "https://files.parsetfss.com/abc/img.png",
    }
    assert h.parse_file?
  end

  def test_parse_file_predicate_rejects_typed_canonical_with_basename_mismatch
    # __type: File without `key` — still enforce basename equality so a
    # tampered `name` field is rejected.
    h = {
      "__type" => "File",
      "name"   => "img.png",
      "url"    => "https://files.parsetfss.com/abc/tampered.png",
    }
    refute h.parse_file?
  end

  def test_parse_file_predicate_rejects_unrelated_three_key_hashes
    # A random three-key hash that happens to have name/url shouldn't
    # be misidentified.
    h = {
      "name" => "foo",
      "url"  => "https://example.com/x",
      "extra" => "bar",
    }
    refute h.parse_file?
  end
end
