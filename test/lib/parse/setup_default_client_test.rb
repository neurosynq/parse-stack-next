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

  # Pin the return value: Parse.setup must return the registered client,
  # not an orphan. Under the pre-fix code Parse.setup(@opts_b) returned
  # the newly-constructed but never-registered Parse::Client instance
  # (because `||=` had kept the first one in the slot). Callers that did
  # `client = Parse.setup(...)` and reused it would have ended up with
  # a client that was NOT the default — every subsequent Parse.* call
  # would still route through the first registration. assert_same checks
  # object identity, not just equality.
  def test_parse_setup_returns_the_registered_default_client
    returned = Parse.setup(@opts_a)
    assert_same returned, Parse::Client.client(:default),
      "Parse.setup must return the same instance it registered as :default"

    returned2 = Parse.setup(@opts_b)
    assert_same returned2, Parse::Client.client(:default),
      "Parse.setup on second call must return the newly-registered :default, not the prior one"
  end

  # The delegation from Parse.setup to Parse::Client.setup must forward
  # the block so callers can still customise the Faraday connection.
  # Parse::Client#initialize yields the Faraday `conn` once it's
  # constructed (see `yield(conn) if block_given?` in client.rb).
  def test_parse_setup_forwards_block_to_faraday_connection
    yielded = []
    Parse.setup(@opts_a) do |conn|
      yielded << conn
    end

    assert_equal 1, yielded.length,
      "Parse.setup must forward its block to Parse::Client.new exactly once"
    assert_kind_of Faraday::Connection, yielded.first,
      "The block must receive the Faraday connection, as it did pre-delegation"
  end
end
