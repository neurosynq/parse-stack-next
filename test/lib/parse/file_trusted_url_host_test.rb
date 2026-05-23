# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the Parse::File URL host allowlist on hydration.
#
# Without this gate, a Parse::File hydrated from a JSON row (e.g. a
# user-supplied avatar field that the SDK trusts) can carry a URL
# pointing at any host on the Internet. Downstream code rendering
# `file.url` in `<img src="…">` becomes a stored-phishing /
# SVG-XSS / open-redirect surface. The allowlist limits which hosts
# the SDK will accept on hydration.
class TestFileTrustedUrlHost < Minitest::Test
  def setup
    @original_trusted_hosts = Parse::File.instance_variable_get(:@trusted_url_hosts)
    @original_policy        = Parse::File.instance_variable_get(:@untrusted_url_policy)
    @original_warned        = Parse::File.instance_variable_get(:@warned_untrusted_hosts)
    Parse::File.instance_variable_set(:@trusted_url_hosts, nil)
    Parse::File.instance_variable_set(:@untrusted_url_policy, nil)
    Parse::File.instance_variable_set(:@warned_untrusted_hosts, nil)
  end

  def teardown
    Parse::File.instance_variable_set(:@trusted_url_hosts, @original_trusted_hosts)
    Parse::File.instance_variable_set(:@untrusted_url_policy, @original_policy)
    Parse::File.instance_variable_set(:@warned_untrusted_hosts, @original_warned)
  end

  def test_default_policy_is_warn_and_accepts_untrusted_host
    file = Parse::File.new(name: "avatar.png", contents: nil)
    _out, err = capture_io { file.attributes = { "name" => "avatar.png", "url" => "https://attacker.example.com/p.png" } }
    assert_equal "https://attacker.example.com/p.png", file.url
    assert_match(/Untrusted URL host/, err)
  end

  def test_strip_policy_blanks_untrusted_url
    Parse::File.untrusted_url_policy = :strip
    file = Parse::File.new(name: "a.png", contents: nil)
    capture_io do
      file.attributes = { "name" => "a.png", "url" => "https://attacker.example.com/a.png" }
    end
    assert_nil file.url
  end

  def test_raise_policy_refuses_untrusted_url
    Parse::File.untrusted_url_policy = :raise
    file = Parse::File.new(name: "a.png", contents: nil)
    err = assert_raises(Parse::File::UntrustedHostError) do
      file.attributes = { "name" => "a.png", "url" => "https://attacker.example.com/a.png" }
    end
    assert_match(/attacker\.example\.com/, err.message)
  end

  def test_legacy_tfss_filename_accepted_on_any_host
    Parse::File.untrusted_url_policy = :raise
    file = Parse::File.new(name: "tfss-abcd1234-1234-1234-1234-1234567890ab-x.png", contents: nil)
    # Even on attacker host — the tfss- name carries its own integrity contract.
    file.attributes = {
      "name" => "tfss-abcd1234-1234-1234-1234-1234567890ab-x.png",
      "url"  => "https://cdn.thirdparty.example/tfss-abcd1234-1234-1234-1234-1234567890ab-x.png",
    }
    assert_match(%r{cdn\.thirdparty\.example}, file.url)
  end

  def test_files_parsetfss_com_is_default_trusted
    Parse::File.untrusted_url_policy = :raise
    file = Parse::File.new(name: "a.png", contents: nil)
    file.attributes = { "name" => "a.png", "url" => "https://files.parsetfss.com/abc/a.png" }
    assert_match %r{files\.parsetfss\.com}, file.url
  end

  def test_custom_trusted_host_allowed
    Parse::File.untrusted_url_policy = :raise
    Parse::File.trusted_url_hosts = ["cdn.example.com"]
    file = Parse::File.new(name: "a.png", contents: nil)
    file.attributes = { "name" => "a.png", "url" => "https://cdn.example.com/a.png" }
    assert_match %r{cdn\.example\.com}, file.url
  end

  def test_wildcard_trusted_host_matches_subdomains
    Parse::File.untrusted_url_policy = :raise
    Parse::File.trusted_url_hosts = [".example.com"]
    file = Parse::File.new(name: "a.png", contents: nil)
    file.attributes = { "name" => "a.png", "url" => "https://files.example.com/a.png" }
    assert_match %r{files\.example\.com}, file.url

    file2 = Parse::File.new(name: "b.png", contents: nil)
    file2.attributes = { "name" => "b.png", "url" => "https://example.com/b.png" }
    assert_match %r{://example\.com}, file2.url
  end

  def test_wildcard_does_not_match_unrelated_host
    Parse::File.untrusted_url_policy = :raise
    Parse::File.trusted_url_hosts = [".example.com"]
    file = Parse::File.new(name: "a.png", contents: nil)
    assert_raises(Parse::File::UntrustedHostError) do
      file.attributes = { "name" => "a.png", "url" => "https://attacker-example.com/a.png" }
    end
  end

  def test_url_setter_runs_same_validation
    Parse::File.untrusted_url_policy = :raise
    file = Parse::File.new(name: "a.png", contents: nil)
    assert_raises(Parse::File::UntrustedHostError) do
      file.url = "https://attacker.example.com/a.png"
    end
  end

  def test_clearing_url_with_nil_passes_through
    file = Parse::File.new(name: "a.png", contents: nil)
    file.url = nil
    assert_nil file.url
  end

  def test_warning_is_deduplicated_per_host
    file1 = Parse::File.new(name: "a.png", contents: nil)
    file2 = Parse::File.new(name: "b.png", contents: nil)
    _out, err = capture_io do
      file1.attributes = { "name" => "a.png", "url" => "https://attacker.example.com/a.png" }
      file2.attributes = { "name" => "b.png", "url" => "https://attacker.example.com/b.png" }
    end
    # Only ONE warning for the same host
    assert_equal 1, err.scan(/Untrusted URL host/).size
  end
end
