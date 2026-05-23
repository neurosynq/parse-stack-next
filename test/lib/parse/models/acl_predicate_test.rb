# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Unit tests for Parse::ACL.read_predicate / write_predicate. These
# helpers were extracted from the four ACL query-constraint classes to
# eliminate duplication and to give the Atlas Search ACL injection
# path a shared, audited implementation. The contract:
#
#   * Always emit the canonical { "$or" => [{"_rperm" => {"$in"=>...}},
#     {"_rperm" => {"$exists" => false}}] } shape, including the
#     $exists branch (Parse Server treats a missing _rperm as public,
#     so dropping the $exists branch silently hides every public
#     document).
#   * Append "*" by default; suppress with include_public: false.
#   * Coerce input to strings, dedupe, drop empties.
class ACLPredicateTest < Minitest::Test
  def test_read_predicate_appends_public_by_default
    pred = Parse::ACL.read_predicate(["user123", "role:Admin"])
    assert_equal(
      {
        "$or" => [
          { "_rperm" => { "$in" => ["user123", "role:Admin", "*"] } },
          { "_rperm" => { "$exists" => false } },
        ],
      },
      pred,
    )
  end

  def test_read_predicate_does_not_duplicate_existing_public
    pred = Parse::ACL.read_predicate(["*", "role:Admin"])
    permissions_in_pred = pred["$or"].first["_rperm"]["$in"]
    assert_equal 1, permissions_in_pred.count("*"),
                 "include_public must not duplicate an existing '*' entry"
  end

  def test_read_predicate_can_suppress_public
    pred = Parse::ACL.read_predicate(["user123"], include_public: false)
    refute_includes pred["$or"].first["_rperm"]["$in"], "*"
  end

  def test_predicate_always_includes_exists_false_branch
    pred = Parse::ACL.read_predicate(["user123"])
    assert pred["$or"].any? { |branch| branch["_rperm"] == { "$exists" => false } },
           "$exists: false branch is mandatory: Parse Server treats missing " \
           "_rperm as public, and dropping the branch silently hides every " \
           "public document"
  end

  def test_write_predicate_uses_wperm_field
    pred = Parse::ACL.write_predicate(["user123"])
    assert_equal "_wperm", pred["$or"].first.keys.first
    assert_equal "_wperm", pred["$or"].last.keys.first
  end

  def test_predicate_dedupes_input
    pred = Parse::ACL.read_predicate(["role:Admin", "role:Admin", "user123"])
    perms = pred["$or"].first["_rperm"]["$in"]
    assert_equal 1, perms.count("role:Admin")
    assert_equal 1, perms.count("user123")
  end

  def test_predicate_coerces_to_strings
    pred = Parse::ACL.read_predicate([:user123, "role:Admin"])
    perms = pred["$or"].first["_rperm"]["$in"]
    assert_includes perms, "user123"
  end

  def test_predicate_drops_empty_entries
    pred = Parse::ACL.read_predicate(["user123", "", "role:Admin"])
    perms = pred["$or"].first["_rperm"]["$in"]
    refute_includes perms, ""
  end
end
