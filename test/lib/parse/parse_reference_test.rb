require_relative "../../test_helper"
require "minitest/autorun"

# Default field name + auto-population helper for parse_reference
class PRDefault < Parse::Object
  parse_class "PRDefault"
  property :title, :string
  parse_reference
  def autofetch!(*); nil; end
end

# Custom local name; remote defaults to camelCase of local
class PRCustomLocal < Parse::Object
  parse_class "PRCustomLocal"
  property :name, :string
  parse_reference :ref
  def autofetch!(*); nil; end
end

# Custom local AND remote names
class PRCustomBoth < Parse::Object
  parse_class "PRCustomBoth"
  property :label, :string
  parse_reference :ref, field: "refKey"
  def autofetch!(*); nil; end
end

# System-class subclass: format must produce "_User$id"
class PRSystemUserSub < Parse::User
  parse_class "_User"
  parse_reference
  def autofetch!(*); nil; end
end

class PRParentForSubclass < Parse::Object
  parse_class "PRParentForSubclass"
  property :title, :string
  parse_reference
  def autofetch!(*); nil; end
end

# Child redeclares parse_reference -- must NOT register a second callback
class PRChildRedeclares < PRParentForSubclass
  parse_class "PRChildRedeclares"
  parse_reference
end

# Precompute path: id + reference assigned in before_create so the
# canonical value ships in the initial POST body, no after_create update!.
class PRPrecomputed < Parse::Object
  parse_class "PRPrecomputed"
  property :title, :string
  parse_reference precompute: true
  def autofetch!(*); nil; end
end

# Precompute on a subclass declaring twice -- must not register a second
# before_create callback.
class PRPrecomputedParent < Parse::Object
  parse_class "PRPrecomputedParent"
  parse_reference precompute: true
  def autofetch!(*); nil; end
end

class PRPrecomputedChild < PRPrecomputedParent
  parse_class "PRPrecomputedChild"
  parse_reference precompute: true
end

