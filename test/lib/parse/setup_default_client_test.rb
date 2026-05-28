require_relative "../../test_helper"

class TestSetupDefaultClient < Minitest::Test
  def setup
    @opts_a = {
      server_url: "http://localhost:1337/parse",
      app_id: "app_a",
      api_key: "key_a",
    }
    @opts_b = {
      server_url: "http://other.example:1337/parse",
      app_id: "app_b",
      api_key: "key_b",
    }
    Parse::Client.clients.clear
  end

  def teardown
    Parse::Client.clients.clear
  end

  # Regression: Parse.setup used to call Parse::Client.new directly, which
  # registers the default client via `@clients[:default] ||= self`. Once a
  # default was set, every subsequent Parse.setup built a new client and
  # immediately discarded it — the second call silently no-op'd while
  # Parse::Client.setup (which uses `=`) overwrote.
  def test_parse_setup_overwrites_default_client_on_repeated_calls
    Parse.setup(@opts_a)
    first = Parse::Client.client(:default)
    assert_equal "app_a", first.application_id

    Parse.setup(@opts_b)
    second = Parse::Client.client(:default)

    assert_equal "app_b", second.application_id,
      "Parse.setup must replace the :default client on a second call"
    refute_equal first.object_id, second.object_id,
      "Parse.setup must register a new client instance, not reuse the first"
  end

  # Parse.setup and Parse::Client.setup are documented as equivalent. They
  # must register the default client the same way.
  def test_parse_setup_and_client_setup_register_default_identically
    Parse.setup(@opts_a)
    via_module = Parse::Client.client(:default).application_id

    Parse::Client.clients.clear

    Parse::Client.setup(@opts_a)
    via_class = Parse::Client.client(:default).application_id

    assert_equal via_module, via_class
    assert_equal "app_a", via_module
  end

  # Ad-hoc Parse::Client.new must NOT hijack the :default slot when one is
  # already registered — that's the reason `||=` exists in #initialize and
  # the reason Parse.setup has to go through Parse::Client.setup to be able
  # to overwrite.
  def test_parse_client_new_does_not_replace_existing_default
    Parse.setup(@opts_a)
    primary = Parse::Client.client(:default)

    secondary = Parse::Client.new(@opts_b)
    refute_equal secondary.object_id, Parse::Client.client(:default).object_id,
      "Parse::Client.new must not overwrite an already-registered :default client"
    assert_equal primary.object_id, Parse::Client.client(:default).object_id
  end
end
