# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit coverage for the `/serverInfo`-backed capability layer
# (Parse::API::Server#server_supports? / #server_features). The capability
# table is version-inferred (Parse Server's `features` block is too coarse to
# carry these behavior flags) and fails OPEN to the modern server line.
class TestServerCapabilities < Minitest::Test
  # Minimal host exposing the Server API mixin with a pre-seeded server_info,
  # so `server_info` returns without a wire request.
  class FakeServerClient
    include Parse::API::Server
    def initialize(info)
      @server_info = info
    end
  end

  def client_for(version: nil, features: {})
    info = { "features" => features }
    info["parseServerVersion"] = version if version
    FakeServerClient.new(info.with_indifferent_access)
  end

  def test_server_features_returns_advertised_block
    c = client_for(version: "9.9.0", features: { "hooks" => { "create" => true } })
    assert_equal({ "hooks" => { "create" => true } }, c.server_features)
  end

  def test_server_features_empty_when_absent
    c = FakeServerClient.new({ "parseServerVersion" => "9.9.0" }.with_indifferent_access)
    assert_equal({}, c.server_features)
  end

  def test_capabilities_on_current_server_9_9
    c = client_for(version: "9.9.0")
    assert c.server_supports?(:livequery_keys_option), "keys option since 7.0"
    assert c.server_supports?(:cloud_object_encoding), "object encoding since 8.0"
    assert c.server_supports?(:aggregate_raw_values), "rawValues since 9.9"
    refute c.server_supports?(:public_explain), "public explain restricted at 9.0"
  end

  def test_capabilities_on_8_5
    c = client_for(version: "8.5.0")
    assert c.server_supports?(:cloud_object_encoding)
    assert c.server_supports?(:public_explain), "below 9.0 → public explain still allowed"
    refute c.server_supports?(:aggregate_raw_values), "rawValues not until 9.9"
    assert c.server_supports?(:livequery_keys_option)
  end

  def test_capabilities_on_old_6_x
    c = client_for(version: "6.0.0")
    refute c.server_supports?(:cloud_object_encoding), "encoding not until 8.0"
    refute c.server_supports?(:livequery_keys_option), "keys rename not until 7.0"
    assert c.server_supports?(:public_explain), "old server allowed public explain"
  end

  def test_fail_open_to_modern_on_unknown_version
    c = client_for(version: nil) # features present, version absent
    # `since:` capabilities assume the modern server line → true
    assert c.server_supports?(:cloud_object_encoding)
    assert c.server_supports?(:aggregate_raw_values)
    # `until:` capabilities assume the modern (restricted) server → false
    refute c.server_supports?(:public_explain)
  end

  def test_unknown_capability_raises
    c = client_for(version: "9.9.0")
    assert_raises(ArgumentError) { c.server_supports?(:no_such_capability) }
  end
end
