# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for Parse::Webhooks::Registration URL validation
# (NEW-EXT-7: register_webhook! must refuse SSRF-friendly destinations).
class WebhookRegistrationTest < Minitest::Test
  def setup
    @registry = Class.new do
      extend Parse::Webhooks::Registration
    end
  end

  def test_assert_webhook_url_safe_accepts_public_https
    # Resolv returns a public address for this; assert no raise.
    Resolv.stub(:getaddresses, ["93.184.216.34"]) do
      assert_equal "https://hooks.example.com/", @registry.assert_webhook_url_safe!("https://hooks.example.com/")
    end
  end

  def test_assert_webhook_url_safe_rejects_blank
    assert_raises(ArgumentError) { @registry.assert_webhook_url_safe!(nil) }
    assert_raises(ArgumentError) { @registry.assert_webhook_url_safe!("") }
  end

  def test_assert_webhook_url_safe_rejects_non_http_scheme
    assert_raises(ArgumentError) { @registry.assert_webhook_url_safe!("file:///etc/passwd") }
    assert_raises(ArgumentError) { @registry.assert_webhook_url_safe!("gopher://example.com/") }
    assert_raises(ArgumentError) { @registry.assert_webhook_url_safe!("javascript:alert(1)") }
  end

  def test_assert_webhook_url_safe_rejects_userinfo
    Resolv.stub(:getaddresses, ["93.184.216.34"]) do
      assert_raises(ArgumentError) do
        @registry.assert_webhook_url_safe!("https://user:pw@hooks.example.com/")
      end
    end
  end

  def test_assert_webhook_url_safe_rejects_loopback
    Resolv.stub(:getaddresses, ["127.0.0.1"]) do
      err = assert_raises(ArgumentError) do
        @registry.assert_webhook_url_safe!("https://localhost/")
      end
      assert_match(/private\/internal/, err.message)
    end
  end

  def test_assert_webhook_url_safe_rejects_rfc1918
    Resolv.stub(:getaddresses, ["10.0.0.5"]) do
      assert_raises(ArgumentError) do
        @registry.assert_webhook_url_safe!("https://internal.example.com/")
      end
    end
    Resolv.stub(:getaddresses, ["192.168.1.1"]) do
      assert_raises(ArgumentError) do
        @registry.assert_webhook_url_safe!("https://router.local/")
      end
    end
    Resolv.stub(:getaddresses, ["172.16.0.5"]) do
      assert_raises(ArgumentError) do
        @registry.assert_webhook_url_safe!("https://corp.example.com/")
      end
    end
  end

  def test_assert_webhook_url_safe_rejects_aws_metadata
    # 169.254.169.254 — the canonical AWS / GCP / Azure metadata endpoint
    err = assert_raises(ArgumentError) do
      @registry.assert_webhook_url_safe!("http://169.254.169.254/latest/meta-data/")
    end
    assert_match(/private\/internal/, err.message)
  end

  def test_assert_webhook_url_safe_rejects_alibaba_metadata
    err = assert_raises(ArgumentError) do
      @registry.assert_webhook_url_safe!("http://100.100.100.200/latest/meta-data/")
    end
    assert_match(/private\/internal/, err.message)
  end

  def test_assert_webhook_url_safe_rejects_unresolvable_host
    Resolv.stub(:getaddresses, []) do
      err = assert_raises(ArgumentError) do
        @registry.assert_webhook_url_safe!("https://nx.invalid/")
      end
      assert_match(/could not be resolved/, err.message)
    end
  end

  def test_register_webhook_refuses_metadata_url
    # Even on the public entry point, SSRF is refused before any HTTP
    # call to Parse Server. We rely on assert_webhook_url_safe! firing
    # before client.create_function/create_trigger is invoked.
    assert_raises(ArgumentError) do
      @registry.register_webhook!(:function, "noop",
                                  "http://169.254.169.254/latest/meta-data/")
    end
  end

  def test_register_functions_refuses_loopback_endpoint
    Resolv.stub(:getaddresses, ["127.0.0.1"]) do
      assert_raises(ArgumentError) do
        @registry.register_functions!("http://localhost:8080/hooks/")
      end
    end
  end

  def test_register_triggers_refuses_loopback_endpoint
    Resolv.stub(:getaddresses, ["127.0.0.1"]) do
      assert_raises(ArgumentError) do
        @registry.register_triggers!("http://localhost:8080/hooks/")
      end
    end
  end
end
