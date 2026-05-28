# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the `@key` field on Parse::File and the
# `saved?` predicate that has to honor it.
#
# Why this matters: storage adapters (the upcoming S3Adapter is the
# canonical example) hand the SDK a Parse::File whose canonical URL
# encodes a structured object key —
# `https://bucket.s3.us-east-1.amazonaws.com/tenants/<id>/<uuid>-doc.pdf`.
# The terminal path segment (`<uuid>-doc.pdf`) does NOT equal `@name`
# (`doc.pdf`), so the legacy `@name == File.basename(@url)` check would
# falsely report `saved? == false` and re-trigger the upload path on
# every `save` call. The `@key` field is the adapter's positive signal
# that the file is canonically located.
class TestFileKeyField < Minitest::Test
  def setup
    # Allow the test URLs through hydration without warning noise.
    @original_trusted_hosts = Parse::File.instance_variable_get(:@trusted_url_hosts)
    @original_policy        = Parse::File.instance_variable_get(:@untrusted_url_policy)
    @original_warned        = Parse::File.instance_variable_get(:@warned_untrusted_hosts)
    Parse::File.trusted_url_hosts = [
      ".s3.amazonaws.com", ".s3.us-east-1.amazonaws.com",
      "bucket.s3.amazonaws.com", "files.parsetfss.com",
    ]
    Parse::File.untrusted_url_policy = :raise
  end

  def teardown
    Parse::File.instance_variable_set(:@trusted_url_hosts, @original_trusted_hosts)
    Parse::File.instance_variable_set(:@untrusted_url_policy, @original_policy)
    Parse::File.instance_variable_set(:@warned_untrusted_hosts, @original_warned)
  end

  # ------------------------------------------------------------------
  # @key accessor surface
  # ------------------------------------------------------------------

  def test_key_defaults_to_nil_for_legacy_constructor
    file = Parse::File.new("doc.pdf", "bytes", "application/pdf")
    assert_nil file.key
  end

  def test_key_is_writeable
    file = Parse::File.new("doc.pdf", "bytes", "application/pdf")
    file.key = "tenants/abc/uuid-doc.pdf"
    assert_equal "tenants/abc/uuid-doc.pdf", file.key
  end

  # ------------------------------------------------------------------
  # @key round-trips through Hash hydration (attributes=)
  # ------------------------------------------------------------------

  def test_attributes_hydration_picks_up_string_key
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    file.attributes = {
      "name" => "doc.pdf",
      "url"  => "https://bucket.s3.amazonaws.com/tenants/abc/uuid-doc.pdf",
      "key"  => "tenants/abc/uuid-doc.pdf",
    }
    assert_equal "tenants/abc/uuid-doc.pdf", file.key
  end

  def test_attributes_hydration_picks_up_symbol_key
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    file.attributes = {
      name: "doc.pdf",
      url:  "https://bucket.s3.amazonaws.com/tenants/abc/uuid-doc.pdf",
      key:  "tenants/abc/uuid-doc.pdf",
    }
    assert_equal "tenants/abc/uuid-doc.pdf", file.key
  end

  def test_attributes_hydration_without_key_leaves_key_nil
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    file.attributes = {
      "name" => "doc.pdf",
      "url"  => "https://files.parsetfss.com/abc/doc.pdf",
    }
    assert_nil file.key
  end

  def test_attributes_hydration_preserves_existing_key_when_missing
    # Re-hydration should not clobber `@key` if the incoming hash omits it.
    # Regression check: a partial-update path that re-runs `attributes=`
    # with only `{url: ...}` should not silently strip `@key`.
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    file.key = "tenants/abc/uuid-doc.pdf"
    file.attributes = {
      "name" => "doc.pdf",
      "url"  => "https://bucket.s3.amazonaws.com/tenants/abc/uuid-doc.pdf",
    }
    assert_equal "tenants/abc/uuid-doc.pdf", file.key
  end

  # ------------------------------------------------------------------
  # saved? — adapter-stored files (with @key)
  # ------------------------------------------------------------------

  def test_saved_true_when_key_present_even_with_prefixed_url
    # The canonical foot-gun. URL terminal segment (`uuid-doc.pdf`)
    # diverges from `@name` (`doc.pdf`); without `@key` recognition,
    # saved? would be false and `save` would attempt to re-upload.
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    file.attributes = {
      "name" => "doc.pdf",
      "url"  => "https://bucket.s3.amazonaws.com/tenants/abc/uuid-doc.pdf",
      "key"  => "tenants/abc/uuid-doc.pdf",
    }
    assert file.saved?, "expected saved? to be true when @key is present"
  end

  def test_saved_true_with_deeply_prefixed_key
    # Multi-segment key (typical canonical layout
    # `<tenant>/<class>/<id>/<uuid>.ext`).
    file = Parse::File.new(name: "report.pdf", contents: nil)
    file.attributes = {
      "name" => "report.pdf",
      "url"  => "https://bucket.s3.amazonaws.com/t1/Post/objId/u-report.pdf",
      "key"  => "t1/Post/objId/u-report.pdf",
    }
    assert file.saved?
  end

  def test_saved_false_when_key_present_but_url_blank
    file = Parse::File.new("doc.pdf")
    file.key = "tenants/abc/uuid-doc.pdf"
    refute file.saved?, "expected saved? to be false when @url is blank"
  end

  def test_saved_false_when_key_present_but_name_blank
    file = Parse::File.new("doc.pdf")
    file.instance_variable_set(:@name, nil)
    file.instance_variable_set(:@url, "https://bucket.s3.amazonaws.com/t/u-doc.pdf")
    file.key = "t/u-doc.pdf"
    refute file.saved?
  end

  # ------------------------------------------------------------------
  # saved? — legacy Parse-hosted files (no @key, basename match)
  # ------------------------------------------------------------------

  def test_saved_true_for_legacy_parse_hosted_file
    file = Parse::File.new(name: "img.png", contents: nil)
    file.attributes = {
      "name" => "img.png",
      "url"  => "https://files.parsetfss.com/abc/img.png",
    }
    assert file.saved?, "legacy basename-equality check still applies when @key is blank"
  end

  def test_saved_false_when_no_key_and_basename_mismatch
    # Without `@key`, name/basename divergence MUST still flip saved? false —
    # this is the original safety check protecting against assigning a URL
    # whose terminal segment was renamed by the server.
    file = Parse::File.new(name: "img.png", contents: nil)
    file.attributes = {
      "name" => "img.png",
      "url"  => "https://files.parsetfss.com/abc/different-name.png",
    }
    refute file.saved?
  end

  def test_saved_false_when_url_and_name_both_blank
    file = Parse::File.new("doc.pdf", "bytes", "application/pdf")
    refute file.saved?
  end

  # ------------------------------------------------------------------
  # save() guard — adapter-stored files must not re-upload
  # ------------------------------------------------------------------

  def test_save_short_circuits_when_adapter_stored_file_already_saved
    # If saved? incorrectly returned false for an adapter-stored file,
    # save() would call client.create_file and the test would hit a
    # mock-expectation failure. With the @key recognition the guard
    # short-circuits and save() returns true without touching the client.
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    file.attributes = {
      "name" => "doc.pdf",
      "url"  => "https://bucket.s3.amazonaws.com/t1/uuid-doc.pdf",
      "key"  => "t1/uuid-doc.pdf",
    }
    # Stub client to fail loudly if save() tries to upload.
    fake_client = Minitest::Mock.new
    file.stub :client, fake_client do
      assert_equal true, file.save
    end
    fake_client.verify  # zero expectations → must not have been called
  end
end
