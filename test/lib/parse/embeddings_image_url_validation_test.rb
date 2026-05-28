# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"
require "parse/model/file"

# Unit tests for the v5.1 image-URL forwarding surface added to
# Parse::Embeddings: the sentinel-gated trust_provider_url_fetch
# toggle, the allowed_image_hosts allowlist, and the validate_image_url!
# validator that ties them together with Parse::File's SSRF primitives.
class EmbeddingsImageURLValidationTest < Minitest::Test
  SENTINEL = "PROVIDER_EGRESS_VERIFIED"

  def setup
    Parse::Embeddings.reset!
    # Save Parse::File state — assert_host_allowed! reads
    # allowed_remote_ports and allowed_remote_hosts.
    @prior_ports = Parse::File.allowed_remote_ports.dup
    @prior_hosts = Parse::File.allowed_remote_hosts.dup
  end

  def teardown
    Parse::Embeddings.reset!
    Parse::File.allowed_remote_ports = @prior_ports
    Parse::File.allowed_remote_hosts = @prior_hosts
    teardown_stubbed_resolve
  end

  # ---- trust_provider_url_fetch sentinel --------------------------------

  def test_sentinel_default_is_off
    refute Parse::Embeddings.trust_provider_url_fetch?
  end

  def test_assigning_exact_sentinel_enables_forwarding
    Parse::Embeddings.trust_provider_url_fetch = SENTINEL
    assert Parse::Embeddings.trust_provider_url_fetch?
  end

  def test_assigning_true_is_refused
    err = assert_raises(Parse::Embeddings::ConfirmationRequired) do
      Parse::Embeddings.trust_provider_url_fetch = true
    end
    assert_match(/exact sentinel/, err.message)
    assert_match(/PROVIDER_EGRESS_VERIFIED/, err.message)
    refute Parse::Embeddings.trust_provider_url_fetch?
  end

  def test_assigning_truthy_string_is_refused
    assert_raises(Parse::Embeddings::ConfirmationRequired) do
      Parse::Embeddings.trust_provider_url_fetch = "true"
    end
    assert_raises(Parse::Embeddings::ConfirmationRequired) do
      Parse::Embeddings.trust_provider_url_fetch = "PROVIDER_EGRESS_VERIFIED!"
    end
    assert_raises(Parse::Embeddings::ConfirmationRequired) do
      Parse::Embeddings.trust_provider_url_fetch = 1
    end
    refute Parse::Embeddings.trust_provider_url_fetch?
  end

  def test_nil_disables_forwarding
    Parse::Embeddings.trust_provider_url_fetch = SENTINEL
    assert Parse::Embeddings.trust_provider_url_fetch?
    Parse::Embeddings.trust_provider_url_fetch = nil
    refute Parse::Embeddings.trust_provider_url_fetch?
  end

  def test_reset_clears_sentinel
    Parse::Embeddings.trust_provider_url_fetch = SENTINEL
    Parse::Embeddings.reset!
    refute Parse::Embeddings.trust_provider_url_fetch?
  end

  # ---- allowed_image_hosts allowlist -----------------------------------

  def test_allowed_image_hosts_default_is_empty
    assert_equal [], Parse::Embeddings.allowed_image_hosts
  end

  def test_setting_allowed_image_hosts_round_trips
    Parse::Embeddings.allowed_image_hosts = ["cdn.example.com", ".cloudfront.net"]
    assert_equal ["cdn.example.com", ".cloudfront.net"], Parse::Embeddings.allowed_image_hosts
  end

  def test_setting_allowed_image_hosts_freezes_array
    Parse::Embeddings.allowed_image_hosts = ["x.example.com"]
    assert Parse::Embeddings.allowed_image_hosts.frozen?
  end

  def test_setting_allowed_image_hosts_rejects_non_array
    assert_raises(ArgumentError) { Parse::Embeddings.allowed_image_hosts = "x.example.com" }
    assert_raises(ArgumentError) { Parse::Embeddings.allowed_image_hosts = nil }
  end

  def test_setting_allowed_image_hosts_rejects_non_string_entries
    assert_raises(ArgumentError) { Parse::Embeddings.allowed_image_hosts = [:symbol] }
    assert_raises(ArgumentError) { Parse::Embeddings.allowed_image_hosts = [""] }
  end

  def test_reset_clears_allowed_image_hosts
    Parse::Embeddings.allowed_image_hosts = ["x.example.com"]
    Parse::Embeddings.reset!
    assert_equal [], Parse::Embeddings.allowed_image_hosts
  end

  # ---- validate_image_url! — sentinel gate -----------------------------

  def test_validate_raises_confirmation_required_when_sentinel_off
    Parse::Embeddings.allowed_image_hosts = ["cdn.example.com"]
    err = assert_raises(Parse::Embeddings::ConfirmationRequired) do
      Parse::Embeddings.validate_image_url!("https://cdn.example.com/x.jpg")
    end
    assert_match(/forwarding is disabled/, err.message)
  end

  # ---- validate_image_url! — scheme/userinfo/port ---------------------

  def test_validate_canonicalizes_and_returns_url_on_success
    enable_with_hosts(["1.1.1.1"])
    out = Parse::Embeddings.validate_image_url!("https://1.1.1.1/path/to/image.jpg?q=1")
    assert_equal "https://1.1.1.1/path/to/image.jpg?q=1", out
  end

  def test_validate_rejects_non_string
    enable_with_hosts(["cdn.example.com"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!(nil)
    end
    assert_equal :parse, err.reason
  end

  def test_validate_rejects_invalid_url
    enable_with_hosts(["cdn.example.com"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://[not a url")
    end
    assert_equal :parse, err.reason
  end

  def test_validate_refuses_http_by_default
    enable_with_hosts(["1.1.1.1"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("http://1.1.1.1/img.jpg")
    end
    assert_equal :scheme, err.reason
  end

  def test_validate_allows_http_with_allow_insecure
    enable_with_hosts(["1.1.1.1"])
    out = Parse::Embeddings.validate_image_url!("http://1.1.1.1/img.jpg", allow_insecure: true)
    assert_equal "http://1.1.1.1/img.jpg", out
  end

  def test_validate_refuses_non_http_schemes_even_with_allow_insecure
    enable_with_hosts(["1.1.1.1"])
    %w[ftp file gopher data javascript].each do |scheme|
      err = assert_raises(Parse::Embeddings::InvalidImageURL) do
        Parse::Embeddings.validate_image_url!("#{scheme}://1.1.1.1/x", allow_insecure: true)
      end
      assert_equal :scheme, err.reason, "scheme=#{scheme}"
    end
  end

  def test_validate_refuses_userinfo
    enable_with_hosts(["1.1.1.1"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://user:pass@1.1.1.1/img.jpg")
    end
    assert_equal :userinfo, err.reason
    # The thrown error must not echo the password back into the message.
    refute_match(/pass/, err.message)
  end

  def test_validate_refuses_non_allowlisted_port
    enable_with_hosts(["1.1.1.1"])
    # Parse::File.allowed_remote_ports defaults to [80, 443].
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://1.1.1.1:6379/img.jpg")
    end
    assert_equal :port, err.reason
  end

  # ---- validate_image_url! — CIDR (private IPs) ------------------------

  def test_validate_refuses_loopback_ipv4
    enable_with_hosts(["127.0.0.1"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://127.0.0.1/img.jpg")
    end
    assert_equal :host_blocked, err.reason
  end

  def test_validate_refuses_rfc1918
    enable_with_hosts(["10.0.0.1", "192.168.1.1", "172.16.0.1"])
    %w[10.0.0.1 192.168.1.1 172.16.0.1].each do |ip|
      err = assert_raises(Parse::Embeddings::InvalidImageURL) do
        Parse::Embeddings.validate_image_url!("https://#{ip}/x")
      end
      assert_equal :host_blocked, err.reason, "ip=#{ip}"
    end
  end

  def test_validate_refuses_link_local
    enable_with_hosts(["169.254.169.254"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://169.254.169.254/latest/meta-data/")
    end
    assert_equal :host_blocked, err.reason
  end

  # ---- validate_image_url! — obfuscated IP literals -------------------

  def test_validate_refuses_decimal_ipv4_literal
    # 2130706433 == 127.0.0.1. Old code path would fall to a
    # resolution failure (:parse); new code path tags as :host_blocked
    # so operator logs distinguish typos from SSRF attempts.
    enable_with_hosts(["1.1.1.1"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://2130706433/x")
    end
    assert_equal :host_blocked, err.reason
    assert_match(/obfuscated.*IP literal/, err.message)
  end

  def test_validate_refuses_ipv4_with_leading_zero_octets
    # 0177.0.0.1 — octal-style leading zero, parses as canonical 0x7f.0.0.1
    # on some stacks (curl, glibc). Reject these to avoid host confusion.
    enable_with_hosts(["1.1.1.1"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://0177.0.0.1/x")
    end
    assert_equal :host_blocked, err.reason
  end

  def test_validate_refuses_ipv4_octet_over_255
    enable_with_hosts(["1.1.1.1"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://999.1.1.1/x")
    end
    assert_equal :host_blocked, err.reason
  end

  def test_validate_canonical_ipv4_passes_obfuscation_check
    # Sanity check that ordinary IPv4 still works through the new
    # ip_shaped_but_not_canonical? gate.
    enable_with_hosts(["1.1.1.1"])
    out = Parse::Embeddings.validate_image_url!("https://1.1.1.1/x")
    assert_equal "https://1.1.1.1/x", out
  end

  # Round-2 audit MEDIUM #1: prior helper let `0x7f.0.0.1` slip past
  # the `[a-zA-Z]` early-out because of the `x`. Pin the fix.
  def test_validate_refuses_hex_ipv4_literal
    enable_with_hosts(["1.1.1.1"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://0x7f.0.0.1/x")
    end
    assert_equal :host_blocked, err.reason
  end

  def test_validate_refuses_hex_ipv4_uppercase_x
    enable_with_hosts(["1.1.1.1"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://0X7F.0.0.1/x")
    end
    assert_equal :host_blocked, err.reason
  end

  def test_validate_refuses_ipv4_short_form
    # `127.1` is 127.0.0.1 in dotted-quad short-form. inet_aton-style
    # resolvers expand it; some Ruby stacks do not. Either way, refuse.
    enable_with_hosts(["1.1.1.1"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://127.1/x")
    end
    assert_equal :host_blocked, err.reason
  end

  def test_validate_accepts_alpha_leading_digit_hostname
    # `9-cdn.example.com` is a legitimate RFC 1123 hostname. The
    # numeric-rejection guard must not catch it.
    stub_resolve("9-cdn.example.com", "1.1.1.1")
    enable_with_hosts(["9-cdn.example.com"])
    out = Parse::Embeddings.validate_image_url!("https://9-cdn.example.com/x")
    assert_equal "https://9-cdn.example.com/x", out
  end

  # Round-2 audit LOW #3: allowlist check runs BEFORE the DNS hop,
  # so a request to a non-allowlisted host should never resolve.
  # Pin the ordering by checking that Parse::File.resolve_addresses
  # is not called when the allowlist rejects the host.
  def test_validate_allowlist_runs_before_dns_resolution
    enable_with_hosts(["cdn.example.com"])  # does NOT include "evil.example.com"
    resolution_attempted = false
    Parse::File.singleton_class.class_eval do
      alias_method :_orig_resolve_addresses_v2, :resolve_addresses unless method_defined?(:_orig_resolve_addresses_v2)
    end
    Parse::File.define_singleton_method(:resolve_addresses) do |h|
      resolution_attempted = true
      _orig_resolve_addresses_v2(h)
    end
    begin
      assert_raises(Parse::Embeddings::InvalidImageURL) do
        Parse::Embeddings.validate_image_url!("https://evil.example.com/x")
      end
      refute resolution_attempted,
        "Allowlist string match must run BEFORE the resolver — non-allowlisted hosts should never trigger DNS"
    ensure
      Parse::File.singleton_class.class_eval do
        alias_method :resolve_addresses, :_orig_resolve_addresses_v2
      end
    end
  end

  # ---- validate_image_url! — host allowlist ----------------------------

  def test_validate_refuses_when_allowlist_empty
    Parse::Embeddings.trust_provider_url_fetch = SENTINEL
    # No allowed_image_hosts set.
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://1.1.1.1/x")
    end
    assert_equal :host_not_allowlisted, err.reason
    assert_match(/empty/, err.message)
  end

  def test_validate_refuses_host_not_in_allowlist
    enable_with_hosts(["other.example.com"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://1.1.1.1/x")
    end
    assert_equal :host_not_allowlisted, err.reason
  end

  def test_validate_exact_host_match
    enable_with_hosts(["1.1.1.1"])
    Parse::Embeddings.validate_image_url!("https://1.1.1.1/x")
  end

  def test_validate_suffix_match_with_dot_prefix
    # Stub resolution so hostname lookups don't hit real DNS.
    stub_resolve("foo.cloudfront.net", "1.1.1.1")
    enable_with_hosts([".cloudfront.net"])
    Parse::Embeddings.validate_image_url!("https://foo.cloudfront.net/img.jpg")
  end

  def test_validate_suffix_pattern_matches_apex
    stub_resolve("cloudfront.net", "1.1.1.1")
    enable_with_hosts([".cloudfront.net"])
    Parse::Embeddings.validate_image_url!("https://cloudfront.net/img.jpg")
  end

  def test_validate_suffix_pattern_does_not_match_sibling
    stub_resolve("evilcloudfront.net", "1.1.1.1")
    enable_with_hosts([".cloudfront.net"])
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Embeddings.validate_image_url!("https://evilcloudfront.net/img.jpg")
    end
    assert_equal :host_not_allowlisted, err.reason
  end

  def test_validate_host_match_is_case_insensitive
    enable_with_hosts(["1.1.1.1"])
    Parse::Embeddings.validate_image_url!("https://1.1.1.1/x")
    # And for hostnames:
    stub_resolve("CDN.Example.COM", "1.1.1.1")
    Parse::Embeddings.allowed_image_hosts = ["cdn.example.com"]
    Parse::Embeddings.validate_image_url!("https://CDN.Example.COM/x")
  end

  private

  def enable_with_hosts(hosts)
    Parse::Embeddings.trust_provider_url_fetch = SENTINEL
    Parse::Embeddings.allowed_image_hosts = hosts
  end

  # Bypass Resolv for hostname tests — DNS in CI is non-deterministic.
  # Stub Parse::File.resolve_addresses to return a fixed IPAddr for the
  # given host. The :host_blocked check then runs against that IP.
  def stub_resolve(host, ip)
    addr = IPAddr.new(ip)
    Parse::File.singleton_class.class_eval do
      alias_method :_orig_resolve_addresses, :resolve_addresses unless method_defined?(:_orig_resolve_addresses)
    end
    Parse::File.define_singleton_method(:resolve_addresses) do |h|
      h.casecmp(host).zero? ? [addr] : _orig_resolve_addresses(h)
    end
    # Restore after the test via teardown hook
    @stubbed_resolve = true
  end

  def teardown_stubbed_resolve
    return unless @stubbed_resolve
    Parse::File.singleton_class.class_eval do
      alias_method :resolve_addresses, :_orig_resolve_addresses if method_defined?(:_orig_resolve_addresses)
    end
    @stubbed_resolve = false
  end
end
