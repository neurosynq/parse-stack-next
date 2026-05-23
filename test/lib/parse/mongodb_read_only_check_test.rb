# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"

# Unit tests for Parse::MongoDB.read_only? + configure's verify_role warning.
# The connectionStatus probe is stubbed via stub responses on a fake client;
# no live MongoDB is needed.
class MongoDBReadOnlyCheckTest < Minitest::Test
  def setup
    @stash_analytics = ENV.delete("ANALYTICS_DATABASE_URI")
    @stash_database  = ENV.delete("DATABASE_URI")
    Parse::MongoDB.reset!
  end

  def teardown
    ENV["ANALYTICS_DATABASE_URI"] = @stash_analytics if @stash_analytics
    ENV["DATABASE_URI"]           = @stash_database  if @stash_database
    Parse::MongoDB.reset!
  end

  # Build a fake client whose `database.command(...)` returns the stub
  # response. Avoids the network entirely.
  def stub_client_with_response(response)
    fake_db = Object.new
    fake_db.define_singleton_method(:command) { |*_args| [response] }
    fake_client = Object.new
    fake_client.define_singleton_method(:database) { fake_db }
    fake_client
  end

  def configure_then_stub(stub_response)
    Parse::MongoDB.configure(
      uri: "mongodb://stub:27017/db",
      enabled: true,
      verify_role: false,
    )
    fake = stub_client_with_response(stub_response)
    Parse::MongoDB.instance_variable_set(:@client, fake)
  end

  # ---- read_only? --------------------------------------------------------

  def test_read_only_returns_true_when_privileges_have_no_write_actions
    configure_then_stub({
      "authInfo" => {
        "authenticatedUserPrivileges" => [
          { "resource" => { "db" => "parse", "collection" => "" },
            "actions" => %w[find listCollections listIndexes] },
        ],
      },
    })
    assert_equal true, Parse::MongoDB.read_only?
  end

  def test_read_only_returns_false_when_insert_action_present
    configure_then_stub({
      "authInfo" => {
        "authenticatedUserPrivileges" => [
          { "resource" => { "db" => "parse", "collection" => "" },
            "actions" => %w[find insert] },
        ],
      },
    })
    assert_equal false, Parse::MongoDB.read_only?
  end

  def test_read_only_returns_false_when_any_write_action_in_any_privilege
    configure_then_stub({
      "authInfo" => {
        "authenticatedUserPrivileges" => [
          { "resource" => { "db" => "parse", "collection" => "Song" },
            "actions" => %w[find] },
          { "resource" => { "db" => "parse", "collection" => "Artist" },
            "actions" => %w[find update] },
        ],
      },
    })
    assert_equal false, Parse::MongoDB.read_only?
  end

  def test_read_only_returns_nil_when_privilege_list_missing
    configure_then_stub({ "authInfo" => {} })
    assert_nil Parse::MongoDB.read_only?
  end

  def test_read_only_returns_nil_when_privilege_list_empty
    configure_then_stub({
      "authInfo" => { "authenticatedUserPrivileges" => [] },
    })
    assert_nil Parse::MongoDB.read_only?
  end

  def test_read_only_returns_nil_when_command_raises
    Parse::MongoDB.configure(
      uri: "mongodb://stub:27017/db",
      enabled: true,
      verify_role: false,
    )
    fake_db = Object.new
    fake_db.define_singleton_method(:command) { |*_a| raise "boom" }
    fake_client = Object.new
    fake_client.define_singleton_method(:database) { fake_db }
    Parse::MongoDB.instance_variable_set(:@client, fake_client)
    assert_nil Parse::MongoDB.read_only?
  end

  def test_read_only_returns_nil_when_not_available
    Parse::MongoDB.reset!
    assert_nil Parse::MongoDB.read_only?
  end

  # ---- configure verify_role warning ------------------------------------

  def test_warns_when_role_is_writeable
    # We exercise warn_if_writeable_role! directly because configure's
    # internal call (verify_role: true) would attempt a real connection to
    # the bogus stub URI and stall on server selection. Configure first
    # with verify_role: false, then install the fake client, then call the
    # warning helper.
    fake = stub_client_with_response({
      "authInfo" => {
        "authenticatedUserPrivileges" => [
          { "resource" => { "db" => "parse", "collection" => "" },
            "actions" => %w[find insert] },
        ],
      },
    })
    Parse::MongoDB.configure(
      uri: "mongodb://stub:27017/db",
      enabled: true,
      verify_role: false,
    )
    Parse::MongoDB.instance_variable_set(:@client, fake)
    captured = capture_warn { Parse::MongoDB.warn_if_writeable_role! }
    assert_match(/write privileges/, captured)
  end

  def test_does_not_warn_when_role_is_read_only
    fake = stub_client_with_response({
      "authInfo" => {
        "authenticatedUserPrivileges" => [
          { "resource" => { "db" => "parse", "collection" => "" },
            "actions" => %w[find] },
        ],
      },
    })
    captured = capture_warn do
      Parse::MongoDB.configure(
        uri: "mongodb://stub:27017/db",
        enabled: true,
        verify_role: false,
      )
      Parse::MongoDB.instance_variable_set(:@client, fake)
      Parse::MongoDB.warn_if_writeable_role!
    end
    assert_equal "", captured
  end

  def test_does_not_warn_when_role_is_indeterminate
    fake = stub_client_with_response({ "authInfo" => {} })
    captured = capture_warn do
      Parse::MongoDB.configure(
        uri: "mongodb://stub:27017/db",
        enabled: true,
        verify_role: false,
      )
      Parse::MongoDB.instance_variable_set(:@client, fake)
      Parse::MongoDB.warn_if_writeable_role!
    end
    assert_equal "", captured, "nil (indeterminate) must not surface as a warning"
  end

  def test_verify_role_false_skips_the_check
    # No fake client installed: a real configure with verify_role: true would
    # attempt a connection to the bogus URI and stall on server selection.
    # verify_role: false must return immediately.
    started = Time.now
    Parse::MongoDB.configure(
      uri: "mongodb://stub:27017/db",
      enabled: true,
      verify_role: false,
    )
    elapsed = Time.now - started
    assert elapsed < 1.0, "verify_role: false must not attempt a connection (took #{elapsed}s)"
  end

  def capture_warn
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
