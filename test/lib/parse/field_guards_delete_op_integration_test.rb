require_relative "../../test_helper_integration"

# Integration test that probes the Parse Server semantic that the FieldGuards
# feature relies on: when a beforeSave webhook (or, equivalently, a direct
# REST create request) emits {"__op": "Delete"} for a field on a CREATE, does
# Parse Server drop the field from the persisted object, or does it persist
# the client-supplied value anyway?
#
# This test does NOT exercise the parse-stack guard module end-to-end (that
# requires standing up a local Rack server and registering its URL with
# Parse Server, which is significant new infrastructure). Instead it isolates
# the single semantic question that determines whether :master_only-on-create
# can be enforced via our changes_payload response, by hitting the Parse
# Server REST endpoint directly with the same payload shape our gem produces.
#
# If this test fails, the `:master_only` guard on create is a paper guarantee
# and the design needs to change (likely emitting a full-object replacement
# response rather than a Delete-op delta).
class FieldGuardsDeleteOpIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  CLASS_NAME = "GuardDeleteOpProbe"

  def teardown
    # Best-effort cleanup; the integration test_helper resets the database
    # between cases, but explicit deletes keep dashboard state tidy.
    super
  rescue StandardError
    # Ignore teardown failures
  end

  def test_delete_op_on_create_drops_field_from_persisted_object
    # Submit a create with one normal field and one field carrying a Delete op
    # -- mimicking what our webhook would return on a non-master client save
    # against a class with `guard :secret, :master_only`.
    body = {
      "slug" => "create-with-delete-op",
      "secret" => { "__op" => "Delete" },
    }

    response = Parse.client.request(
      :post,
      "classes/#{CLASS_NAME}",
      body: body.to_json,
    )
    object_id = response.result["objectId"]
    refute_nil object_id, "Parse Server accepted the create (got response: #{response.result.inspect})"

    # Fetch the object back via the master-key client and inspect what was
    # actually persisted. The fetch must use the same Parse.client connection
    # the gem uses (configured by test_helper_integration), which has master
    # key for read access.
    fetched = Parse.client.request(:get, "classes/#{CLASS_NAME}/#{object_id}").result

    assert_equal "create-with-delete-op", fetched["slug"],
                 "the unguarded field must be persisted normally"
    refute fetched.key?("secret"),
           "Parse Server must drop the field when the create payload contains " \
           "{__op: Delete} for it -- otherwise master_only-on-create cannot be " \
           "enforced via webhook response. Got fetched object: #{fetched.inspect}"
  end

  def test_delete_op_overrides_client_supplied_value_on_create
    # The realistic scenario: a client sends BOTH a value and our webhook
    # response wants to drop it. Parse Server merges the webhook response with
    # the client payload, so the Delete op in the response must win.
    body = {
      "slug" => "create-override",
      # The client tried to write this value:
      "secret" => "client-tried-to-leak-this",
    }
    # Now simulate the webhook response merging by sending a SECOND payload
    # that resembles what our webhook code would emit: secret gets a Delete op.
    # Since we can't intercept here without a Rack endpoint, this case is
    # exercised in the unit tests; the test above proves the Parse Server
    # honors Delete-on-create which is the only semantic our gem depends on.
    skip "Covered by the unit test that asserts {__op: Delete} in changes_payload " \
         "and the test above that proves Parse Server honors it. End-to-end is " \
         "deferred until the local Rack-webhook integration harness exists."
  end
end
