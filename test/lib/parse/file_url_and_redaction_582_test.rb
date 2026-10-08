# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# 5.8.2 review follow-ups:
#   - Parse::File hydration normalizes a URL the way a browser parses it
#     (tab/CR/LF removed, C0 controls and spaces stripped), checks
#     scheme-relative values against the allowlist, and treats non-http(s)
#     schemes as untrusted. The tfss- carve-out can be turned off.
#   - Response#to_s redacts the request line on errors and credential text
#     inside string values; header-shaped credential text is redacted.
class FileUrlBrowserParseTest < Minitest::Test
  def setup
    @prior_hosts = Parse::File.trusted_url_hosts.dup
    @prior_policy = Parse::File.untrusted_url_policy
    @prior_tfss = Parse::File.instance_variable_get(:@trust_legacy_tfss_on_any_host)
    @prior_warned = Parse::File.instance_variable_get(:@warned_untrusted_hosts)
    Parse::File.trusted_url_hosts = ["files.example.com"]
    Parse::File.untrusted_url_policy = :raise
  end

  def teardown
    Parse::File.trusted_url_hosts = @prior_hosts
    Parse::File.untrusted_url_policy = @prior_policy
    Parse::File.instance_variable_set(:@trust_legacy_tfss_on_any_host, @prior_tfss)
    Parse::File.instance_variable_set(:@warned_untrusted_hosts, @prior_warned)
  end

  def hydrate(url, name: "a.png")
    Parse::File.new({ "__type" => "File", "name" => name, "url" => url })
  end

  REFUSED = [
    "//evil.com/a.png",
    "\\\\evil.com/a.png",
    "/\\evil.com/a.png",
    "\\/evil.com/a.png",
    "\x01https://evil.com/a.png",
    "\x00 https://evil.com/a.png",
    "ht\ttps://evil.com/a.png",
    "https://ev\nil.com/a.png",
    "javascript:alert(1)",
    "JavaScript:alert(1)",
    "data:image/svg+xml;base64,PHN2Zz4=",
    "vbscript:msgbox",
    "file:///etc/passwd",
  ].freeze

  def test_browser_resolved_foreign_urls_raise
    REFUSED.each do |url|
      assert_raises(Parse::File::UntrustedHostError, "expected #{url.inspect} to be refused") { hydrate(url) }
    end
  end

  def test_browser_resolved_foreign_urls_are_stripped
    Parse::File.untrusted_url_policy = :strip
    REFUSED.each do |url|
      file = nil
      capture_io { file = hydrate(url) }
      assert_nil file.url, "expected #{url.inspect} to be stripped"
    end
  end

  def test_trusted_and_relative_values_still_pass
    assert_equal "https://files.example.com/a.png", hydrate("https://files.example.com/a.png").url
    assert_equal "//files.example.com/a.png", hydrate("//files.example.com/a.png").url
    assert_equal "\thttps://files.example.com/a.png", hydrate("\thttps://files.example.com/a.png").url
    assert_equal "a.png", hydrate("a.png").url
    assert_equal "/files/a.png", hydrate("/files/a.png").url
    assert_equal "files/a.png", hydrate("files/a.png").url
  end

  def test_warn_policy_accepts_and_warns
    Parse::File.untrusted_url_policy = :warn
    Parse::File.instance_variable_set(:@warned_untrusted_hosts, {})
    file = nil
    _out, err = capture_io { file = hydrate("javascript:alert(1)") }
    assert_equal "javascript:alert(1)", file.url
    assert_match(/javascript: URL/, err)
  end

  def test_tfss_carve_out_is_on_by_default
    tfss = "tfss-abcd1234-1234-1234-1234-1234567890ab-x.png"
    file = hydrate("https://cdn.thirdparty.example/#{tfss}", name: tfss)
    assert_equal "https://cdn.thirdparty.example/#{tfss}", file.url
  end

  def test_tfss_carve_out_can_be_turned_off
    Parse::File.trust_legacy_tfss_on_any_host = false
    tfss = "tfss-abcd1234-1234-1234-1234-1234567890ab-x.png"
    assert_raises(Parse::File::UntrustedHostError) do
      hydrate("https://cdn.thirdparty.example/#{tfss}", name: tfss)
    end
    Parse::File.trusted_url_hosts = ["files.example.com", "files.parsetfss.com"]
    assert_equal "https://files.parsetfss.com/#{tfss}",
                 hydrate("https://files.parsetfss.com/#{tfss}", name: tfss).url
  end
