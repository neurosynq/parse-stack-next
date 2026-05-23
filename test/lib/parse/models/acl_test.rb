require_relative "../../../test_helper"

class Note < Parse::Object
  set_default_acl :public, read: true, write: false
  set_default_acl "123456", read: false, write: true
  set_default_acl "Admin", role: true, read: true, write: true
end

class TestACL < Minitest::Test
  NOTE_JSON_MASTER_KEY_ONLY = { :__type => "Object", :className => "Note", :objectId => "CEalzSpXRX", :createdAt => "2017-05-24T15:42:04.461Z", :updatedAt => "2017-06-10T01:13:51.581Z", :ACL => {} }
  NOTE_JSON_WRITE_ONLY = { :__type => "Object", :className => "Note", :objectId => "izByXF5L4w", :createdAt => "2017-06-06T21:16:23.463Z", :updatedAt => "2017-06-06T21:16:23.463Z", :ACL => { "*" => { "write" => true } } }
  NOTE_JSON_READ_AND_WRITE = { :__type => "Object", :className => "Note", :objectId => "izByXF5L4w", :createdAt => "2017-06-06T21:16:23.463Z", :updatedAt => "2017-06-06T21:16:23.463Z", :ACL => { "*" => { "read" => true, "write" => true } } }
  NOTE_EDGE_CASE_SHOULD_BE_AFFECTED = { :__type => "Object", :className => "Note", :objectId => "CEalzSpXRX", :createdAt => "2017-05-24T15:42:04.461Z", :updatedAt => "2017-06-10T01:13:51.581Z" }
  READ_ONLY = { read: true }
  WRITE_ONLY = { write: true }
  READ_AND_WRITE = { read: true, write: true }
  MASTER_KEY_ONLY = {}
  PUBLIC_READ_AND_WRITE = { "*" => { "read" => true, "write" => true } }
  PUBLIC_READ_ONLY = { "*" => { "read" => true } }
  PUBLIC_WRITE_ONLY = { "*" => { "write" => true } }

  def setup
    # master_key_only = Parse::ACL.new
    # public_read_only = Parse::ACL.everyone(true, false)
    # public_write_only = Parse::ACL.new({Parse::ACL::PUBLIC => {read: write}})
  end

  def test_acl
    assert Parse::ACL < Parse::DataType
    assert_equal Parse::ACL::PUBLIC, "*"
    assert_equal Parse::ACL.new(PUBLIC_READ_AND_WRITE), PUBLIC_READ_AND_WRITE
    assert_equal Parse::ACL.new(PUBLIC_READ_ONLY), PUBLIC_READ_ONLY
    assert_equal Parse::ACL.new(PUBLIC_WRITE_ONLY), PUBLIC_WRITE_ONLY
    assert_equal Parse::ACL.new(MASTER_KEY_ONLY), MASTER_KEY_ONLY
    assert_equal Parse::ACL.new, MASTER_KEY_ONLY

    assert_equal Parse::ACL.everyone.as_json, PUBLIC_READ_AND_WRITE
    assert_equal Parse::ACL.everyone(true, true).as_json, PUBLIC_READ_AND_WRITE
    assert_equal Parse::ACL.everyone(true).as_json, PUBLIC_READ_AND_WRITE
    assert_equal Parse::ACL.everyone(true, false).as_json, PUBLIC_READ_ONLY
    assert_equal Parse::ACL.everyone(false, true).as_json, PUBLIC_WRITE_ONLY
    assert_equal Parse::ACL.everyone(false, false).as_json, MASTER_KEY_ONLY
    refute_equal Parse::ACL.everyone.as_json, MASTER_KEY_ONLY

    assert_equal Parse::ACL.new(Parse::ACL.everyone(true, true)).as_json, PUBLIC_READ_AND_WRITE
    assert_equal Parse::ACL.new(Parse::ACL.everyone(true, true)).as_json, PUBLIC_READ_AND_WRITE
    assert_equal Parse::ACL.new(Parse::ACL.everyone(true, false)).as_json, PUBLIC_READ_ONLY
    assert_equal Parse::ACL.new(Parse::ACL.everyone(false, true)).as_json, PUBLIC_WRITE_ONLY
    assert_equal Parse::ACL.new(Parse::ACL.everyone(false, false)).as_json, MASTER_KEY_ONLY
    acl = Parse::ACL.new
    acl.apply :public, true, true
    assert_equal acl, Parse::ACL.everyone
    acl.apply :public, true, false
    assert_equal acl, Parse::ACL.everyone(true, false)
    acl.apply :public, false, true
    assert_equal acl, Parse::ACL.everyone(false, true)
    acl.apply :public, false, false
    assert_equal acl, Parse::ACL.everyone(false, false)

    assert acl.respond_to?(:world)
    assert_equal acl.method(:world).original_name, :everyone
  end

  def test_acl_role
    role = "Admin"
    acl = Parse::ACL.new(PUBLIC_READ_AND_WRITE)
    acl_hash = { "*" => { "read" => true, "write" => true } }
    assert_equal acl, acl_hash
    assert_equal acl, Parse::ACL.new(acl_hash)
    acl_hash["role:#{role}"] = { "read" => true }
    acl.apply_role role, true, false
    assert_equal acl, acl_hash
    assert_equal acl, Parse::ACL.new(acl_hash)

    acl_hash["role:#{role}"] = { "write" => true }
    acl.apply_role role, false, true
    assert_equal acl, acl_hash
    assert_equal acl, Parse::ACL.new(acl_hash)

    acl_hash["role:#{role}"] = { "read" => true, "write" => true }
    acl.apply_role role, true, true
    assert_equal acl, acl_hash
    assert_equal acl, Parse::ACL.new(acl_hash)

    acl_hash.delete "role:#{role}"
    acl.apply_role role, false, false
    assert_equal acl, acl_hash
    assert_equal acl, Parse::ACL.new(acl_hash)

    assert acl.respond_to?(:add_role)
    assert_equal acl.method(:add_role).original_name, :apply_role
  end

  def test_acl_id
    id = "123456"
    acl = Parse::ACL.new(PUBLIC_READ_AND_WRITE)

    acl_hash = { "*" => { "read" => true, "write" => true } }
    assert_equal acl, acl_hash
    assert_equal acl, Parse::ACL.new(acl_hash)

    acl_hash[id] = { "read" => true }
    acl.apply id, true, false
    assert_equal acl, acl_hash
    assert_equal acl, Parse::ACL.new(acl_hash)

    acl_hash[id] = { "write" => true }
    acl.apply id, false, true
    assert_equal acl, acl_hash
    assert_equal acl, Parse::ACL.new(acl_hash)

    acl_hash[id] = { "read" => true, "write" => true }
    acl.apply id, true, true
    assert_equal acl, acl_hash
    assert_equal acl, Parse::ACL.new(acl_hash)

    acl_hash.delete id
    acl.apply id, false, false
    assert_equal acl, acl_hash
    assert_equal acl, Parse::ACL.new(acl_hash)

    assert acl.respond_to?(:add)
    assert_equal acl.method(:add).original_name, :apply
  end

  def test_set_default_acl
    expected_default_acls = { "*" => { "read" => true }, "123456" => { "write" => true }, "role:Admin" => { "read" => true, "write" => true } }
    note = Note.new
    assert_equal Note.default_acls, expected_default_acls
    assert_equal note.acl, expected_default_acls
    assert_equal note.acl, Note.default_acls

    # Should cause no change.
    Note.set_default_acl "anthony", read: false, write: false

    note = Note.new
    assert_equal Note.default_acls, expected_default_acls
    assert_equal note.acl, expected_default_acls
    assert_equal note.acl, Note.default_acls

    # Should cause change.
    Note.set_default_acl "anthony", read: true, write: false
    expected_default_acls = { "*" => { "read" => true }, "anthony" => { "read" => true }, "123456" => { "write" => true }, "role:Admin" => { "read" => true, "write" => true } }
    note = Note.new
    assert_equal Note.default_acls, expected_default_acls
    assert_equal note.acl, expected_default_acls
    assert_equal note.acl, Note.default_acls

    # Override should cause change.
    Note.set_default_acl :public, read: false, write: false
    expected_default_acls = { "anthony" => { "read" => true }, "123456" => { "write" => true }, "role:Admin" => { "read" => true, "write" => true } }
    note = Note.new
    assert_equal Note.default_acls, expected_default_acls
    assert_equal note.acl, expected_default_acls
    assert_equal note.acl, Note.default_acls

    # these should not be affected by set_default_acl on the Note class as imported objects.
    note_master_key_only = Parse::Object.build NOTE_JSON_MASTER_KEY_ONLY
    note_write_only = Parse::Object.build NOTE_JSON_WRITE_ONLY
    note_read_and_write = Parse::Object.build NOTE_JSON_READ_AND_WRITE
    note_edge_case = Parse::Object.build NOTE_EDGE_CASE_SHOULD_BE_AFFECTED

    assert_equal note_master_key_only.acl, {}
    assert_equal note_write_only.acl, { "*" => { "write" => true } }
    assert_equal note_read_and_write.acl, { "*" => { "read" => true, "write" => true } }
    assert_equal note_edge_case.acl, Note.default_acls # should be affected because ACL is nil
    refute_equal note_master_key_only, Note.default_acls
    refute_equal note_write_only, Note.default_acls
    refute_equal note_read_and_write, Note.default_acls
  end

  def test_readable_by_with_single_values
    # Setup ACL with various permissions
    acl = Parse::ACL.new
    acl.apply(:public, read: true, write: false)
    acl.apply("user123", read: true, write: true)
    acl.apply("user456", read: false, write: true)
    acl.apply_role("Admin", read: true, write: true)
    acl.apply_role("Editor", read: true, write: false)
    acl.apply_role("Writer", read: false, write: true)

    # Test public read access
    assert acl.readable_by?("*")
    assert acl.readable_by?(:public)

    # Test user read access
    assert acl.readable_by?("user123")
    refute acl.readable_by?("user456")  # Has write but not read
    refute acl.readable_by?("user789")  # Doesn't exist

    # Test role read access
    assert acl.readable_by?("Admin")
    assert acl.readable_by?("role:Admin")
    assert acl.readable_by?("Editor")
    refute acl.readable_by?("Writer")  # Has write but not read
    refute acl.readable_by?("Viewer")  # Doesn't exist

    # Test aliases
    assert acl.can_read?("user123")
    refute acl.can_read?("user456")
  end

  def test_readable_by_with_arrays
    # Setup ACL
    acl = Parse::ACL.new
    acl.apply("user123", read: true, write: false)
    acl.apply("user456", read: false, write: true)
    acl.apply_role("Admin", read: true, write: true)
    acl.apply_role("Editor", read: false, write: true)

    # Test array with one readable user - should return true
    assert acl.readable_by?(["user123"])

    # Test array with one non-readable user - should return false
    refute acl.readable_by?(["user456"])

    # Test array with multiple users where one is readable - should return true (OR logic)
    assert acl.readable_by?(["user123", "user456"])
    assert acl.readable_by?(["user456", "user123"])
    assert acl.readable_by?(["user999", "user123"])

    # Test array with no readable users - should return false
    refute acl.readable_by?(["user456", "user789"])

    # Test array with roles
    assert acl.readable_by?(["Admin"])
    refute acl.readable_by?(["Editor"])
    assert acl.readable_by?(["Admin", "Editor"])  # Admin is readable

    # Test mixed array with users and roles
    assert acl.readable_by?(["user999", "Editor", "Admin"])  # Admin is readable
    assert acl.readable_by?(["user123", "Writer"])  # user123 is readable
    refute acl.readable_by?(["user456", "Editor", "Writer"])  # None are readable

    # Test empty array - should return false
    refute acl.readable_by?([])
  end

  def test_writeable_by_with_single_values
    # Setup ACL with various permissions
    acl = Parse::ACL.new
    acl.apply(:public, read: true, write: false)
    acl.apply("user123", read: true, write: true)
    acl.apply("user456", read: true, write: false)
    acl.apply_role("Admin", read: true, write: true)
    acl.apply_role("Editor", read: false, write: true)
    acl.apply_role("Viewer", read: true, write: false)

    # Test public write access
    refute acl.writeable_by?("*")
    refute acl.writeable_by?(:public)

    # Test user write access
    assert acl.writeable_by?("user123")
    refute acl.writeable_by?("user456")  # Has read but not write
    refute acl.writeable_by?("user789")  # Doesn't exist

    # Test role write access
    assert acl.writeable_by?("Admin")
    assert acl.writeable_by?("role:Admin")
    assert acl.writeable_by?("Editor")
    refute acl.writeable_by?("Viewer")  # Has read but not write
    refute acl.writeable_by?("Writer")  # Doesn't exist

    # Test aliases
    assert acl.writable_by?("user123")
    assert acl.can_write?("user123")
    refute acl.can_write?("user456")
  end

  def test_writeable_by_with_arrays
    # Setup ACL
    acl = Parse::ACL.new
    acl.apply("user123", read: false, write: true)
    acl.apply("user456", read: true, write: false)
    acl.apply_role("Admin", read: true, write: true)
    acl.apply_role("Viewer", read: true, write: false)

    # Test array with one writable user - should return true
    assert acl.writeable_by?(["user123"])

    # Test array with one non-writable user - should return false
    refute acl.writeable_by?(["user456"])

    # Test array with multiple users where one is writable - should return true (OR logic)
    assert acl.writeable_by?(["user123", "user456"])
    assert acl.writeable_by?(["user456", "user123"])
    assert acl.writeable_by?(["user999", "user123"])

    # Test array with no writable users - should return false
    refute acl.writeable_by?(["user456", "user789"])

    # Test array with roles
    assert acl.writeable_by?(["Admin"])
    refute acl.writeable_by?(["Viewer"])
    assert acl.writeable_by?(["Admin", "Viewer"])  # Admin is writable

    # Test mixed array with users and roles
    assert acl.writeable_by?(["user999", "Viewer", "Admin"])  # Admin is writable
    assert acl.writeable_by?(["user123", "Viewer"])  # user123 is writable
    refute acl.writeable_by?(["user456", "Viewer", "Writer"])  # None are writable

    # Test empty array - should return false
    refute acl.writeable_by?([])

    # Test writable_by? alias
    assert acl.writable_by?(["user123", "user456"])
  end

  def test_owner_with_single_values
    # Setup ACL with various permissions
    acl = Parse::ACL.new
    acl.apply(:public, read: true, write: false)
    acl.apply("user123", read: true, write: true)  # Owner
    acl.apply("user456", read: true, write: false)  # Read-only
    acl.apply("user789", read: false, write: true)  # Write-only
    acl.apply_role("Admin", read: true, write: true)  # Owner
    acl.apply_role("Editor", read: true, write: false)  # Read-only
    acl.apply_role("Writer", read: false, write: true)  # Write-only

    # Test public is not an owner (has read but not write)
    refute acl.owner?("*")
    refute acl.owner?(:public)

    # Test user ownership
    assert acl.owner?("user123")  # Has both read and write
    refute acl.owner?("user456")  # Has read but not write
    refute acl.owner?("user789")  # Has write but not read
    refute acl.owner?("user999")  # Doesn't exist

    # Test role ownership
    assert acl.owner?("Admin")
    assert acl.owner?("role:Admin")
    refute acl.owner?("Editor")  # Has read but not write
    refute acl.owner?("Writer")  # Has write but not read
    refute acl.owner?("Viewer")  # Doesn't exist
  end

  def test_owner_with_arrays
    # Setup ACL
    acl = Parse::ACL.new
    acl.apply("user123", read: true, write: true)  # Owner
    acl.apply("user456", read: true, write: false)  # Read-only
    acl.apply("user789", read: false, write: true)  # Write-only
    acl.apply_role("Admin", read: true, write: true)  # Owner
    acl.apply_role("Editor", read: true, write: false)  # Read-only

    # Test array with one owner - should return true
    assert acl.owner?(["user123"])

    # Test array with one non-owner - should return false
    refute acl.owner?(["user456"])
    refute acl.owner?(["user789"])

    # Test array with multiple users where one is an owner - should return true (OR logic)
    assert acl.owner?(["user123", "user456"])
    assert acl.owner?(["user456", "user123"])
    assert acl.owner?(["user999", "user123"])

    # Test array with no owners - should return false
    refute acl.owner?(["user456", "user789"])
    refute acl.owner?(["user456", "user999"])

    # Test array with roles
    assert acl.owner?(["Admin"])
    refute acl.owner?(["Editor"])
    assert acl.owner?(["Admin", "Editor"])  # Admin is an owner

    # Test mixed array with users and roles
    assert acl.owner?(["user999", "Editor", "Admin"])  # Admin is an owner
    assert acl.owner?(["user123", "Editor"])  # user123 is an owner
    refute acl.owner?(["user456", "Editor", "Writer"])  # None are owners

    # Test empty array - should return false
    refute acl.owner?([])
  end

  def test_readable_by_writeable_by_and_owner_helper_methods
    # Setup ACL with various permissions
    acl = Parse::ACL.new
    acl.apply("owner_user", read: true, write: true)
    acl.apply("read_user", read: true, write: false)
    acl.apply("write_user", read: false, write: true)
    acl.apply_role("OwnerRole", read: true, write: true)
    acl.apply_role("ReadRole", read: true, write: false)
    acl.apply_role("WriteRole", read: false, write: true)

    # Test readable_by returns correct list
    readable = acl.readable_by
    assert_includes readable, "owner_user"
    assert_includes readable, "read_user"
    refute_includes readable, "write_user"
    assert_includes readable, "role:OwnerRole"
    assert_includes readable, "role:ReadRole"
    refute_includes readable, "role:WriteRole"

    # Test writeable_by returns correct list
    writeable = acl.writeable_by
    assert_includes writeable, "owner_user"
    refute_includes writeable, "read_user"
    assert_includes writeable, "write_user"
    assert_includes writeable, "role:OwnerRole"
    refute_includes writeable, "role:ReadRole"
    assert_includes writeable, "role:WriteRole"

    # Test owners returns correct list (both read and write)
    owners = acl.owners
    assert_includes owners, "owner_user"
    refute_includes owners, "read_user"
    refute_includes owners, "write_user"
    assert_includes owners, "role:OwnerRole"
    refute_includes owners, "role:ReadRole"
    refute_includes owners, "role:WriteRole"
  end

  def test_readable_by_with_user_object_and_role_expansion
    # Create a simple user-like object with parse_class and id (acts like a Parse pointer)
    user = OpenStruct.new(id: "user123", parse_class: "_User")

    # Create simple role objects
    admin_role = OpenStruct.new(name: "Admin")
    editor_role = OpenStruct.new(name: "Editor")

    # Mock Parse::Role.all to return the user's roles
    Parse::Role.stub :all, [admin_role, editor_role] do
      # Setup ACL - user has direct read access, Admin role has read access
      acl = Parse::ACL.new
      acl.apply("user123", read: true, write: false)
      acl.apply_role("Admin", read: true, write: false)
      acl.apply_role("Editor", read: false, write: true)
      acl.apply_role("Viewer", read: true, write: false)

      # Test that readable_by? with User object checks both user ID and their roles
      # Should return true because:
      # 1. user123 has direct read access
      # 2. Admin role (which user belongs to) has read access
      assert acl.readable_by?(user), "User should be readable (direct access + Admin role)"
    end
  end

  def test_readable_by_with_user_object_role_only_access
    # Create a simple user-like object
    user = OpenStruct.new(id: "user456", parse_class: "_User")

    # Create simple role object
    moderator_role = OpenStruct.new(name: "Moderator")

    Parse::Role.stub :all, [moderator_role] do
      # Setup ACL - user has NO direct access, but Moderator role has read access
      acl = Parse::ACL.new
      acl.apply_role("Moderator", read: true, write: false)
      acl.apply_role("Admin", read: false, write: true)

      # Should return true because Moderator role has read access
      assert acl.readable_by?(user), "User should be readable via Moderator role"
    end
  end

  def test_readable_by_with_user_pointer_and_role_expansion
    # Create a simple user pointer-like object
    user_pointer = OpenStruct.new(id: "user789", parse_class: "User")

    # Create simple role object
    admin_role = OpenStruct.new(name: "Admin")

    Parse::Role.stub :all, [admin_role] do
      # Setup ACL - only Admin role has read access (not the user directly)
      acl = Parse::ACL.new
      acl.apply_role("Admin", read: true, write: true)
      acl.apply("other_user", read: true, write: false)

      # Should return true because Admin role (which user belongs to) has read access
      assert acl.readable_by?(user_pointer), "User pointer should be readable via Admin role"
    end
  end

  def test_writeable_by_with_user_object_and_role_expansion
    # Create a simple user-like object
    user = OpenStruct.new(id: "user123", parse_class: "_User")

    # Create simple role object
    admin_role = OpenStruct.new(name: "Admin")

    Parse::Role.stub :all, [admin_role] do
      # Setup ACL - user has NO direct write, but Admin role has write access
      acl = Parse::ACL.new
      acl.apply("user123", read: true, write: false)
      acl.apply_role("Admin", read: true, write: true)

      # Should return true because Admin role has write access
      assert acl.writeable_by?(user), "User should be writeable via Admin role"
    end
  end

  def test_owner_with_user_object_and_role_expansion
    # Create a simple user-like object
    user = OpenStruct.new(id: "user123", parse_class: "_User")

    # Create simple role object
    owner_role = OpenStruct.new(name: "Owner")

    Parse::Role.stub :all, [owner_role] do
      # Setup ACL - user has read but not write, Owner role has both
      acl = Parse::ACL.new
      acl.apply("user123", read: true, write: false)
      acl.apply_role("Owner", read: true, write: true)

      # Should return true because Owner role has both read and write
      assert acl.owner?(user), "User should be owner via Owner role"
    end
  end

  def test_user_object_without_roles
    # Create a simple user-like object
    user = OpenStruct.new(id: "user999", parse_class: "_User")

    Parse::Role.stub :all, [] do
      # Setup ACL - only this user has direct access
      acl = Parse::ACL.new
      acl.apply("user999", read: true, write: true)

      # Should return true because user has direct access (no roles needed)
      assert acl.readable_by?(user), "User should be readable via direct access"
      assert acl.writeable_by?(user), "User should be writeable via direct access"
      assert acl.owner?(user), "User should be owner via direct access"
    end
  end

  def test_user_object_with_role_fetch_failure
    # Create a simple user-like object
    user = OpenStruct.new(id: "user888", parse_class: "_User")

    # Simulate role fetch failure
    Parse::Role.stub :all, -> (_) { raise StandardError, "Network error" } do
      # Setup ACL - user has direct read access
      acl = Parse::ACL.new
      acl.apply("user888", read: true, write: false)

      # Should still work with just the user ID (graceful degradation)
      assert acl.readable_by?(user), "Should work with user ID even if role fetch fails"
    end
  end

  def test_user_pointer_to_non_user_class
    # Create a simple pointer-like object to a different class (not User)
    pointer = OpenStruct.new(id: "team123", parse_class: "Team")

    # Setup ACL
    acl = Parse::ACL.new
    acl.apply_role("Admin", read: true, write: true)

    # Should NOT expand roles for non-User pointers, should check the key directly
    refute acl.readable_by?(pointer), "Non-User pointer should not trigger role expansion"
  end
end