class ParseReferenceTest < Minitest::Test
  def setup
    # master_key must be configured for the `_precompute_<field>!` callback
    # to run; the DSL gates the optimization on master-key authority.
    Parse.setup(
      server_url: "https://test.parse.com",
      application_id: "test",
      api_key: "test",
      master_key: "test-master",
    )
  end

  def test_format_helper
    assert_equal "Post$abc123",
                 Parse::Core::ParseReference.format("Post", "abc123")
    assert_nil Parse::Core::ParseReference.format(nil, "abc")
    assert_nil Parse::Core::ParseReference.format("Post", nil)
    assert_nil Parse::Core::ParseReference.format("Post", "")
  end

  def test_parse_helper
    assert_equal ["Post", "abc123"], Parse::Core::ParseReference.parse("Post$abc123")
    assert_equal ["_User", "xyz"], Parse::Core::ParseReference.parse("_User$xyz")
    # IDs that themselves contain $ are preserved on the right side
    assert_equal ["Weird", "id$with$dollars"],
                 Parse::Core::ParseReference.parse("Weird$id$with$dollars")
    assert_equal [nil, nil], Parse::Core::ParseReference.parse(nil)
  end

  def test_parse_helper_rejects_malformed
    assert_raises(ArgumentError) { Parse::Core::ParseReference.parse("no-separator") }
    assert_raises(ArgumentError) { Parse::Core::ParseReference.parse(12345) }
  end

  def test_default_field_name_registers_property
    assert PRDefault.fields.key?(:parse_reference),
           "parse_reference should declare the :parse_reference local property"
    assert_equal "parseReference", PRDefault.field_map[:parse_reference].to_s,
                 "remote field defaults to camelCase form"
  end

  def test_custom_local_name_uses_camel_case_remote
    assert PRCustomLocal.fields.key?(:ref)
    assert_equal "ref", PRCustomLocal.field_map[:ref].to_s
  end

  def test_custom_local_and_remote_names
    assert PRCustomBoth.fields.key?(:ref)
    assert_equal "refKey", PRCustomBoth.field_map[:ref].to_s
  end

  def test_after_create_callback_registered
    # ActiveModel exposes the registered callbacks via _create_callbacks
    callbacks = PRDefault._create_callbacks.map { |cb| cb.filter.to_sym rescue cb.filter }
    assert_includes callbacks, :_assign_parse_reference!,
                    "after_create callback was registered"
  end

  def test_helper_sets_field_to_canonical_form
    obj = PRDefault.new(title: "hello")
    # Simulate post-create state: server has assigned an id
    obj.id = "abc123"
    obj.define_singleton_method(:update!) { true } # neutralize the follow-up save

    obj._assign_parse_reference!

    assert_equal "PRDefault$abc123", obj.parse_reference
  end

  def test_helper_is_idempotent_when_value_already_matches
    obj = PRDefault.new
    obj.id = "abc"
    obj.parse_reference = "PRDefault$abc"
    save_calls = 0
    obj.define_singleton_method(:update!) { save_calls += 1; true }

    obj._assign_parse_reference!
    assert_equal 0, save_calls, "helper must not trigger a save when value already matches"
  end

  def test_helper_skips_when_id_missing
    obj = PRDefault.new(title: "no id yet")
    save_calls = 0
    obj.define_singleton_method(:update!) { save_calls += 1; true }
    obj._assign_parse_reference!
    assert_nil obj.parse_reference, "no id => no value to set"
    assert_equal 0, save_calls
  end

  def test_custom_local_name_helper
    obj = PRCustomLocal.new(name: "x")
    obj.id = "xyz"
    obj.define_singleton_method(:update!) { true }
    obj._assign_ref!
    assert_equal "PRCustomLocal$xyz", obj.ref
  end

  def test_subclass_redeclaring_does_not_double_register_callback
    # Count how many _assign_parse_reference! filters are in the child's
    # create-callback chain. Should be 1, not 2 (one from parent inherit
    # + one from child redeclaration would be the bug).
    matches = PRChildRedeclares._create_callbacks.select do |cb|
      (cb.filter.to_sym rescue cb.filter) == :_assign_parse_reference!
    end
    assert_equal 1, matches.size,
                 "subclass redeclaring parse_reference must not stack a second callback"
  end

  def test_populate_parse_references_helper_populates_unset_objects
    obj = PRDefault.new(title: "hi")
    obj.id = "abc"
    obj.define_singleton_method(:update!) { true }

    updated = PRDefault.populate_parse_references!([obj])
    assert_equal "PRDefault$abc", obj.parse_reference
    assert_equal [obj], updated
  end

  def test_populate_parse_references_helper_skips_already_set
    obj = PRDefault.new
    obj.id = "abc"
    obj.parse_reference = "PRDefault$abc"
    save_calls = 0
    obj.define_singleton_method(:update!) { save_calls += 1; true }

    updated = PRDefault.populate_parse_references!([obj])
    assert_equal 0, save_calls, "already-populated objects must not trigger update!"
    assert_empty updated, "no objects considered updated"
  end

  def test_populate_parse_references_helper_skips_missing_id
    obj = PRDefault.new(title: "no id")
    save_calls = 0
    obj.define_singleton_method(:update!) { save_calls += 1; true }
    PRDefault.populate_parse_references!([obj])
    assert_equal 0, save_calls
  end

  def test_works_on_user_subclass
    user = PRSystemUserSub.new
    user.id = "user_abc"
    user.define_singleton_method(:update!) { true }
    user._assign_parse_reference!
    assert_equal "_User$user_abc", user.parse_reference,
                 "system-class subclasses produce the underscore-prefixed parse_class"
  end

  # ------------------------------------------------------------------
  # objectId generator
  # ------------------------------------------------------------------

  def test_generate_object_id_returns_10_char_alphanumeric
    id = Parse::Core::ParseReference.generate_object_id
    assert_kind_of String, id
    assert_equal 10, id.length, "Parse objectIds are 10 chars"
    assert_match(/\A[A-Za-z0-9]+\z/, id, "alphanumeric only, no $ or other punctuation")
  end

  def test_generate_object_id_length_constant_matches
    assert_equal 10, Parse::Core::ParseReference::OBJECT_ID_LENGTH
    id = Parse::Core::ParseReference.generate_object_id
    assert_equal Parse::Core::ParseReference::OBJECT_ID_LENGTH, id.length
  end

  def test_generate_object_id_produces_distinct_values
    ids = Array.new(200) { Parse::Core::ParseReference.generate_object_id }
    assert_equal 200, ids.uniq.size,
                 "no collisions expected in 200 draws from a 62^10 keyspace"
  end

  def test_generate_object_id_is_compatible_with_parse_reference_format
    id = Parse::Core::ParseReference.generate_object_id
    ref = Parse::Core::ParseReference.format("Post", id)
    klass, parsed_id = Parse::Core::ParseReference.parse(ref)
    assert_equal "Post", klass
    assert_equal id, parsed_id
  end

  # ------------------------------------------------------------------
  # new? semantics: stays true through before_create even when @id set
  # ------------------------------------------------------------------

  def test_new_true_when_id_and_created_at_both_blank
    obj = PRDefault.new
    assert obj.new?
  end

  def test_new_true_when_id_present_but_created_at_blank
    # This is the precompute case: a before_create callback has assigned
    # @id but the server hasn't yet returned createdAt. new? must remain
    # true so downstream callbacks (validation on:create, etc.) behave
    # correctly.
    obj = PRDefault.new
    obj.id = "client_assigned"
    assert obj.new?, "object with id but no createdAt is still considered new"
  end

  def test_not_new_when_both_id_and_created_at_present
    obj = PRDefault.new
    obj.id = "abc"
    obj.created_at = Time.now
    refute obj.new?
  end

  # ------------------------------------------------------------------
  # precompute DSL: callback registration
  # ------------------------------------------------------------------

  def test_precompute_registers_before_create_callback
    found = PRPrecomputed._create_callbacks.any? do |cb|
      cb.kind == :before && (cb.filter.to_sym rescue cb.filter) == :_precompute_parse_reference!
    end
    assert found, "before_create _precompute_parse_reference! must be registered"
  end

  def test_precompute_still_registers_after_create_assign
    # Defensive: the after_create callback remains as a safety net.
    # It becomes a no-op when precompute already set the canonical value
    # (early-return on `current == target`), so registering both is cheap.
    found = PRPrecomputed._create_callbacks.any? do |cb|
      cb.kind == :after && (cb.filter.to_sym rescue cb.filter) == :_assign_parse_reference!
    end
    assert found, "after_create safety net must still be registered"
  end

  def test_default_path_does_not_register_precompute_callback
    found = PRDefault._create_callbacks.any? do |cb|
      cb.kind == :before && cb.filter.to_s.start_with?("_precompute_")
    end
    refute found, "non-precompute classes get no before_create precompute hook"
  end

  def test_precompute_subclass_redeclaring_does_not_double_register
    matches = PRPrecomputedChild._create_callbacks.select do |cb|
      cb.kind == :before && (cb.filter.to_sym rescue cb.filter) == :_precompute_parse_reference!
    end
    assert_equal 1, matches.size,
                 "subclass redeclaring precompute must not stack a second before_create"
  end

  # ------------------------------------------------------------------
  # precompute callback behavior
  # ------------------------------------------------------------------

  def test_precompute_callback_assigns_id_and_canonical_reference
    obj = PRPrecomputed.new(title: "hi")
    assert obj.id.blank?, "precondition: id is blank"
    obj.send(:_precompute_parse_reference!)
    refute_nil obj.id
    assert_equal 10, obj.id.length
    assert_equal "PRPrecomputed$#{obj.id}", obj.parse_reference
  end

  def test_precompute_callback_preserves_existing_id
    obj = PRPrecomputed.new(title: "hi")
    obj.id = "manually_set"
    obj.send(:_precompute_parse_reference!)
    assert_equal "manually_set", obj.id,
                 "precompute must not overwrite an already-assigned id"
    assert_equal "PRPrecomputed$manually_set", obj.parse_reference
  end

  def test_precompute_callback_is_idempotent_when_reference_already_matches
    obj = PRPrecomputed.new(title: "hi")
    obj.id = "abc"
    obj.parse_reference = "PRPrecomputed$abc"
    # Should early-return without modifying anything.
    obj.send(:_precompute_parse_reference!)
    assert_equal "abc", obj.id
    assert_equal "PRPrecomputed$abc", obj.parse_reference
  end

  def test_precompute_marks_parse_reference_as_changed_for_attribute_updates
    # The whole point of precompute is that the reference value lands in
    # the initial POST body. attribute_updates only includes fields that
    # ActiveModel considers changed. Note the key is a Symbol (matches the
    # remote field_map value), not a String.
    obj = PRPrecomputed.new(title: "hi")
    obj.send(:_precompute_parse_reference!)
    updates = obj.attribute_updates
    assert_includes updates.keys, :parseReference,
                    "precomputed value must be visible to the create body"
    assert_equal obj.parse_reference, updates[:parseReference]
  end

  # ------------------------------------------------------------------
  # End-to-end integration with Parse::Object#create (stubbed client)
  # ------------------------------------------------------------------

  # Minimal stand-ins mirroring the StubClient pattern in
  # test/lib/parse/models/user_save_signup_test.rb.
  class StubResponse
    attr_reader :result, :error
    def initialize(result: {}, error: nil); @result = result; @error = error; end
    def success?; @error.nil?; end
    def error?; !success?; end
  end

  class StubClient
    attr_reader :calls, :master_key
    def initialize(create_response: nil, update_response: nil, master_key: "test-master")
      @calls = []
      @create_response = create_response
      @update_response = update_response
      # The `_precompute_<field>!` callback gates on master-key authority;
      # precompute is a master-only optimization. Tests of the precompute
      # path must therefore present a master_key on the stub client.
      @master_key = master_key
    end

    def create_object(class_name, body, session_token: nil, **_opts)
      @calls << [:create_object, class_name, body, session_token]
      @create_response || StubResponse.new(result: {
        "objectId" => body["objectId"] || "srv_generated",
        "createdAt" => "2026-05-15T00:00:00Z",
      })
    end

    def update_object(class_name, id, body, session_token: nil, **_opts)
      @calls << [:update_object, class_name, id, body, session_token]
      @update_response || StubResponse.new(result: { "updatedAt" => "2026-05-15T00:00:01Z" })
    end

    def request(*args, **kwargs)
      raise "unexpected raw request in precompute test: #{args.inspect}"
    end

    def calls_to(method); @calls.select { |c| c.first == method }; end
  end

  def with_stubbed_client(obj, client)
    obj.define_singleton_method(:client) { client }
    obj
  end

  def test_create_body_includes_objectId_when_precompute_set_it
    obj = PRPrecomputed.new(title: "hello")
    client = StubClient.new
    with_stubbed_client(obj, client)

    assert obj.save, "save should succeed against stubbed client"

    create_calls = client.calls_to(:create_object)
    assert_equal 1, create_calls.size, "exactly one create POST"
    _, _, body, _ = create_calls.first
    # objectId is merged in via create() using the Parse::Model::OBJECT_ID
    # string constant; property fields land under their symbol field_map keys.
    refute_nil body["objectId"], "objectId must be forwarded in the body"
    assert_equal 10, body["objectId"].length
    assert_equal "PRPrecomputed$#{body["objectId"]}", body[:parseReference]
    assert_equal "hello", body[:title]
  end

  def test_no_followup_update_when_precompute_set_reference
    obj = PRPrecomputed.new(title: "hello")
    client = StubClient.new
    with_stubbed_client(obj, client)

    obj.save

    assert_empty client.calls_to(:update_object),
                 "precompute path must avoid the after_create second write"
  end

  def test_precompute_skipped_when_client_has_no_master_key
    # Without master-key authority on the save, the SDK refuses to forward
    # a client-supplied objectId (objectId-squatting protection) and
    # precompute falls back to the after_create _assign_<field>! flow:
    # one create POST without objectId + one update PUT to fill in the
    # reference. The local @id is server-assigned, so the reference is
    # derived from the real id.
    obj = PRPrecomputed.new(title: "hello")
    client = StubClient.new(master_key: nil)
    with_stubbed_client(obj, client)

    obj.save

    create_calls = client.calls_to(:create_object)
    assert_equal 1, create_calls.size
    _, _, body, _ = create_calls.first
    refute body.key?("objectId"),
           "client-supplied objectId must not be forwarded without master key"
    refute body.key?(:parseReference),
           "parse_reference must not be precomputed without master key"

    update_calls = client.calls_to(:update_object)
    assert_equal 1, update_calls.size,
                 "after_create _assign_<field>! must run as the fallback"
    _, _, _, body, _ = update_calls.first
    assert_equal "PRPrecomputed$srv_generated", body[:parseReference]
  end

  def test_precompute_skipped_when_session_token_set
    # A per-save session token means the save runs as a user, not as
    # master. Precompute must skip and fall back to the after_create
    # flow, otherwise the create POST would carry a client-supplied
    # objectId rejected by Parse Server (or accepted under
    # `allowCustomObjectId: true` as an objectId-squatting vector).
    obj = PRPrecomputed.new(title: "hello")
    client = StubClient.new
    with_stubbed_client(obj, client)

    obj.save(session: "r:session-abc")

    create_calls = client.calls_to(:create_object)
    assert_equal 1, create_calls.size
    _, _, body, session_token = create_calls.first
    refute body.key?("objectId"),
           "client-supplied objectId must not be forwarded under session-token auth"
    assert_equal "r:session-abc", session_token

    update_calls = client.calls_to(:update_object)
    assert_equal 1, update_calls.size,
                 "after_create _assign_<field>! fallback must run under session-token auth"
  end

  # ------------------------------------------------------------------
  # before_save recompute callback (belt-and-suspenders defense)
  # ------------------------------------------------------------------

  def test_recompute_callback_registered_as_before_save
    found = PRDefault._save_callbacks.any? do |cb|
      cb.kind == :before && (cb.filter.to_sym rescue cb.filter) == :_recompute_parse_reference!
    end
    assert found, "before_save _recompute_parse_reference! must be registered"
  end

  def test_recompute_callback_overwrites_divergent_value
    # Simulates the webhook context: object's id has been assigned by Parse
    # Server, but parseReference has been set to a spoofed value (e.g. by a
    # non-gem client whose write slipped past apply_field_guards! on create).
    obj = PRDefault.new
    obj.id = "abc123"
    obj.parse_reference = "AdminAudit$evil"
    obj.send(:_recompute_parse_reference!)
    assert_equal "PRDefault$abc123", obj.parse_reference,
                 "any divergent value must be force-recomputed to canonical"
  end

  def test_recompute_callback_is_noop_when_value_matches
    obj = PRDefault.new
    obj.id = "abc"
    obj.parse_reference = "PRDefault$abc"
    obj.changes_applied
    obj.send(:_recompute_parse_reference!)
    assert_equal "PRDefault$abc", obj.parse_reference
    refute obj.parse_reference_changed?, "no dirty bit when value already matched"
  end

  def test_recompute_callback_skips_when_id_blank
    # In the gem-side save flow, before_save fires before before_create, so
    # id is still blank for a fresh non-precompute object. The callback must
    # be a no-op in that context; the after_create populator handles it.
    obj = PRDefault.new
    obj.send(:_recompute_parse_reference!)
    assert_nil obj.id
    assert_nil obj.parse_reference
  end

  def test_recompute_fires_during_save_callbacks
    obj = PRDefault.new
    obj.id = "xyz"
    obj.parse_reference = "Bogus$value"
    # Run the :save callback chain directly (mirrors what prepare_save! does
    # in the webhook flow) without triggering the actual REST request.
    obj.run_callbacks(:save) { true }
    assert_equal "PRDefault$xyz", obj.parse_reference,
                 "before_save chain must include the recompute callback"
  end

  def test_recompute_subclass_redeclaring_does_not_double_register
    matches = PRChildRedeclares._save_callbacks.select do |cb|
      cb.kind == :before && (cb.filter.to_sym rescue cb.filter) == :_recompute_parse_reference!
    end
    assert_equal 1, matches.size,
                 "subclass redeclaring must not stack a second before_save"
  end

  def test_default_path_omits_objectId_when_id_blank
    # Backwards-compat: classes that don't use precompute send no objectId
    # in the create body and the server assigns one.
    obj = PRDefault.new(title: "no-precompute")
    client = StubClient.new
    with_stubbed_client(obj, client)
    obj.define_singleton_method(:update!) { true } # neutralize the after_create followup

    obj.save

    _, _, body, _ = client.calls_to(:create_object).first
    refute body.key?("objectId"), "non-precompute path must not include client-assigned objectId"
  end
end