end

class ResponseAndHeaderRedactionTest < Minitest::Test
  BB = Parse::Middleware::BodyBuilder

  def test_header_shaped_credentials_are_redacted
    text = "X-Parse-Master-Key: mk1 X-Parse-REST-API-Key: rk1 x-parse-session-token=r:abc " \
           "X-Parse-Javascript-Key: jk1 X-Parse-Client-Key: ck1 X-Parse-Webhook-Key: wk1 " \
           "Authorization: Bearer tok.en Authorization: Basic Zm9vOmJhcg=="
    out = BB.redact(text)
    %w[mk1 rk1 r:abc jk1 ck1 wk1 tok.en Zm9vOmJhcg==].each do |secret|
      refute_includes out, secret, "#{secret} should be redacted"
    end
    assert_includes out, "Authorization: Bearer [FILTERED]"
    assert_includes out, "X-Parse-Master-Key: [FILTERED]"
  end

  def test_redaction_is_idempotent
    once = BB.redact("X-Parse-Master-Key: mk1 password=hunter2")
    assert_equal once, BB.redact(once)
  end

  def test_to_s_filters_credential_text_inside_values
    resp = Parse::Response.new({ "objectId" => "a1",
                                 "note" => "password=hunter2 and X-Parse-Master-Key: mk1" })
    out = resp.to_s
    refute_includes out, "hunter2"
    refute_includes out, "mk1"
    assert_includes out, "a1"
    assert_equal "password=hunter2 and X-Parse-Master-Key: mk1", resp.result["note"]
  end

  def test_error_to_s_redacts_the_request_line
    resp = Parse::Response.new({ "code" => 101, "error" => "Object not found." })
    resp.request = "GET /parse/login?username=u&password=hunter2"
    out = resp.to_s
    refute_includes out, "hunter2"
    assert_includes out, "[E-101]"
  end

  # Text patterns run on string values before JSON encoding, so escaped
  # quotes inside a value neither defeat them nor corrupt the output.
  def test_to_s_redacts_quoted_credentials_and_stays_valid_json
    r = Parse::Response.new({
      "msg" => %q{password="TEST_SECRET"},
      "h" => %q{"Authorization": "Bearer TOK123"},
      "m" => %q{X-Parse-Master-Key: "MK999"},
      "s" => %q{password='SQ1' ok},
      "arr" => [{ "note" => %q{secret="S2"} }, [%q{token="T3"}]],
    })
    out = r.to_s
    JSON.parse(out)
    %w[TEST_SECRET TOK123 MK999 SQ1 S2 T3].each { |secret| refute_includes out, secret }
    assert_equal %q{password="TEST_SECRET"}, r.result["msg"], "#result stays raw"
  end

  def test_log_redaction_of_json_bodies_handles_quoted_values
    out = Parse::Middleware::BodyBuilder.redact({ "note" => %q{password="LOGSECRET"} }.to_json)
    JSON.parse(out)
    refute_includes out, "LOGSECRET"
  end


  # A quoted value is redacted whole, including spaces inside it and a
  # quoted value after an auth scheme.
  def test_quoted_values_are_redacted_whole
    {
      %q{Authorization: Bearer "TEST_SECRET"} => %q{Authorization: Bearer "[FILTERED]"},
      %q{password="first SECOND_SECRET"} => %q{password="[FILTERED]"},
      %q{password='a b' next} => %q{password='[FILTERED]' next},
      %q{X-Parse-Master-Key: "TEST_SECRET"} => %q{X-Parse-Master-Key: "[FILTERED]"},
      %q{Authorization: "Bearer x y"} => %q{Authorization: "[FILTERED]"},
      %q{token: "a\"b c" tail} => %q{token: "[FILTERED]" tail},
      %q{password=hunter2&user=x} => %q{password=[FILTERED]&user=x},
    }.each do |input, expected|
      assert_equal expected, BB.redact_patterns(input), input
    end
  end

  def test_to_s_redacts_quoted_values_with_spaces_and_schemes
    r = Parse::Response.new({ "message" => %q{Authorization: Bearer "TEST_SECRET" and password="first SECOND_SECRET"} })
    out = r.to_s
    refute_match(/TEST_SECRET|SECOND_SECRET/, out)
    JSON.parse(out)
  end

  def test_redaction_is_idempotent_on_quoted_placeholders
    once = BB.redact_patterns(%q{{"password":"secret"}})
    assert_equal once, BB.redact_patterns(once)
  end

end
