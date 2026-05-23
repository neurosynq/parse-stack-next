require_relative "../../test_helper_integration"

# End-to-end verification of the parse_reference DSL: the after_create
# callback must trigger a follow-up save that populates the canonical
# "Class$objectId" value into the Parse Server / MongoDB.

class PRIntPost < Parse::Object
  parse_class "PRIntPost"
  property :title, :string
  parse_reference
end

class PRIntEvent < Parse::Object
  parse_class "PRIntEvent"
  property :name, :string
  parse_reference :ref, field: "refKey"
end

class PRIntPrecomputed < Parse::Object
  parse_class "PRIntPrecomputed"
  property :title, :string
  parse_reference precompute: true
end

class ParseReferenceIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def test_after_create_populates_parse_reference_in_mongodb
    post = PRIntPost.new(title: "first")
    post.save

    assert post.id.present?, "post must have a server-assigned id after save"
    expected = "PRIntPost$#{post.id}"

    # Local instance has the value (from after_create's writeback)
    assert_equal expected, post.parse_reference

    # And the server has it persisted -- fetch via master to confirm the
    # second save actually landed in MongoDB.
    fetched = Parse.client.request(:get, "classes/PRIntPost/#{post.id}").result
    assert_equal expected, fetched["parseReference"],
                 "Parse Server must have the canonical reference in the parseReference column. " \
                 "Got: #{fetched.inspect}"
  end

  def test_custom_field_name_persists_to_custom_remote_column
    event = PRIntEvent.new(name: "kickoff")
    event.save

    expected = "PRIntEvent$#{event.id}"
    assert_equal expected, event.ref

    fetched = Parse.client.request(:get, "classes/PRIntEvent/#{event.id}").result
    assert_equal expected, fetched["refKey"],
                 "the configured remote column name (refKey) must hold the value"
    refute fetched.key?("parseReference"),
           "default column should not be present when a custom field: is specified"
    refute fetched.key?("ref"),
           "the local Ruby name should not leak into the wire column"
  end

  def test_precompute_does_not_autofetch_during_before_create
    # Regression: the before_create _precompute_<field>! callback used to
    # call public_send(field_name) to compare the current value to the
    # canonical target. That goes through the property reader, which sees
    # value.nil? and pointer? (objectId just assigned, timestamps still
    # blank) and fires autofetch! against an id that doesn't exist on the
    # server yet -- producing a 101 Object not found and aborting save.
    obj = PRIntPrecomputed.new(title: "precomputed")
    obj.save

    assert obj.id.present?, "precomputed object must save and have an id"
    expected = "PRIntPrecomputed$#{obj.id}"
    assert_equal expected, obj.parse_reference,
                 "precompute must populate the local reference before the create POST"

    fetched = Parse.client.request(:get, "classes/PRIntPrecomputed/#{obj.id}").result
    assert_equal expected, fetched["parseReference"],
                 "precomputed reference must land in MongoDB on the initial create"
  end

  def test_value_is_stable_across_subsequent_updates
    # Subsequent saves should not change the field. (after_create only fires
    # once; later saves don't re-invoke the assignment helper.)
    post = PRIntPost.new(title: "original")
    post.save
    initial_ref = post.parse_reference

    post.title = "edited"
    post.save

    fetched = Parse.client.request(:get, "classes/PRIntPost/#{post.id}").result
    assert_equal initial_ref, fetched["parseReference"],
                 "parse_reference must not change across updates"
    assert_equal "edited", fetched["title"], "unguarded fields update normally"
  end
end
