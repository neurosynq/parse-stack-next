# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# The hazard this closes was created by making authorization per-client while
# the MongoDB connection stayed process-global.
#
# Before 5.7 both were global, so they were at least consistently wrong
# together. Now `client.authorization` resolves a session token against that
# client's own Parse application, while `Parse::MongoDB` still holds one URI,
# one database, and one driver client chosen by whoever called `configure`. A
# secondary client would resolve its token correctly, build a correct `_rperm`
# allow-set for a user of ITS application, and then run the resulting pipeline
# against the other application's database. Nothing about that looks like a
# failure; it looks like a query that returned few rows.
class MongoDBClientBindingTest < Minitest::Test
  def setup
    @bound = Parse::MongoDB.instance_variable_get(:@bound_application_id)
  end

  def teardown
    Parse::MongoDB.instance_variable_set(:@bound_application_id, @bound)
  end

  def bind_to(app_id)
    Parse::MongoDB.instance_variable_set(:@bound_application_id, app_id)
  end

  FakeClient = Struct.new(:application_id)

  def test_matching_application_passes
    bind_to("appA")
    Parse::MongoDB.verify_client!(FakeClient.new("appA"))
  end

  def test_mismatched_application_fails_closed
    bind_to("appA")
    error = assert_raises(Parse::MongoDB::ClientMismatch) do
      Parse::MongoDB.verify_client!(FakeClient.new("appB"))
    end
    assert_includes error.message, "appA"
    assert_includes error.message, "appB"
  end

  # A connection configured before this guard existed, or in a process that
  # set up Mongo before Parse, records no binding. There is nothing to compare
  # against, so the call proceeds rather than breaking every such deployment.
  def test_no_binding_recorded_permits_the_call
    bind_to(nil)
    Parse::MongoDB.verify_client!(FakeClient.new("appB"))
  end

  # Master-mode and public-fallback resolutions can be produced in a process
  # that never called Parse.setup, so they carry no client. An unidentifiable
  # caller cannot be checked, and refusing it would break paths that worked
  # before authorization was client-scoped at all.
  def test_unidentifiable_caller_permits_the_call
    bind_to("appA")
    Parse::MongoDB.verify_client!(nil)
    Parse::MongoDB.verify_client!(FakeClient.new(nil))
  end

  # The message has to say what to do about it. A bare "mismatch" would send
  # an operator looking for a bug in their query.
  def test_message_names_the_remedy
    bind_to("appA")
    error = assert_raises(Parse::MongoDB::ClientMismatch) do
      Parse::MongoDB.verify_client!(FakeClient.new("appB"))
    end
    assert_includes error.message, "REST"
  end

  # ACLScope must label every resolution with its client, or the guard above
  # has nothing to check and silently permits everything.
  def test_every_resolution_carries_its_client
    modes = [
      [{ master: true }, :master],
      [{}, :public],
    ]
    modes.each do |kwargs, expected_mode|
      resolution = Parse::ACLScope.resolve!(kwargs.dup, method_name: :aggregate)
      assert_equal expected_mode, resolution.mode
      assert resolution.respond_to?(:client),
             "Resolution must carry the client so MongoDB.verify_client! can check it"
    end
  end

  # The kwarg must be consumed, not forwarded to the driver, which would
  # reject it as an unknown aggregate option.
  def test_client_kwarg_is_popped_from_the_options_hash
    options = { master: true, client: nil, max_time_ms: 500 }
    Parse::ACLScope.resolve!(options, method_name: :aggregate)
    refute options.key?(:client), "client: must be consumed like the other auth kwargs"
    assert_equal 500, options[:max_time_ms], "non-auth options must survive"
  end
end
