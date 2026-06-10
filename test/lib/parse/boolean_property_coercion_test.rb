# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for :boolean property coercion.
#
# Regression guard for the "false"->true mass-assignment foot-gun: the
# coercion used to be `val ? true : false`, which treats every non-nil,
# non-false object as truthy — so the string "false" (and "0", "off"),
# exactly what arrives from Rails-form / query-string input, coerced to
# `true` and could silently flip an access-control boolean the wrong way.
# Coercion now routes through ActiveModel::Type::Boolean.
class BooleanPropertyCoercionTest < Minitest::Test
  class BoolDoc < Parse::Object
    parse_class "BoolDoc"
    property :title, :string
    property :archived, :boolean
  end

  # ---- the bug being fixed ----------------------------------------------

  def test_string_false_coerces_to_false
    doc = BoolDoc.new
    doc.archived = "false"
    assert_equal false, doc.archived,
                 'string "false" must coerce to false, not Ruby-truthy true'
  end

  def test_string_zero_coerces_to_false
    doc = BoolDoc.new
    doc.archived = "0"
    assert_equal false, doc.archived
  end

  def test_string_off_coerces_to_false
    doc = BoolDoc.new
    doc.archived = "off"
    assert_equal false, doc.archived
  end

  # Weaponized form: a hostile params hash that flips an access-control
  # boolean by sending the *string* "false" must not end up storing true.
  def test_mass_assignment_string_false_does_not_flip_true
    doc = BoolDoc.new
    doc.attributes = { "title" => "x", "archived" => "false" }
    refute_equal true, doc.archived,
                 'mass-assigned "false" must never become true'
    assert_equal false, doc.archived
  end

  # ---- true-ish values still coerce to true ------------------------------

  def test_string_true_coerces_to_true
    doc = BoolDoc.new
    doc.archived = "true"
    assert_equal true, doc.archived
  end

  def test_string_one_coerces_to_true
    doc = BoolDoc.new
    doc.archived = "1"
    assert_equal true, doc.archived
  end

  # ---- native booleans pass through (Parse wire JSON path) ---------------

  def test_real_true_stays_true
    doc = BoolDoc.new
    doc.archived = true
    assert_equal true, doc.archived
  end

  def test_real_false_stays_false
    doc = BoolDoc.new
    doc.archived = false
    assert_equal false, doc.archived
  end

  # ---- nil / blank -------------------------------------------------------

  def test_nil_stays_nil
    doc = BoolDoc.new
    doc.archived = nil
    assert_nil doc.archived, "nil must remain unset, not coerce to a boolean"
  end

  def test_empty_string_is_unset
    doc = BoolDoc.new
    doc.archived = ""
    assert_nil doc.archived,
               'blank "" should be treated as unset (nil), not true'
  end
end
