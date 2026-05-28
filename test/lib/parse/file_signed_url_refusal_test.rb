# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the URL normalization point on `Parse::File`.
#
# Architectural context (s3_adapter_plan.md rev 3, D1 + D2):
# `@url` is ALWAYS the bare canonical URL — never a signed URL. The
# uniform normalization rule applies to every writer (caller-side
# `url=`, hydration `attributes=`):
#
# - Detect signature params (`X-Amz-Signature`, `X-Amz-Credential`,
#   `X-Amz-Security-Token`, `AWSAccessKeyId`, `Key-Pair-Id`).
# - If present, STRIP the query string entirely; store the bare URL
#   in `@url`; stash the original signed URL in `@presigned_url` with
#   a data-driven expiry parsed from `X-Amz-Date + X-Amz-Expires`
#   (SigV4) or `Expires` (SigV2 / CloudFront).
# - Invalidate the `@key` cache (URL change implies potential
#   storage-location change).
# - Run the trusted-host check.
#
# No raise. The Wave A `SignedUrlError` class stays defined for
# downstream apps that want stricter enforcement, but the built-in
# SDK writers normalize silently — asymmetric behavior between
# writers was an explicit anti-goal in rev 3.
class TestFileSignedUrlNormalization < Minitest::Test
  def setup
    @original_trusted_hosts = Parse::File.instance_variable_get(:@trusted_url_hosts)
    @original_policy        = Parse::File.instance_variable_get(:@untrusted_url_policy)
    @original_warned        = Parse::File.instance_variable_get(:@warned_untrusted_hosts)
    @original_signed_policy = Parse::File.instance_variable_get(:@signed_url_policy)
    Parse::File.trusted_url_hosts = [
      ".s3.amazonaws.com", "bucket.s3.amazonaws.com",
      ".cloudfront.net", "files.parsetfss.com",
    ]
    Parse::File.untrusted_url_policy = :warn
    Parse::File.signed_url_policy = :strip
  end

  def teardown
    Parse::File.instance_variable_set(:@trusted_url_hosts, @original_trusted_hosts)
    Parse::File.instance_variable_set(:@untrusted_url_policy, @original_policy)
    Parse::File.instance_variable_set(:@warned_untrusted_hosts, @original_warned)
    Parse::File.instance_variable_set(:@signed_url_policy, @original_signed_policy)
  end

  # ------------------------------------------------------------------
  # url= strips and stashes signed URLs
  # ------------------------------------------------------------------

  def test_url_setter_strips_sigv4_signature_and_stashes_presigned
    file = Parse::File.new("doc.pdf", "bytes", "application/pdf")
    signed = "https://bucket.s3.amazonaws.com/doc.pdf?" \
             "X-Amz-Algorithm=AWS4-HMAC-SHA256&" \
             "X-Amz-Date=20260528T120000Z&" \
             "X-Amz-Expires=900&" \
             "X-Amz-Signature=abc123"
    file.url = signed
    assert_equal "https://bucket.s3.amazonaws.com/doc.pdf", file.url,
                 "@url must be the bare canonical URL"
    assert_equal signed, file.presigned_url,
                 "the original signed URL must be stashed in @presigned_url"
    refute_nil file.presigned_url_expires_at,
               "@presigned_url_expires_at must be populated from query params"
  end

  def test_url_setter_strips_cloudfront_signed_url
    file = Parse::File.new("doc.pdf")
    signed = "https://d111.cloudfront.net/private/doc.pdf?" \
             "Key-Pair-Id=APKAEXAMPLE&Policy=eyJ&Signature=abc&Expires=1700000000"
    file.url = signed
    assert_equal "https://d111.cloudfront.net/private/doc.pdf", file.url
    assert_equal signed, file.presigned_url
  end

  def test_url_setter_strips_sigv2_legacy
    file = Parse::File.new("doc.pdf")
    signed = "https://bucket.s3.amazonaws.com/doc.pdf?" \
             "AWSAccessKeyId=AKIAEXAMPLE&Expires=1700000000&Signature=abc"
    file.url = signed
    assert_equal "https://bucket.s3.amazonaws.com/doc.pdf", file.url
  end

  def test_url_setter_does_NOT_raise_signed_url_error
    # Critical assertion: the Wave A SignedUrlError raise was reverted
    # in rev 3 — both writers normalize uniformly. The exception class
    # still exists for downstream stricter-mode use.
    file = Parse::File.new("doc.pdf")
    signed = "https://bucket.s3.amazonaws.com/doc.pdf?X-Amz-Signature=abc"
    refute_raises Parse::File::SignedUrlError do
      file.url = signed
    end
  end

  # ------------------------------------------------------------------
  # url= accepts canonical URLs unchanged
  # ------------------------------------------------------------------

  def test_url_setter_accepts_canonical_s3_url
    file = Parse::File.new("doc.pdf")
    file.url = "https://bucket.s3.amazonaws.com/tenants/abc/doc.pdf"
    assert_equal "https://bucket.s3.amazonaws.com/tenants/abc/doc.pdf", file.url
    assert_nil file.presigned_url,
               "no presigned stash when URL was already canonical"
  end

  def test_url_setter_accepts_parse_hosted_url
    file = Parse::File.new("img.png")
    file.url = "https://files.parsetfss.com/abc/img.png"
    assert_equal "https://files.parsetfss.com/abc/img.png", file.url
    assert_nil file.presigned_url
  end

  def test_url_setter_accepts_canonical_url_with_unrelated_query_params
    # URLs with non-signature query params (`?v=2`, `?cache_bust=...`)
    # are common and must pass through unchanged.
    file = Parse::File.new("img.png")
    file.url = "https://files.parsetfss.com/abc/img.png?v=2&cache=bust"
    assert_equal "https://files.parsetfss.com/abc/img.png?v=2&cache=bust", file.url
    assert_nil file.presigned_url
  end

  def test_url_setter_accepts_nil_and_clears_all_url_state
    # The post-review fix: assigning nil must wipe `@url`,
    # `@presigned_url`, AND `@presigned_url_expires_at` — not leave
    # the stash as a stale capability the operator could render.
    file = Parse::File.new("doc.pdf")
    file.url = "https://bucket.s3.amazonaws.com/doc.pdf?" \
               "X-Amz-Date=20260528T120000Z&X-Amz-Expires=900&X-Amz-Signature=abc"
    refute_nil file.presigned_url
    refute_nil file.presigned_url_expires_at

    file.url = nil
    assert_nil file.url,                       "url must be cleared"
    assert_nil file.presigned_url,             "presigned_url stash must be cleared"
    assert_nil file.presigned_url_expires_at,  "expiry must be cleared"
  end

  # ------------------------------------------------------------------
  # Stash is CLEARED on canonical-URL reassignment (review-board fix)
  # ------------------------------------------------------------------

  def test_canonical_url_reassignment_clears_stash
    # The most-flagged review item: `file.url = signed; file.url =
    # canonical` previously left the stale signed URL in
    # @presigned_url. Operators rendering `file.presigned_url` in
    # views would get a stale capability. Now: reassignment to a
    # non-signed URL clears the stash atomically.
    file = Parse::File.new("doc.pdf")
    file.url = "https://bucket.s3.amazonaws.com/doc.pdf?X-Amz-Signature=abc"
    refute_nil file.presigned_url

    file.url = "https://bucket.s3.amazonaws.com/doc.pdf"
    assert_nil file.presigned_url,
               "canonical URL reassignment must clear the stash"
    assert_nil file.presigned_url_expires_at,
               "expiry must be cleared alongside the stash"
  end

  def test_signed_url_reassignment_replaces_stash
    # Sanity check: two consecutive signed-URL assignments replace
    # the stash rather than leaking the older one.
    file = Parse::File.new("doc.pdf")
    file.url = "https://bucket.s3.amazonaws.com/doc.pdf?X-Amz-Signature=abc&X-Amz-Date=20260528T120000Z&X-Amz-Expires=900"
    first_stash  = file.presigned_url
    first_expiry = file.presigned_url_expires_at

    file.url = "https://bucket.s3.amazonaws.com/doc.pdf?X-Amz-Signature=xyz&X-Amz-Date=20260528T130000Z&X-Amz-Expires=900"
    refute_equal first_stash,  file.presigned_url
    refute_equal first_expiry, file.presigned_url_expires_at
  end

  # ------------------------------------------------------------------
  # signed_url_policy = :raise for strict-mode operators
  # ------------------------------------------------------------------

  def test_signed_url_policy_raise_blocks_url_setter
    Parse::File.signed_url_policy = :raise
    file = Parse::File.new("doc.pdf")
    err = assert_raises(Parse::File::SignedUrlError) do
      file.url = "https://bucket.s3.amazonaws.com/doc.pdf?X-Amz-Signature=abc"
    end
    assert_match(/signed_url_policy.*raise/i, err.message)
  end

  def test_signed_url_policy_raise_blocks_attributes_hydration
    # Uniform across writers — operators who flip strict mode get
    # the same enforcement on hydration as on caller-side writes.
    Parse::File.signed_url_policy = :raise
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    assert_raises(Parse::File::SignedUrlError) do
      file.attributes = {
        "name" => "doc.pdf",
        "url"  => "https://bucket.s3.amazonaws.com/doc.pdf?X-Amz-Signature=abc",
      }
    end
  end

  def test_signed_url_policy_strip_is_default
    assert_equal :strip, Parse::File.signed_url_policy
  end

  def test_signed_url_policy_strip_does_not_raise
    Parse::File.signed_url_policy = :strip
    file = Parse::File.new("doc.pdf")
    refute_raises Parse::File::SignedUrlError do
      file.url = "https://bucket.s3.amazonaws.com/doc.pdf?X-Amz-Signature=abc"
    end
  end

  # ------------------------------------------------------------------
  # :strip untrusted-host policy interaction with the stash
  # ------------------------------------------------------------------

  def test_strip_untrusted_host_policy_also_clears_presigned_stash
    # Defense in depth: if `untrusted_url_policy = :strip` rejects
    # the URL because the host isn't trusted, the stash must NOT
    # retain the attacker-controlled signed URL. Otherwise the
    # operator who picked `:strip` to keep untrusted URLs out of
    # their views still ends up with an attacker URL in
    # `@presigned_url`.
    Parse::File.untrusted_url_policy = :strip
    file = Parse::File.new("doc.pdf")
    capture_io do
      file.url = "https://attacker.example.com/doc.pdf?X-Amz-Signature=abc"
    end
    assert_nil file.url,
               "untrusted host with :strip policy must blank @url"
    assert_nil file.presigned_url,
               "and must also clear @presigned_url so the strip policy " \
               "isn't a half-measure"
    assert_nil file.presigned_url_expires_at
  end

  # ------------------------------------------------------------------
  # presigned_url_valid? helper (avoids hand-rolled time arithmetic)
  # ------------------------------------------------------------------

  def test_presigned_url_valid_returns_true_when_not_expired
    file = Parse::File.new("doc.pdf")
    file.instance_variable_set(:@presigned_url, "https://x/y?X-Amz-Signature=abc")
    file.instance_variable_set(:@presigned_url_expires_at, Time.now.utc + 3600)
    assert file.presigned_url_valid?
  end

  def test_presigned_url_valid_returns_false_when_expired
    file = Parse::File.new("doc.pdf")
    file.instance_variable_set(:@presigned_url, "https://x/y?X-Amz-Signature=abc")
    file.instance_variable_set(:@presigned_url_expires_at, Time.now.utc - 1)
    refute file.presigned_url_valid?
  end

  def test_presigned_url_valid_returns_false_when_no_stash
    file = Parse::File.new("doc.pdf")
    refute file.presigned_url_valid?
  end

  def test_presigned_url_valid_buffer_treats_near_expiry_as_invalid
    # Operator passes a 60-second buffer so they refetch before the
    # URL actually goes stale server-side.
    file = Parse::File.new("doc.pdf")
    file.instance_variable_set(:@presigned_url, "https://x/y?X-Amz-Signature=abc")
    file.instance_variable_set(:@presigned_url_expires_at, Time.now.utc + 30)
    refute file.presigned_url_valid?(buffer: 60),
           "buffer must push valid? false when within the safety margin"
    assert file.presigned_url_valid?(buffer: 10),
           "smaller buffer that doesn't engulf the remaining TTL must be valid"
  end

  # ------------------------------------------------------------------
  # attributes= behaves IDENTICALLY (rev 3 D2 — uniform normalization)
  # ------------------------------------------------------------------

  def test_attributes_hydration_strips_signed_url_same_as_setter
    # Parse Server with S3FilesAdapter returns presigned URLs on every
    # read. attributes= must strip + stash, NOT raise.
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    signed = "https://bucket.s3.amazonaws.com/doc.pdf?" \
             "X-Amz-Date=20260528T120000Z&X-Amz-Expires=900&X-Amz-Signature=abc"
    file.attributes = { "name" => "doc.pdf", "url" => signed }
    assert_equal "https://bucket.s3.amazonaws.com/doc.pdf", file.url
    assert_equal signed, file.presigned_url
  end

  def test_attributes_hydration_does_NOT_raise_signed_url_error
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    refute_raises Parse::File::SignedUrlError do
      file.attributes = {
        "name" => "doc.pdf",
        "url"  => "https://bucket.s3.amazonaws.com/doc.pdf?X-Amz-Signature=abc",
      }
    end
  end

  # ------------------------------------------------------------------
  # Bare-key URL pattern passes through normalization untouched
  # ------------------------------------------------------------------

  def test_bare_key_url_pattern_passes_through_unchanged
    # Some apps store the canonical bucket-relative key directly in
    # `@url` (no scheme, no host, no signature) — `assets/team/x.jpg`
    # rather than `https://bucket.s3.../assets/team/x.jpg`. The
    # normalization point must NOT mangle these (no `?`, no `&`, no
    # signature param). Without an explicit test, a future regex
    # change could regress this.
    Parse::File.untrusted_url_policy = :warn
    file = Parse::File.new(name: "x.jpg", contents: nil)
    capture_io { file.url = "assets/team/x.jpg" }
    assert_equal "assets/team/x.jpg", file.url
    assert_nil file.presigned_url
  end

  def test_bare_key_with_path_traversal_chars_is_left_to_caller
    # The normalization point does not police path content — `..`,
    # leading `/`, control chars all pass through. App-level
    # validation owns that. The SDK's only invariant is "no signed
    # URL ends up in @url"; bare key shapes are off the signature
    # radar.
    Parse::File.untrusted_url_policy = :warn
    file = Parse::File.new(name: "x.jpg", contents: nil)
    capture_io { file.url = "/abs/path/x.jpg" }
    assert_equal "/abs/path/x.jpg", file.url
  end

  # ------------------------------------------------------------------
  # parse_presigned_expiry parses TTL from query params
  # ------------------------------------------------------------------

  def test_parse_presigned_expiry_handles_sigv4
    # X-Amz-Date = 2026-05-28T12:00:00Z, X-Amz-Expires = 900 (15 min)
    # → expiry at 2026-05-28T12:15:00Z
    url = "https://x/y?X-Amz-Date=20260528T120000Z&X-Amz-Expires=900&X-Amz-Signature=abc"
    expiry = Parse::File.parse_presigned_expiry(url)
    refute_nil expiry
    assert_equal Time.utc(2026, 5, 28, 12, 15, 0), expiry
  end

  def test_parse_presigned_expiry_handles_sigv2
    # Expires = Unix timestamp
    unix = Time.utc(2026, 5, 28, 12, 15, 0).to_i
    url = "https://x/y?AWSAccessKeyId=AKIA&Expires=#{unix}&Signature=abc"
    expiry = Parse::File.parse_presigned_expiry(url)
    refute_nil expiry
    assert_equal Time.utc(2026, 5, 28, 12, 15, 0), expiry
  end

  def test_parse_presigned_expiry_returns_nil_for_unsigned_url
    assert_nil Parse::File.parse_presigned_expiry("https://x/y")
  end

  def test_parse_presigned_expiry_returns_nil_for_non_string
    assert_nil Parse::File.parse_presigned_expiry(nil)
    assert_nil Parse::File.parse_presigned_expiry(:not_a_string)
  end

  def test_parse_presigned_expiry_returns_nil_for_malformed_date
    url = "https://x/y?X-Amz-Date=bogus&X-Amz-Expires=900"
    assert_nil Parse::File.parse_presigned_expiry(url)
  end

  def test_parse_presigned_expiry_returns_nil_for_out_of_range_components
    # Ruby's `Time.utc` rolls some invalid date components over
    # silently (Feb 31 → Mar 3, Feb 29 in non-leap → Mar 1). But for
    # truly out-of-range components — month > 12, hour > 23,
    # minute > 59 — it raises ArgumentError. The rescue inside
    # `parse_presigned_expiry` must convert that raise into a clean
    # nil return so hydration of a row with corrupt date data
    # doesn't crash the caller.
    # Ruby's Time.utc only raises on certain out-of-range components
    # — month > 12 and hour > 23 are reliable; minute=60 / second=60
    # are treated as leap-second rollover and don't raise. Use only
    # the cases that DO raise.
    bad_dates = %w[
      20261301T120000Z
      20260528T250000Z
    ]
    bad_dates.each do |bad_date|
      url = "https://x/y?X-Amz-Date=#{bad_date}&X-Amz-Expires=900&X-Amz-Signature=abc"
      assert_nil Parse::File.parse_presigned_expiry(url),
                 "#{bad_date.inspect} must return nil (Time.utc raises on it)"
    end
  end

  def test_attributes_hydration_with_corrupt_date_does_not_crash
    # End-to-end: a row whose presigned URL carries an out-of-range
    # X-Amz-Date (month 13) must hydrate cleanly with
    # @presigned_url_expires_at == nil, NOT crash with ArgumentError.
    file = Parse::File.new(name: "doc.pdf", contents: nil)
    file.attributes = {
      "name" => "doc.pdf",
      "url"  => "https://bucket.s3.amazonaws.com/doc.pdf?" \
                "X-Amz-Date=20261301T120000Z&X-Amz-Expires=900&X-Amz-Signature=abc",
    }
    assert_equal "https://bucket.s3.amazonaws.com/doc.pdf", file.url
    refute_nil file.presigned_url
    assert_nil file.presigned_url_expires_at,
               "out-of-range date must produce nil expiry rather than crash"
  end

  # ------------------------------------------------------------------
  # url_signature_param? is case-insensitive (misbehaving-CDN defense)
  # ------------------------------------------------------------------

  def test_url_signature_param_predicate_is_case_insensitive
    # AWS canonical capitalization is what SIGNATURE_QUERY_PARAMS
    # carries; misbehaving CDNs / reverse proxies that lowercase
    # query param names must not bypass detection (asymmetry with
    # the case-insensitive `log_filter` regex was a review finding).
    %w[
      ?x-amz-signature=abc
      ?X-AMZ-SIGNATURE=abc
      ?aWSaCCESSkEYiD=abc
      ?KEY-PAIR-ID=abc
    ].each do |suffix|
      url = "https://bucket.s3.amazonaws.com/doc.pdf#{suffix}"
      assert Parse::File.url_signature_param?(url),
             "case-insensitive: #{url} must be flagged"
    end
  end

  def test_normalization_strips_lowercase_signature_too
    # Wire-up assertion: lowercase signature triggers the full
    # strip + stash path.
    file = Parse::File.new("doc.pdf")
    file.url = "https://bucket.s3.amazonaws.com/doc.pdf?x-amz-signature=abc"
    assert_equal "https://bucket.s3.amazonaws.com/doc.pdf", file.url
    refute_nil file.presigned_url
  end

  # ------------------------------------------------------------------
  # SignedUrlError class is still DEFINED (Wave A class stays for
  # downstream-app use in strict mode), just not raised by the
  # built-in writers.
  # ------------------------------------------------------------------

  def test_signed_url_error_class_is_still_defined
    assert defined?(Parse::File::SignedUrlError)
    assert Parse::File::SignedUrlError < Parse::Error
  end

  # ------------------------------------------------------------------
  # url_signature_param? class method (still public)
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
    refute Parse::File.url_signature_param?("https://x.com/api?signature_pad_id=123")
    refute Parse::File.url_signature_param?("https://x.com/api?policy=accept")
  end

  private

  # Minitest's assert_raises requires the exception to fire. Inverse
  # helper for "must not raise this".
  def refute_raises(klass)
    yield
    pass
  rescue klass => e
    flunk "expected NOT to raise #{klass}, but got: #{e.message}"
  end
end
