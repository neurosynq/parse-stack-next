# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the Parse::File secret-leakage hardening.
#
# Why this matters: storage adapters that issue short-TTL presigned
# download URLs (S3, GCS, CloudFront) hand the SDK a string whose
# possession IS the read capability. Any default formatter that emits
# the URL — `inspect` in an exception backtrace, log lines that
# interpolate the file — leaks the capability into log aggregators,
# error reporters, and developer terminals.
#
# Two protections:
#   (1) `#inspect` never includes `@url`; only a presence-boolean.
#   (2) `Parse::File.log_filter` returns a regex operators can plug
#       into log scrubbers / Rails `filter_parameters` to redact
#       presigned-URL query params from log lines.
#
# `#to_s` is intentionally left returning `@url` so ERB templates,
# `<img src="<%= file %>">`, and string interpolation continue to work.
# The invariant the rest of the SDK has to maintain: `@url` is ALWAYS
# a stable canonical URL (e.g. the S3 object URL with no query string,
# or a stable app-side proxy URL), NEVER a presigned URL with a
# signature query parameter. Presigned URLs are returned only from
# `Parse::File#download_url(as:, ttl:)` (added in a later phase) and
# are never assigned to `@url`.
class TestFileUrlLeakage < Minitest::Test
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
  # #inspect must not include @url
  # ------------------------------------------------------------------

  def test_inspect_does_not_emit_full_url_for_legacy_parse_file
    file = Parse::File.new(name: "img.png", contents: nil)
    file.attributes = {
      "name" => "img.png",
      "url"  => "https://files.parsetfss.com/abc/img.png",
    }
    out = file.inspect
    refute_includes out, "https://files.parsetfss.com",
                    "inspect must not include the URL string"
    refute_includes out, "/abc/img.png"
  end

  def test_inspect_does_not_emit_full_url_for_adapter_stored_file
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    file.attributes = {
      "name" => "doc.pdf",
      "url"  => "https://bucket.s3.amazonaws.com/tenants/abc/uuid-doc.pdf",
      "key"  => "tenants/abc/uuid-doc.pdf",
    }
    out = file.inspect
    refute_includes out, "https://",
                    "inspect must not include any URL scheme"
    refute_includes out, "bucket.s3.amazonaws.com",
                    "inspect must not include the URL host"
    # Note: the URL terminal segment (`uuid-doc.pdf`) DOES appear inside
    # `@key` (which is the bucket-relative object key, intentionally
    # shown for debugging). The leak we are guarding against is the
    # SCHEME + HOST that turns `@key` back into a fetchable resource.
  end

  def test_inspect_signals_url_presence_without_revealing_url
    set_file = Parse::File.new(name: "img.png", contents: nil)
    set_file.attributes = {
      "name" => "img.png",
      "url"  => "https://files.parsetfss.com/abc/img.png",
    }
    assert_match(/@url=set/, set_file.inspect)

    unset_file = Parse::File.new("img.png", "bytes", "image/png")
    assert_match(/@url=blank/, unset_file.inspect)
  end

  def test_inspect_includes_name_mime_type_and_key
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    file.attributes = {
      "name" => "doc.pdf",
      "url"  => "https://bucket.s3.amazonaws.com/t/u-doc.pdf",
      "key"  => "t/u-doc.pdf",
    }
    out = file.inspect
    assert_includes out, "doc.pdf"            # @name
    assert_includes out, "t/u-doc.pdf"        # @key (non-secret, helpful for debugging)
  end

  def test_inspect_omits_key_section_when_key_blank
    file = Parse::File.new("doc.pdf", "bytes", "application/pdf")
    refute_match(/@key=/, file.inspect)
  end

  # ------------------------------------------------------------------
  # #to_s is intentionally unchanged (back-compat)
  # ------------------------------------------------------------------

  def test_to_s_returns_canonical_url
    # Documenting the invariant: callers depend on `file.to_s` →
    # canonical URL for ERB rendering. Changing this would silently
    # break `<img src="<%= file %>">` in every downstream app.
    # Adapters MUST keep `@url` canonical (never presigned) so this
    # remains safe to emit.
    file = Parse::File.new(name: "img.png", contents: nil)
    file.attributes = {
      "name" => "img.png",
      "url"  => "https://files.parsetfss.com/abc/img.png",
    }
    assert_equal "https://files.parsetfss.com/abc/img.png", file.to_s
  end

  # ------------------------------------------------------------------
  # Parse::File.log_filter regex
  # ------------------------------------------------------------------

  def test_log_filter_matches_aws_sigv4_presigned_url
    url = "https://bucket.s3.us-east-1.amazonaws.com/tenants/abc/u-doc.pdf?" \
          "X-Amz-Algorithm=AWS4-HMAC-SHA256&" \
          "X-Amz-Credential=AKIAEXAMPLE%2F20260528%2Fus-east-1%2Fs3%2Faws4_request&" \
          "X-Amz-Date=20260528T120000Z&X-Amz-Expires=900&" \
          "X-Amz-SignedHeaders=host&" \
          "X-Amz-Signature=abc123def456"
    assert_match Parse::File.log_filter, url
  end

  def test_log_filter_matches_aws_sigv2_presigned_url
    url = "https://bucket.s3.amazonaws.com/img.png?" \
          "AWSAccessKeyId=AKIAEXAMPLE&Expires=1700000000&" \
          "Signature=abc123%2Fdef456"
    assert_match Parse::File.log_filter, url
  end

  def test_log_filter_matches_aws_sts_token_url
    # STS temporary credentials are the highest-impact leak —
    # ensure X-Amz-Security-Token is caught.
    url = "https://bucket.s3.amazonaws.com/d.pdf?X-Amz-Security-Token=FQoG..."
    assert_match Parse::File.log_filter, url
  end

  def test_log_filter_matches_cloudfront_signed_url
    url = "https://d111111abcdef8.cloudfront.net/private/doc.pdf?" \
          "Key-Pair-Id=APKAEXAMPLE&" \
          "Policy=eyJTdGF0ZW1lbnQiOlt7IlJlc291cmNlIjoiKi8qIn1dfQ__&" \
          "Signature=abc123"
    assert_match Parse::File.log_filter, url
  end

  def test_log_filter_does_not_match_canonical_url
    # Canonical S3 / Parse-hosted URLs without signature params must
    # NOT be scrubbed — that would over-redact every file URL in
    # every log message.
    refute_match Parse::File.log_filter,
                    "https://bucket.s3.amazonaws.com/tenants/abc/uuid-doc.pdf"
    refute_match Parse::File.log_filter,
                    "https://files.parsetfss.com/abc/img.png"
  end

  def test_log_filter_does_not_match_unrelated_query_params
    # A URL with query params that aren't presigned-URL signatures
    # must not match — `?foo=bar&page=2` style URLs are common and
    # should not be redacted.
    refute_match Parse::File.log_filter,
                    "https://example.com/api/files?foo=bar&page=2"
  end

  def test_log_filter_scrubbing_round_trip
    msg = "uploaded file https://bucket.s3.amazonaws.com/d.pdf?" \
          "X-Amz-Signature=abc123 successfully"
    scrubbed = msg.gsub(Parse::File.log_filter, "[FILTERED_PRESIGNED_URL]")
    refute_includes scrubbed, "X-Amz-Signature"
    refute_includes scrubbed, "abc123"
    assert_includes scrubbed, "[FILTERED_PRESIGNED_URL]"
    assert_includes scrubbed, "uploaded file"
    assert_includes scrubbed, "successfully"
  end

  def test_log_filter_handles_multiple_urls_in_single_line
    msg = "https://b.s3.amazonaws.com/a?X-Amz-Signature=a1 " \
          "https://b.s3.amazonaws.com/b?X-Amz-Signature=b2"
    scrubbed = msg.gsub(Parse::File.log_filter, "[FILTERED]")
    refute_includes scrubbed, "X-Amz-Signature"
    assert_equal 2, scrubbed.scan("[FILTERED]").length
  end

  def test_log_filter_is_frozen_singleton
    # Avoid the gotcha of operators mutating the shared regex object
    # at runtime. Each access returns the same frozen instance.
    assert_predicate Parse::File.log_filter, :frozen?
    assert_same Parse::File.log_filter, Parse::File.log_filter
  end

  # ------------------------------------------------------------------
  # Parse::File.filter_parameter_names
  # ------------------------------------------------------------------

  def test_filter_parameter_names_covers_aws_prefixed_params
    # Default list: AWS-prefixed params only — never collides with a
    # Rails app's privacy_policy / signature / expires form fields.
    names = Parse::File.filter_parameter_names
    %w[X-Amz-Signature X-Amz-Credential X-Amz-Security-Token
       X-Amz-Algorithm X-Amz-Date X-Amz-Expires
       AWSAccessKeyId Key-Pair-Id].each do |sig_param|
      assert(names.any? { |rx| rx.match?(sig_param) },
             "filter_parameter_names should match #{sig_param}")
    end
  end

  def test_filter_parameter_names_does_not_include_bare_signature_or_policy
    # Critical: bare `Signature` and `Policy` are too generic and would
    # over-redact privacy_policy / e-signature / webhook signature
    # fields across every Rails app. They live in the opt-in
    # cloudfront_signed_param_names list instead.
    names = Parse::File.filter_parameter_names
    refute(names.any? { |rx| rx.match?("Signature") },
           "bare `Signature` must not be in safe defaults — collides with " \
           "webhook signatures, DocuSign signatures, etc.")
    refute(names.any? { |rx| rx.match?("Policy") },
           "bare `Policy` must not be in safe defaults — collides with " \
           "privacy_policy, policy_id, etc.")
    refute(names.any? { |rx| rx.match?("Expires") },
           "bare `Expires` must not be in safe defaults — collides with " \
           "any cache-control-style field.")
  end

  def test_filter_parameter_names_is_case_insensitive
    # Some HTTP clients normalize query param names to lowercase.
    # The regex must catch both cases.
    names = Parse::File.filter_parameter_names
    assert(names.any? { |rx| rx.match?("x-amz-signature") })
    assert(names.any? { |rx| rx.match?("X-AMZ-SIGNATURE") })
  end

  def test_filter_parameter_names_does_not_match_unrelated_params
    names = Parse::File.filter_parameter_names
    refute(names.any? { |rx| rx.match?("page") })
    refute(names.any? { |rx| rx.match?("api_key") }, "API keys are filtered separately, not by this list")
    refute(names.any? { |rx| rx.match?("privacy_policy") },
           "must not over-redact a privacy_policy form field")
    refute(names.any? { |rx| rx.match?("e_signature") },
           "must not over-redact an e-signature form field")
    refute(names.any? { |rx| rx.match?("expires_at") },
           "must not over-redact a cache-style expires_at field")
  end

  # ------------------------------------------------------------------
  # Parse::File.cloudfront_signed_param_names — opt-in CloudFront extras
  # ------------------------------------------------------------------

  def test_cloudfront_signed_param_names_covers_bare_signature_policy_expires
    names = Parse::File.cloudfront_signed_param_names
    %w[Signature Policy Expires].each do |param|
      assert(names.any? { |rx| rx.match?(param) },
             "cloudfront_signed_param_names should match #{param}")
    end
  end

  def test_cloudfront_signed_param_names_is_frozen_singleton
    assert_predicate Parse::File.cloudfront_signed_param_names, :frozen?
    assert_same Parse::File.cloudfront_signed_param_names,
                Parse::File.cloudfront_signed_param_names
  end

  def test_cloudfront_signed_param_names_composes_with_defaults
    # Documented usage: append the CloudFront list onto the defaults.
    combined = Parse::File.filter_parameter_names +
               Parse::File.cloudfront_signed_param_names
    %w[X-Amz-Signature AWSAccessKeyId Key-Pair-Id
       Signature Policy Expires].each do |param|
      assert(combined.any? { |rx| rx.match?(param) },
             "combined list should match #{param}")
    end
  end
end
