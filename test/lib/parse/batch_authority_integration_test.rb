require_relative "../../test_helper_integration"
require "minitest/autorun"

class BatchAuthorityItem < Parse::Object
  parse_class "BatchAuthorityItem"
  property :v, :integer
end

# A batch must run each write with the credentials it was built for. Parse
# Server runs every sub-request of a `POST /batch` under that call's own
# credentials, so a write built for a user session must not reach a row
# only the master key can change.
class BatchAuthorityIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def setup_rows
    user = Parse::User.new(username: "batch_auth_#{SecureRandom.hex(4)}", password: "pw-#{SecureRandom.hex(4)}")
    user.signup!
    row = BatchAuthorityItem.new(v: 1)
    row.acl = Parse::ACL.new # master only
    row.save!
    [user, row]
  end

  # The stored value, read with the master key and without the cache.
  def stored_v(row)
    Parse.client.fetch_object("BatchAuthorityItem", row.id, cache: false, use_master_key: true).result["v"]
  end

  # The row as a fetched object, read with the default (master) client.
  def master_copy(row)
    BatchAuthorityItem.build(Parse.client.fetch_object("BatchAuthorityItem", row.id, cache: false, use_master_key: true).result)
  end

  def with_user_client(user)
    previous = BatchAuthorityItem.instance_variable_get(:@client)
    BatchAuthorityItem.instance_variable_set(:@client, Parse.client.become(user.session_token))
    yield
  ensure
    BatchAuthorityItem.instance_variable_set(:@client, previous)
  end

  def test_raw_request_session_is_enforced_in_a_batch
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      user, row = setup_rows
      req = Parse::Request.new(:put, row.uri_path, body: { v: 2 },
                                                   opts: { session_token: user.session_token, use_master_key: false })
      responses = Parse.batch([req]).submit
      refute responses.first.success?, "a user-session write to a master-only row must be refused"
      assert_equal 1, stored_v(row)
    end
  end

  def test_array_save_uses_the_session_bound_class_client
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      user, row = setup_rows
      target = master_copy(row)
      with_user_client(user) do
        target.v = 11
        refute target.save, "a single save as the user is refused"
        target.v = 11
        refute [target].save.success?, "the batch save as the user is refused too"
      end
      assert_equal 1, stored_v(row), "a batch save through the user's client must not run as master"
    end
  end

  def test_transaction_uses_the_session_bound_class_client
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      user, row = setup_rows
      target = master_copy(row)
      with_user_client(user) do
        target.v = 12
        begin
          BatchAuthorityItem.transaction(retry_server_errors: true) { |tx| tx.add(target) }
        rescue Parse::Error
          # A refused transaction may surface as an error; the stored value is the check.
        end
      end
      assert_equal 1, stored_v(row), "a transaction through the user's client must not run as master"
    end
  end

  def test_session_argument_is_enforced_and_master_default_unchanged
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      user, row = setup_rows
      fetched = master_copy(row)
      fetched.v = 20
      batch = [fetched].save(session: user)
      refute batch.success?
      assert_equal 1, stored_v(row)

      # The default (master) client still writes the row.
      fetched = master_copy(row)
      fetched.v = 21
      assert [fetched].save.success?
      assert_equal 21, stored_v(row)
    end
  end
end
