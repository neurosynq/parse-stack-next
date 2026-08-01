require_relative "../../../test_helper"

class ACLAccessHelperDocument < Parse::Object
  parse_class "ACLAccessHelperDocument"
  acl_policy :private

  belongs_to :owner, as: :user
  property :editors, :array
end

class ACLAccessInvalidPointerDocument < Parse::Object
  parse_class "ACLAccessInvalidPointerDocument"
  acl_policy :private

  property :owner, :object
end

class ACLAccessHelpersTest < Minitest::Test
  ABSENT_ACL = Object.new.freeze

  def setup
    Parse.setup(
      server_url: "http://localhost:1337/parse",
      application_id: "test",
      api_key: "test",
    ) unless Parse::Client.client?
    @client = Parse::Client.client
    Parse::CLPScope.reset_cache!
    cache_clp({})

    @user = Parse::User.new
    @user.id = "u_alice"
    @user.session_token = "r:alice-session"
    @other_user = Parse::User.new
    @other_user.id = "u_bob"
    @other_user.session_token = "r:bob-session"
    @role = Parse::Role.new(name: "Admin")
    @role.id = "r_admin"
  end

  def teardown
    Parse::CLPScope.reset_cache!
  end

  def test_helpers_expose_boolean_and_evidence_bearing_apis
    assert_respond_to @user, :can_read?
    assert_respond_to @user, :can_write?
    assert_respond_to @user, :can_delete?
    assert_respond_to @user, :access_decision
    assert_respond_to @user, :access_decisions
    assert_respond_to @role, :can_read?
    assert_respond_to @role, :can_write?
    assert_respond_to @role, :can_delete?

    decision = @user.access_decision(document_with(Parse::ACL.everyone), :read)
    assert_instance_of Parse::Access::Decision, decision
    assert decision.allowed?
    assert_equal :allowed, decision.status
  end

  def test_acl_and_clp_are_both_required_and_delete_uses_acl_write
    cache_clp(
      "get" => {},
      "update" => { "*" => true },
      "delete" => { "*" => true },
    )
    document = document_with(Parse::ACL.everyone(true, false))

    refute @user.can_read?(document)
    refute @user.can_write?(document)
    refute @user.can_delete?(document)
    refute @role.can_read?(document)
    refute @role.can_write?(document)
    refute @role.can_delete?(document)
  end

  def test_full_hydration_without_acl_uses_parse_public_default
    document = document_with(ABSENT_ACL)

    # The Ruby class's local default remains private, but the trusted full row
    # proves that Parse Server omitted ACL and therefore treats it as public.
    assert_equal :absent, document.authorization_acl_state
    assert @user.can_read?(document)
    assert @user.can_write?(document)
    assert @user.can_delete?(document)
    assert @role.can_read?(document)
    assert @role.can_write?(document)
    assert @role.can_delete?(document)
  end

  def test_pointer_and_partial_target_are_unknown_and_boolean_helpers_fail_closed
    pointer = ACLAccessHelperDocument.new("doc_pointer")
    partial = ACLAccessHelperDocument.build(
      { "objectId" => "doc_partial", "title" => "partial" },
      fetched_keys: [:title],
    )

    pointer_decision = @user.access_decision(pointer, :read)
    partial_decision = @user.access_decision(partial, :read)
    assert pointer_decision.unknown?
    assert_includes pointer_decision.reasons, :target_is_pointer
    assert partial_decision.unknown?
    assert_includes partial_decision.reasons, :target_partially_fetched
    refute @user.can_read?(pointer)
    refute @user.can_read?(partial)
  end

  def test_untrusted_id_hash_does_not_claim_authoritative_acl_state
    target = ACLAccessHelperDocument.new(
      "objectId" => "doc_untrusted",
      "createdAt" => "2026-01-01T00:00:00.000Z",
      "updatedAt" => "2026-01-01T00:00:00.000Z",
      "ACL" => Parse::ACL.everyone.as_json,
    )

    assert_equal :unknown, target.authorization_acl_state
    decision = @user.access_decision(target, :read)
    assert decision.unknown?
    assert_includes decision.reasons, :acl_unavailable
    refute @user.can_read?(target)
  end

  def test_id_only_user_is_not_authenticated_and_does_not_trigger_role_lookup
    id_only = Parse::User.new
    id_only.id = @user.id
    acl = Parse::ACL.private
    acl.apply(@user.id, read: true, write: true)
    document = document_with(acl)
    unexpected_lookup = ->(*, **) { raise "role lookup must not run" }

    Parse::Role.stub(:all_for_user, unexpected_lookup) do
      decision = id_only.access_decision(document, :read)
      assert decision.unknown?
      assert_includes decision.reasons, :authentication_unverified
      refute id_only.can_read?(document)
    end

    assert id_only.can_read?(document_with(Parse::ACL.everyone(true, false))),
           "public access does not require authentication"
  end

  def test_direct_user_and_inherited_role_grants
    acl = Parse::ACL.private
    acl.apply(@user.id, read: true, write: false)
    direct = document_with(acl)
    assert @user.can_read?(direct)
    refute @user.can_write?(direct)

    cache_clp(
      "get" => { "role:Moderator" => true },
      "update" => { "role:Moderator" => true },
      "delete" => { "role:Moderator" => true },
    )
    inherited_acl = Parse::ACL.private
    inherited_acl.apply_role("Moderator", read: true, write: true)
    inherited = document_with(inherited_acl)

    Parse::Role.stub(:all_for_user, Set["Member", "Moderator"]) do
      assert @user.can_read?(inherited)
      assert @user.can_write?(inherited)
      assert @user.can_delete?(inherited)
    end
  end

  def test_direct_role_grants_skip_parent_lookup_and_parent_grants_are_inherited
    cache_clp(
      "get" => { "role:Admin" => true },
      "update" => { "role:Admin" => true },
      "delete" => { "role:Admin" => true },
    )
    acl = Parse::ACL.private
    acl.apply_role("Admin", read: true, write: true)
    direct = document_with(acl)
    unexpected_lookup = ->(**) { raise "parent lookup should not run" }

    @role.stub(:all_parent_role_names, unexpected_lookup) do
      assert @role.can_read?(direct)
      assert @role.can_write?(direct)
      assert @role.can_delete?(direct)
    end

    cache_clp(
      "get" => { "role:Moderator" => true },
      "update" => { "role:Moderator" => true },
      "delete" => { "role:Moderator" => true },
    )
    parent_acl = Parse::ACL.private
    parent_acl.apply_role("Moderator", read: true, write: true)
    inherited = document_with(parent_acl)
    @role.stub(:all_parent_role_names, Set["Admin", "Moderator"]) do
      assert @role.can_read?(inherited)
      assert @role.can_write?(inherited)
      assert @role.can_delete?(inherited)
    end
  end

  def test_role_lookup_failure_is_unknown
    cache_clp("get" => { "role:Moderator" => true })
    acl = Parse::ACL.private
    acl.apply_role("Moderator", read: true, write: false)
    document = document_with(acl)
    failure = ->(*, **) { raise IOError, "offline" }

    Parse::Role.stub(:all_for_user, failure) do
      decision = @user.access_decision(document, :read)
      assert decision.unknown?
      assert_includes decision.reasons, :role_membership_unavailable
      refute @user.can_read?(document)
    end
  end

  def test_id_only_role_stays_unknown_without_autofetching_its_name
    cache_clp("get" => { "role:Moderator" => true })
    acl = Parse::ACL.private
    acl.apply_role("Moderator", read: true, write: false)
    document = document_with(acl)
    id_only_role = Parse::Role.new
    id_only_role.id = "r_unknown"
    unexpected_lookup = ->(**) { raise "parent lookup must not run" }

    id_only_role.stub(:all_parent_role_names, unexpected_lookup) do
      decision = id_only_role.access_decision(document, :read)
      assert decision.unknown?
      assert_includes decision.reasons, :role_identity_unavailable
    end
  end

  def test_check_all_reuses_one_role_closure
    cache_clp(
      "get" => { "role:Moderator" => true },
      "update" => { "role:Moderator" => true },
      "delete" => { "role:Moderator" => true },
    )
    acl = Parse::ACL.private
    acl.apply_role("Moderator", read: true, write: true)
    document = document_with(acl)
    calls = 0
    lookup = lambda do |*, **|
      calls += 1
      Set["Moderator"]
    end

    Parse::Role.stub(:all_for_user, lookup) do
      decisions = @user.access_decisions(document)
      assert decisions.values.all?(&:allowed?)
    end
    assert_equal 1, calls
  end

  def test_public_or_direct_role_clp_branch_bypasses_pointer_filter
    cache_clp(
      "get" => { "*" => true },
      "update" => { "role:Admin" => true },
      "readUserFields" => ["owner"],
      "writeUserFields" => ["owner"],
    )
    document = document_with(Parse::ACL.everyone, owner_id: "u_someone_else")

    assert @user.can_read?(document), "public get bypasses readUserFields"
    assert @role.can_write?(document), "direct role update bypasses writeUserFields"
  end

  def test_access_uses_the_explicit_clients_clp_cache_scope
    client_a = Parse::Client.new(
      server_url: "http://localhost:1337/parse",
      application_id: "access-app-a",
      api_key: "test",
    )
    client_b = Parse::Client.new(
      server_url: "http://localhost:1337/parse",
      application_id: "access-app-b",
      api_key: "test",
    )
    Parse::CLPScope.__cache_put(
      parse_class, clp: { "get" => { "*" => true } }, client: client_a,
    )
    Parse::CLPScope.__cache_put(
      parse_class, clp: { "get" => {} }, client: client_b,
    )
    document = document_with(Parse::ACL.everyone)

    assert @user.can_read?(document, client: client_a)
    refute @user.can_read?(document, client: client_b)
  end

  def test_requires_authentication_does_not_bypass_pointer_filter
    cache_clp(
      "get" => { "requiresAuthentication" => true },
      "update" => { "requiresAuthentication" => true },
      "delete" => { "requiresAuthentication" => true },
      "readUserFields" => ["owner"],
      "writeUserFields" => ["owner"],
    )
    owned = document_with(Parse::ACL.everyone, owner_id: @user.id)

    assert @user.can_read?(owned)
    assert @user.can_write?(owned)
    assert @user.can_delete?(owned)
    refute @other_user.can_read?(owned)
    refute @other_user.can_write?(owned)
    refute @other_user.can_delete?(owned)

    role_decision = @role.access_decision(owned, :read)
    assert role_decision.unknown?
    assert_includes role_decision.reasons, :concrete_user_required
    refute @role.can_read?(owned)
  end

  def test_grouped_user_field_is_a_fallback_even_with_empty_operation_map
    cache_clp(
      "get" => {},
      "update" => {},
      "delete" => {},
      "readUserFields" => ["owner"],
      "writeUserFields" => ["owner"],
    )
    owned = document_with(Parse::ACL.everyone, owner_id: @user.id)

    assert @user.can_read?(owned)
    assert @user.can_write?(owned)
    assert @user.can_delete?(owned)
    refute @other_user.can_read?(owned)
  end

  def test_included_full_user_satisfies_a_typed_pointer_field
    cache_clp(
      "get" => { "requiresAuthentication" => true },
      "readUserFields" => ["owner"],
    )
    owner = server_row(@user.id).merge(
      "__type" => "Object",
      "className" => Parse::Model::CLASS_USER,
    )
    row = server_row("doc_included_owner", acl: Parse::ACL.everyone)
    row["owner"] = owner
    document = ACLAccessHelperDocument.build(row)

    assert_instance_of Parse::User, document.instance_variable_get(:@owner)
    assert @user.can_read?(document)
  end

  def test_invalid_generic_object_user_field_is_unknown
    invalid_class = ACLAccessInvalidPointerDocument.parse_class
    cache_class_clp(
      invalid_class,
      "get" => { "requiresAuthentication" => true },
      "readUserFields" => ["owner"],
    )
    row = server_row("doc_invalid_owner", acl: Parse::ACL.everyone)
    row["owner"] = {
      "__type" => "Pointer",
      "className" => Parse::Model::CLASS_USER,
      "objectId" => @user.id,
    }
    document = ACLAccessInvalidPointerDocument.build(row)

    decision = @user.access_decision(document, :read)
    assert decision.unknown?
    assert_includes decision.reasons, :pointer_field_schema_unavailable
    refute @user.can_read?(document)
  end

  def test_local_pointer_change_is_unknown_for_a_persisted_row
    cache_clp(
      "get" => { "requiresAuthentication" => true },
      "readUserFields" => ["owner"],
    )
    document = document_with(Parse::ACL.everyone, owner_id: @user.id)
    document.owner = Parse::User.pointer(@other_user.id)

    decision = @user.access_decision(document, :read)
    assert decision.unknown?
    assert_includes decision.reasons, :pointer_field_has_local_changes
    refute @user.can_read?(document)
  end

  def test_user_class_self_rules_override_acl_but_not_clp
    cache_class_clp(Parse::Model::CLASS_USER, {})
    private_acl = Parse::ACL.private
    self_target = user_target(@user.id, private_acl)
    other_target = user_target(@other_user.id, Parse::ACL.everyone)

    assert @user.can_read?(self_target)
    assert @user.can_write?(self_target)
    assert @user.can_delete?(self_target)
    refute @user.can_write?(other_target), "users cannot update another _User row"
    refute @user.can_delete?(other_target), "users cannot delete another _User row"

    cache_class_clp(Parse::Model::CLASS_USER, "update" => {})
    refute @user.can_write?(self_target), "_User self-update remains subject to CLP"
  end

  def test_role_cannot_claim_user_self_write_or_delete
    cache_class_clp(Parse::Model::CLASS_USER, {})
    acl = Parse::ACL.private
    acl.apply_role(@role.name, read: true, write: true)
    target = user_target(@other_user.id, acl)

    assert @role.can_read?(target)
    write = @role.access_decision(target, :write)
    delete = @role.access_decision(target, :delete)
    assert write.unknown?
    assert delete.unknown?
    refute @role.can_write?(target)
    refute @role.can_delete?(target)
  end

  def test_role_does_not_use_an_object_id_sentinel_for_authenticated_clp
    cache_clp("get" => { "__parse_authenticated_role_member__" => true })
    acl = Parse::ACL.private
    acl.apply_role(@role.name, read: true, write: false)

    refute @role.can_read?(document_with(acl))
  end

  def test_role_records_use_normal_acl_and_clp_rules
    cache_class_clp(Parse::Model::CLASS_ROLE, {})
    acl = Parse::ACL.private
    acl.apply(@user.id, read: true, write: false)
    target = role_target("Target", acl)

    assert @user.can_read?(target)
    refute @user.can_write?(target)
    refute @user.can_delete?(target)
  end

  def test_unsupported_system_class_is_unknown
    cache_class_clp(Parse::Model::CLASS_INSTALLATION, {})
    installation = Parse::Installation.build(
      server_row("install_1", acl: Parse::ACL.everyone),
    )

    decision = @user.access_decision(installation, :read)
    assert decision.unknown?
    assert_includes decision.reasons, :unsupported_system_class
    refute @user.can_read?(installation)
  end

  def test_user_fields_for_maps_read_and_write_operations
    cache_clp(
      "readUserFields" => ["owner"],
      "writeUserFields" => ["editor"],
    )

    assert_equal ["owner"], Parse::CLPScope.user_fields_for(parse_class, :get, client: @client)
    assert_equal ["owner"], Parse::CLPScope.user_fields_for(parse_class, :find, client: @client)
    assert_equal ["editor"], Parse::CLPScope.user_fields_for(parse_class, :create, client: @client)
    assert_equal ["editor"], Parse::CLPScope.user_fields_for(parse_class, :update, client: @client)
  end

  private

  def parse_class
    ACLAccessHelperDocument.parse_class
  end

  def cache_clp(clp)
    cache_class_clp(parse_class, clp)
  end

  def cache_class_clp(class_name, clp)
    Parse::CLPScope.__cache_put(class_name, clp: clp, client: @client)
  end

  def document_with(acl, owner_id: nil)
    row = server_row("doc_1", acl: acl)
    if owner_id
      row["owner"] = {
        "__type" => "Pointer",
        "className" => Parse::Model::CLASS_USER,
        "objectId" => owner_id,
      }
    end
    ACLAccessHelperDocument.build(row)
  end

  def user_target(id, acl)
    Parse::User.build(server_row(id, acl: acl))
  end

  def role_target(name, acl)
    Parse::Role.build(server_row("role_target", acl: acl).merge("name" => name))
  end

  def server_row(id, acl: ABSENT_ACL)
    row = {
      "objectId" => id,
      "createdAt" => "2026-01-01T00:00:00.000Z",
      "updatedAt" => "2026-01-01T00:00:00.000Z",
    }
    row["ACL"] = acl.as_json unless acl.equal?(ABSENT_ACL)
    row
  end
end
