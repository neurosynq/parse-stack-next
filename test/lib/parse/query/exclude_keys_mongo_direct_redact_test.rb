# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Parse Server's REST `excludeKeys` has no mongo-direct equivalent (the direct
# pipeline can only project the `keys` allowlist), so the SDK honors the
# denylist on the mongo-direct path as a post-fetch sanitize: it recursively
# drops every key with a matching name from the returned Parse-format hashes
# without touching the MongoDB query. These tests drive the redaction helper
# directly over hashes, so they need no live MongoDB.
class TestExcludeKeysMongoDirectRedact < Minitest::Test
  def redact(table, fields, results)
    query = Parse::Query.new(table)
    query.exclude_keys(*fields)
    query.send(:redact_excluded_keys!, results)
  end

  def test_drops_matching_top_level_key
    rows = [{ "objectId" => "a1", "title" => "Hi", "secretToken" => "xyz" }]
    redact("Post", [:secret_token], rows)
    refute rows.first.key?("secretToken")
    assert_equal "Hi", rows.first["title"]
  end

  def test_noop_when_no_exclude_keys
    rows = [{ "objectId" => "a1", "secretToken" => "xyz" }]
    redact("Post", [], rows)
    assert_equal "xyz", rows.first["secretToken"]
  end

  def test_recurses_into_nested_included_objects
    # exclude_keys(:name) must also strip a same-named field inside an
    # included/nested object — the recursive-by-name contract.
    rows = [{
      "objectId" => "a1",
      "name"     => "outer",
      "author"   => { "objectId" => "u1", "name" => "inner", "email" => "x@y" },
    }]
    redact("Post", [:name], rows)
    refute rows.first.key?("name")
    refute rows.first["author"].key?("name")
    assert_equal "x@y", rows.first["author"]["email"]
  end

  def test_recurses_through_arrays
    rows = [{
      "objectId" => "a1",
      "comments" => [
        { "body" => "one", "secretToken" => "s1" },
        { "body" => "two", "secretToken" => "s2" },
      ],
    }]
    redact("Post", [:secret_token], rows)
    rows.first["comments"].each do |c|
      refute c.key?("secretToken")
      refute_nil c["body"]
    end
  end

  def test_field_name_camelized_like_rest_path
    # exclude_keys runs field names through format_field (snake -> camel),
    # matching the camelCase keys mongo/Parse produce.
    rows = [{ "objectId" => "a1", "internalNotes" => "secret" }]
    redact("Post", [:internal_notes], rows)
    refute rows.first.key?("internalNotes")
  end

  # --- Structural-key protection: dropping these would break decode or
  #     diverge from Parse Server's reserved envelope. ---

  def test_objectId_is_never_stripped
    rows = [{ "objectId" => "a1", "title" => "Hi" }]
    redact("Post", [:objectId], rows)
    assert_equal "a1", rows.first["objectId"],
      "objectId must survive exclude_keys so decode can reconstruct the object"
  end

  def test_className_and_type_never_stripped
    rows = [{ "objectId" => "a1", "className" => "Post", "__type" => "Object" }]
    redact("Post", [:className, :__type], rows)
    assert_equal "Post", rows.first["className"]
    assert_equal "Object", rows.first["__type"]
  end

  def test_reserved_timestamp_and_acl_fields_protected
    rows = [{
      "objectId"  => "a1",
      "createdAt" => "2026-01-01T00:00:00.000Z",
      "updatedAt" => "2026-01-02T00:00:00.000Z",
      "ACL"       => { "*" => { "read" => true } },
    }]
    redact("Post", [:createdAt, :updatedAt, :ACL], rows)
    assert rows.first.key?("createdAt")
    assert rows.first.key?("updatedAt")
    assert rows.first.key?("ACL")
  end

  def test_mongo_storage_form_reserved_keys_protected
    # Defensive: even on a raw Mongo-form document, the storage-form reserved
    # keys survive so reconstruction can't be broken by excluding them.
    rows = [{
      "_id"          => "a1",
      "_created_at"  => "t1",
      "_updated_at"  => "t2",
      "_acl"         => { "*" => { "r" => true } },
      "secretToken"  => "xyz",
    }]
    redact("Post", [:_id, :_created_at, :_updated_at, :_acl, :secret_token], rows)
    assert rows.first.key?("_id")
    assert rows.first.key?("_created_at")
    assert rows.first.key?("_updated_at")
    assert rows.first.key?("_acl")
    refute rows.first.key?("secretToken")
  end

  def test_mixed_reserved_and_user_field
    # Excluding both a reserved and a user field keeps the reserved one,
    # drops only the user field.
    rows = [{ "objectId" => "a1", "createdAt" => "t", "secretToken" => "xyz" }]
    redact("Post", [:objectId, :createdAt, :secret_token], rows)
    assert_equal "a1", rows.first["objectId"]
    assert rows.first.key?("createdAt")
    refute rows.first.key?("secretToken")
  end

  def test_returns_the_same_array_reference
    rows = [{ "objectId" => "a1", "secretToken" => "xyz" }]
    result = redact("Post", [:secret_token], rows)
    assert_same rows, result
  end
end
