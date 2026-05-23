require_relative "../../test_helper"

# Tests the mass-assignment allowlist that prevents attacker-controlled
# params from overwriting permission-sensitive keys (acl, roles, objectId,
# sessionToken, ...) on Parse::Object subclasses.
class MassAssignmentProtectionTest < Minitest::Test
  class TestDocument < Parse::Object
    parse_class "TestDocument"
    property :title, :string
    property :body, :string
  end

  # NOTE: `acl` and `objectId` are deliberately NOT in the denylist —
  # `Document.new(acl: my_acl)` is legitimate developer code, and Rails
  # apps should filter attacker-controlled params via StrongParameters
  # before passing them to `Model.new` or `attributes=`. The model layer
  # only blocks fields that have no legitimate user-facing setter.

  def test_mass_assignment_allows_acl
    # ACL is a user-facing property; setting it via the constructor or
    # `attributes=` must work for legitimate developer code paths.
    doc = TestDocument.new
    acl = Parse::ACL.new
    acl.apply("role:Admin", read: true, write: true)
    doc.attributes = { "title" => "Hello", "acl" => acl }
    assert_equal "Hello", doc.title
    acl_json = doc.acl.as_json
    assert acl_json["role:Admin"], "developer-set ACL must be applied"
  end

  def test_mass_assignment_skips_session_token
    user = Parse::User.new
    user.attributes = { "username" => "alice", "sessionToken" => "r:stolen" }
    assert_nil user.session_token
  end

  def test_mass_assignment_skips_roles
    user = Parse::User.new
    user.attributes = { "username" => "alice", "roles" => ["Admin"] }
    # roles should not be writable via mass assignment
    refute_includes (user.respond_to?(:roles) ? user.roles : []), "Admin"
  end

  def test_mass_assignment_skips_created_at_updated_at
    doc = TestDocument.new
    past = Time.utc(1999, 1, 1)
    doc.attributes = { "title" => "Hello", "createdAt" => past.iso8601, "updatedAt" => past.iso8601 }
    refute_equal past.to_i, doc.created_at.to_i if doc.created_at
    refute_equal past.to_i, doc.updated_at.to_i if doc.updated_at
  end

  def test_mass_assignment_allows_normal_properties
    doc = TestDocument.new
    doc.attributes = { "title" => "Hello", "body" => "world" }
    assert_equal "Hello", doc.title
    assert_equal "world", doc.body
  end

  def test_internal_hydration_still_accepts_protected_keys
    # apply_attributes! with dirty_track: false (the default) is the trusted
    # internal hydration path used when building objects from Parse Server
    # responses. It must still accept server-issued sessionToken/ACL/etc.
    user = Parse::User.new
    user.apply_attributes!({ "username" => "alice", "sessionToken" => "r:legit" })
    assert_equal "r:legit", user.session_token
  end

  def test_protected_keys_set_is_frozen
    assert_predicate Parse::Properties::PROTECTED_MASS_ASSIGNMENT_KEYS, :frozen?
  end

  def test_protected_initialize_keys_set_is_frozen
    assert_predicate Parse::Properties::PROTECTED_INITIALIZE_KEYS, :frozen?
  end

  # NEW-EXT-1 defense-in-depth: caller-supplied hashes with an objectId
  # (controller params, JSON params, cache rehydrators) must not be able
  # to forge sessionToken / _rperm / _wperm / _hashed_password / authData
  # / roles by hitting the pristine-hydration branch of #initialize.
  def test_initialize_with_objectId_filters_session_token
    user = Parse::User.new(objectId: "victim", sessionToken: "r:forged")
    assert_equal "victim", user.id
    # Read the ivar directly so we don't trigger an autofetch (the
    # object is in pointer state because no createdAt/updatedAt was
    # supplied, and reading typed properties triggers fetch).
    assert_nil user.instance_variable_get(:@session_token),
               "untrusted Klass.new must filter sessionToken even when objectId is present"
  end

  def test_initialize_with_objectId_filters_auth_data
    user = Parse::User.new(objectId: "victim",
                           authData: { "facebook" => { "id" => "fb1" } })
    assert_equal "victim", user.id
    # Read ivar directly to avoid autofetch (see sibling test).
    assert_nil user.instance_variable_get(:@auth_data),
               "untrusted Klass.new must filter authData even when objectId is present"
  end

  def test_initialize_with_objectId_allows_timestamps
    # Timestamps are in PROTECTED_MASS_ASSIGNMENT_KEYS (for attributes=
    # / Rails-form input) but explicitly NOT in PROTECTED_INITIALIZE_KEYS
    # so the legitimate cache-rehydrate / fixture-construction pattern
    # keeps working.
    iso = "2024-01-01T00:00:00.000Z"
    doc = TestDocument.new("objectId" => "id1",
                           "title" => "Hello",
                           "createdAt" => iso,
                           "updatedAt" => iso)
    assert_equal "id1", doc.id
    assert_equal "Hello", doc.title
    refute_nil doc.created_at
    refute_nil doc.updated_at
  end

  def test_object_build_is_trusted_hydration
    iso = "2024-01-01T00:00:00.000Z"
    user = Parse::User.build({ "objectId" => "u1",
                               "sessionToken" => "r:legit",
                               "createdAt" => iso,
                               "updatedAt" => iso })
    assert_equal "u1", user.id
    assert_equal "r:legit", user.session_token,
                 "Parse::Object.build must hydrate server-issued sessionToken"
  end

  def test_initialize_kwarg_style_attrs_still_work
    # Klass.new(title: "X") is a common construction style. The trusted
    # signal is carried via the @_trusted_init ivar rather than a
    # keyword argument specifically so this pattern keeps working AND
    # so subclasses that override initialize(*args) + super (Ruby 3
    # keyword-arg semantics) don't break.
    doc = TestDocument.new(title: "Hello", body: "World")
    assert_equal "Hello", doc.title
    assert_equal "World", doc.body
  end

  def test_subclass_initialize_with_splat_args_works
    # Regression test for the +**kwargs+ on Parse::Object#initialize
    # design that broke subclasses defining +def initialize(*args);
    # super; end+. Such subclasses must remain hydratable via
    # Parse::Object.build because the build path is what server JSON
    # responses go through.
    sub_class = Class.new(Parse::Object) do
      self.parse_class = "InitTrackerTestClass"
      property :title, :string
      attr_accessor :init_log
      def initialize(*args)
        super
        @init_log = "ran"
      end
    end

    obj = sub_class.build({ "objectId" => "abc",
                            "title" => "Hello",
                            "createdAt" => "2024-01-01T00:00:00.000Z" })
    assert_equal "abc", obj.id
    assert_equal "Hello", obj.title
    assert_equal "ran", obj.init_log, "subclass initialize override must still fire"
  end
end
