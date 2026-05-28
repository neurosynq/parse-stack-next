# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the Parse Server file-pointer wire format —
# `Parse::File#as_json` emits exactly `{__type, name, url}` (the shape
# Parse Server normalizes to on save), and `Hash#parse_file?`
# recognizes both the bare `{name, url}` and the typed
# `{__type: "File", name, url}` shapes while stripping presigned-URL
# query strings before the basename equality check.
#
# Background: Parse Server's REST endpoint normalizes embedded
# file-pointer hashes on save and strips any sub-fields beyond
# `__type`, `name`, and `url`. The Wave C docker integration test
# confirmed this. Any attempt to ride additional fields (e.g. a
# bucket-relative storage key) inside the file-pointer hash gets
# silently dropped. The SDK does not attempt to work around that —
# the wire format IS the contract.
class TestFileWireFormat < Minitest::Test
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
  # as_json wire format invariant
  # ------------------------------------------------------------------

  def test_as_json_emits_canonical_three_key_wire_shape
    # The Parse Server file-pointer wire format is exactly
    # {__type, name, url}; deviating breaks every Parse Server install
    # and every downstream consumer that assumes the shape.
    file = Parse::File.new(name: "img.png", contents: nil)
    file.url = "https://files.parsetfss.com/abc/img.png"

    h = file.as_json
    assert_equal %w[__type name url], h.keys.sort,
                 "as_json must emit exactly __type, name, url"
    assert_equal Parse::Model::TYPE_FILE, h["__type"]
    assert_equal "img.png", h["name"]
    assert_equal "https://files.parsetfss.com/abc/img.png", h["url"]
  end

  # ------------------------------------------------------------------
  # Hash#parse_file? — canonical wire shape recognition
  # ------------------------------------------------------------------

  def test_parse_file_predicate_recognizes_canonical_two_key_hash
    h = { "name" => "img.png", "url" => "https://files.parsetfss.com/abc/img.png" }
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

  def test_parse_file_predicate_strips_query_string_before_basename_check
    # Parse Server's S3FilesAdapter returns presigned URLs on every
    # read; the basename check must ignore the query string so a
    # presigned URL doesn't break parse_file? recognition.
    h = {
      "__type" => "File",
      "name"   => "img.png",
      "url"    => "https://bucket.s3.amazonaws.com/img.png?X-Amz-Signature=abc",
    }
    assert h.parse_file?, "parse_file? must handle presigned URL query strings"
  end

  def test_parse_file_predicate_rejects_canonical_with_basename_mismatch
    h = { "name" => "img.png", "url" => "https://files.parsetfss.com/abc/different.png" }
    refute h.parse_file?
  end

  def test_parse_file_predicate_rejects_typed_canonical_with_basename_mismatch
    h = {
      "__type" => "File",
      "name"   => "img.png",
      "url"    => "https://files.parsetfss.com/abc/tampered.png",
    }
    refute h.parse_file?
  end

  def test_parse_file_predicate_rejects_unrelated_three_key_hashes
    # Without __type marker, a random three-key hash with name/url
    # must NOT be confused with a file pointer — count guard enforces
    # the canonical shape.
    h = {
      "name" => "foo",
      "url"  => "https://example.com/x",
      "extra" => "bar",
    }
    refute h.parse_file?
  end
end
