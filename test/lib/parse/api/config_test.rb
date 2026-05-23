require_relative "../../../test_helper"

class TestApiConfig < Minitest::Test
  include Parse::API::Config

  def setup
    @last_request = nil
    @next_result = { "params" => {}, "masterKeyOnly" => {} }
    @next_error = false
    @config = nil
    @master_key_only = nil
  end

  def request(method, path, **args)
    @last_request = { method: method, path: path, args: args }
    response = Object.new
    result = @next_result
    error = @next_error
    response.define_singleton_method(:result) { result }
    response.define_singleton_method(:error?) { error }
    response
  end

  def test_config_reads_params_and_master_key_only
    @next_result = {
      "params" => { "alpha" => 1, "beta" => "two" },
      "masterKeyOnly" => { "alpha" => true },
    }

    params = config

    assert_equal :get, @last_request[:method]
    assert_equal "config", @last_request[:path]
    assert_equal({ "alpha" => 1, "beta" => "two" }, params)
    assert_equal({ "alpha" => true }, master_key_only)
  end

  def test_config_caches_until_bang
    @next_result = { "params" => { "k" => 1 }, "masterKeyOnly" => {} }
    config
    first_request = @last_request

    @next_result = { "params" => { "k" => 2 }, "masterKeyOnly" => {} }
    config
    assert_same first_request, @last_request, "second config call should hit cache"

    config!
    refute_same first_request, @last_request, "config! should force a refetch"
    assert_equal 2, @config["k"]
  end

  def test_master_key_only_returns_empty_hash_when_server_omits_it
    @next_result = { "params" => { "k" => 1 } }
    config
    assert_equal({}, master_key_only)
  end

  def test_master_key_only_triggers_lazy_fetch
    @next_result = { "params" => {}, "masterKeyOnly" => { "x" => true } }
    flag_map = master_key_only
    assert_equal({ "x" => true }, flag_map)
    assert_equal :get, @last_request[:method]
  end

  def test_update_config_without_master_key_only_omits_field
    @next_result = { "result" => true }
    @config = { "existing" => "value" }
    @master_key_only = { "existing" => true }

    ok = update_config({ "existing" => "new" })

    assert_equal true, ok
    assert_equal :put, @last_request[:method]
    assert_equal({ params: { "existing" => "new" } }, @last_request[:args][:body])
    refute @last_request[:args][:body].key?(:masterKeyOnly)
    assert_equal({ "existing" => true }, @master_key_only,
      "masterKeyOnly cache should be untouched when caller did not pass it")
  end

  def test_update_config_with_master_key_only_sends_and_merges
    @next_result = { "result" => true }
    @config = { "existing" => "value" }
    @master_key_only = { "existing" => false }

    ok = update_config({ "newish" => 42 }, master_key_only: { newish: true })

    assert_equal true, ok
    assert_equal :put, @last_request[:method]
    body = @last_request[:args][:body]
    assert_equal({ "newish" => 42 }, body[:params])
    assert_equal({ newish: true }, body[:masterKeyOnly])
    assert_equal({ "existing" => false, "newish" => true }, @master_key_only)
  end

  def test_update_config_returns_false_on_server_error
    @next_error = true
    refute update_config({ "k" => "v" }, master_key_only: { k: true })
  end

  def test_config_entries_default_filters_master_key_only
    @next_result = {
      "params" => { "pubA" => 1, "secB" => "hush", "pubC" => true },
      "masterKeyOnly" => { "secB" => true, "pubA" => false },
    }
    config

    entries = config_entries
    refute entries.key?("secB"), "default master:false should hide masterKeyOnly keys"
    assert_equal({ value: 1, master_key_only: false }, entries["pubA"])
    assert_equal({ value: true, master_key_only: false }, entries["pubC"])
  end

  def test_config_entries_with_master_true_includes_everything
    @next_result = {
      "params" => { "pubA" => 1, "secB" => "hush" },
      "masterKeyOnly" => { "secB" => true },
    }
    config

    entries = config_entries(master: true)
    assert_equal({ value: 1, master_key_only: false }, entries["pubA"])
    assert_equal({ value: "hush", master_key_only: true }, entries["secB"])
  end

  def test_config_entries_lazy_fetches_when_uncached
    @next_result = {
      "params" => { "k" => 9 },
      "masterKeyOnly" => {},
    }
    entries = config_entries
    assert_equal :get, @last_request[:method]
    assert_equal({ value: 9, master_key_only: false }, entries["k"])
  end

  def test_config_entries_with_empty_master_key_only_map
    # Mirrors the non-master-key-configured case: server already stripped
    # master-only entries server-side, so the flag map is empty/missing.
    @next_result = { "params" => { "pubA" => 1, "pubB" => 2 } }
    config

    assert_equal config_entries, config_entries(master: true),
      "with no flag map, master: true and master: false should be identical"
    assert_equal({ value: 1, master_key_only: false }, config_entries["pubA"])
  end
end
