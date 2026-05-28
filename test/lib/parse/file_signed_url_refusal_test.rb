# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for `Parse::File#url=` refusing presigned / signed URLs.
#
# Why this matters: the design contract is "@url is the stable
# canonical URL, never a short-TTL signed URL." Signed URLs MUST come
# from `download_url(as:, ttl:)` and be returned, not assigned. Without
# structural enforcement, the convention is just a docstring — any
# adapter author who writes `file.url = presigned_url` (the most
# natural Ruby pattern) leaks the capability through `to_s`,
# `<%= file %>` in ERB, `String(file)`, and every exception message
# that interpolates the file.
#
# This test fixes the leak at the assignment point.
class TestFileSignedUrlRefusal < Minitest::Test
  def setup
    @original_trusted_hosts = Parse::File.instance_variable_get(:@trusted_url_hosts)
    @original_policy        = Parse::File.instance_variable_get(:@untrusted_url_policy)
    @original_warned        = Parse::File.instance_variable_get(:@warned_untrusted_hosts)
    Parse::File.trusted_url_hosts = [
      ".s3.amazonaws.com", "bucket.s3.amazonaws.com",
      ".cloudfront.net", "files.parsetfss.com",
    ]
    Parse::File.untrusted_url_policy = :warn
  end

  def teardown
    Parse::File.instance_variable_set(:@trusted_url_hosts, @original_trusted_hosts)
    Parse::File.instance_variable_set(:@untrusted_url_policy, @original_policy)
    Parse::File.instance_variable_set(:@warned_untrusted_hosts, @original_warned)
  end

  # ------------------------------------------------------------------
  # url= refuses each known signature param shape
  # ------------------------------------------------------------------

  def test_url_setter_refuses_sigv4_signature
    file = Parse::File.new("doc.pdf", "bytes", "application/pdf")
    err = assert_raises(Parse::File::SignedUrlError) do
      file.url = "https://bucket.s3.amazonaws.com/doc.pdf?" \
                 "X-Amz-Algorithm=AWS4-HMAC-SHA256&" \
                 "X-Amz-Signature=abc123"
    end
    assert_match(/refuses a signed URL/i, err.message)
  end

  def test_url_setter_refuses_sigv4_credential
    file = Parse::File.new("doc.pdf")
    assert_raises(Parse::File::SignedUrlError) do
      file.url = "https://bucket.s3.amazonaws.com/doc.pdf?" \
                 "X-Amz-Credential=AKIAEXAMPLE%2F20260528%2Fus-east-1%2Fs3%2Faws4_request"
    end
  end

  def test_url_setter_refuses_sts_session_token
    # STS temporary credentials are the highest-impact leak — make
    # sure the token form is refused even without a Signature alongside.
    file = Parse::File.new("doc.pdf")
    assert_raises(Parse::File::SignedUrlError) do
      file.url = "https://bucket.s3.amazonaws.com/d?X-Amz-Security-Token=FQoG_example"
    end
  end

  def test_url_setter_refuses_sigv2_legacy
    file = Parse::File.new("doc.pdf")
    assert_raises(Parse::File::SignedUrlError) do
      file.url = "https://bucket.s3.amazonaws.com/d?" \
                 "AWSAccessKeyId=AKIAEXAMPLE&Expires=1700000000&Signature=abc"
    end
  end

  def test_url_setter_refuses_cloudfront_signed_url
    file = Parse::File.new("doc.pdf")
    assert_raises(Parse::File::SignedUrlError) do
      file.url = "https://d111111abcdef8.cloudfront.net/private/doc.pdf?" \
                 "Key-Pair-Id=APKAEXAMPLE&Policy=eyJ&Signature=abc"
    end
  end

  # ------------------------------------------------------------------
  # url= ACCEPTS canonical URLs (no over-refusal)
  # ------------------------------------------------------------------

  def test_url_setter_accepts_canonical_s3_url
    file = Parse::File.new("doc.pdf")
    file.url = "https://bucket.s3.amazonaws.com/tenants/abc/doc.pdf"
    assert_equal "https://bucket.s3.amazonaws.com/tenants/abc/doc.pdf", file.url
  end

  def test_url_setter_accepts_parse_hosted_url
    file = Parse::File.new("img.png")
    file.url = "https://files.parsetfss.com/abc/img.png"
    assert_equal "https://files.parsetfss.com/abc/img.png", file.url
  end

  def test_url_setter_accepts_canonical_cloudfront_url
    # Public CloudFront URL (no signature) must NOT be refused.
    file = Parse::File.new("img.png")
    file.url = "https://d111111abcdef8.cloudfront.net/public/img.png"
    assert_equal "https://d111111abcdef8.cloudfront.net/public/img.png", file.url
  end

  def test_url_setter_accepts_canonical_url_with_unrelated_query_params
    # URLs with non-signature query params (`?v=2`, `?cache_bust=...`)
    # are common and must pass through.
    file = Parse::File.new("img.png")
    file.url = "https://files.parsetfss.com/abc/img.png?v=2&cache=bust"
    assert_equal "https://files.parsetfss.com/abc/img.png?v=2&cache=bust", file.url
  end

  def test_url_setter_accepts_url_containing_signature_word_in_path
    # Defensive: a URL like /signature-pad/img.png must not match.
    # The check is for `?X-Amz-Signature=` (query param), not the word
    # appearing anywhere.
    file = Parse::File.new("img.png")
    file.url = "https://files.parsetfss.com/signature-uploads/img.png"
    assert_equal "https://files.parsetfss.com/signature-uploads/img.png", file.url
  end

  def test_url_setter_accepts_nil
    file = Parse::File.new("doc.pdf", "bytes")
    file.url = "https://files.parsetfss.com/abc/doc.pdf"
    file.url = nil
    assert_nil file.url
  end

  # ------------------------------------------------------------------
  # Hydration via attributes= also refuses signed URLs
  # ------------------------------------------------------------------

  def test_attributes_hydration_refuses_signed_url
    # Defense in depth: even if the SDK is reading a row from Parse
    # Server where the `url` field somehow carries a signed URL
    # (DB corruption, mistaken backfill), refuse the assignment.
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    assert_raises(Parse::File::SignedUrlError) do
      file.attributes = {
        "name" => "doc.pdf",
        "url"  => "https://bucket.s3.amazonaws.com/doc.pdf?X-Amz-Signature=abc",
      }
    end
  end

  # ------------------------------------------------------------------
  # Class-level url_signature_param? helper
  # ------------------------------------------------------------------

  def test_url_signature_param_predicate_handles_each_known_form
    %w[
      ?X-Amz-Signature=abc
      ?X-Amz-Credential=abc
      ?X-Amz-Security-Token=abc
      ?AWSAccessKeyId=abc
      ?Key-Pair-Id=abc
      &X-Amz-Signature=abc
    ].each do |suffix|
      url = "https://bucket.s3.amazonaws.com/doc.pdf#{suffix}"
      assert Parse::File.url_signature_param?(url), "expected #{url} to be flagged"
    end
  end

  def test_url_signature_param_predicate_rejects_non_strings_and_blanks
    refute Parse::File.url_signature_param?(nil)
    refute Parse::File.url_signature_param?("")
    refute Parse::File.url_signature_param?(:not_a_string)
    refute Parse::File.url_signature_param?("https://no-query.example.com/doc")
  end

  def test_url_signature_param_predicate_does_not_match_partial_substrings
    # `signature_pad_id=` is not a signed URL.
    refute Parse::File.url_signature_param?("https://x.com/api?signature_pad_id=123")
    # `policy=` alone is too generic to flag (CloudFront URLs also
    # carry Key-Pair-Id, which IS flagged separately).
    refute Parse::File.url_signature_param?("https://x.com/api?policy=accept")
  end
end
