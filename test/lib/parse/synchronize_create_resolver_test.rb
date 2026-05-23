# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the synchronize: cascade resolver on Parse::Object class
# methods. This covers the per-call → per-class → module-level precedence
# that the synchronize wrapper relies on to decide whether to engage the
# create-lock for a given first_or_create! / create_or_update! call.
#
# These tests do not exercise the lock itself (see create_lock_test.rb) and
# do not require a running Parse Server.

class SynchronizeCreateResolverTest < Minitest::Test
  class FlagTestKlass < Parse::Object
    parse_class "FlagTestKlassUnitTest"
  end

  def setup
    @saved_default = Parse.synchronize_create_default
    Parse.synchronize_create_default = false
    FlagTestKlass.synchronize_create_default = nil
  end

  def teardown
    Parse.synchronize_create_default = @saved_default
    FlagTestKlass.synchronize_create_default = nil
  end

  def resolve(kwarg)
    FlagTestKlass.send(:_resolve_synchronize_flag, kwarg)
  end

  # --- Per-call kwarg wins unconditionally -----------------------------

  def test_per_call_true_enables_with_defaults
    assert_equal [true, {}], resolve(true)
  end

  def test_per_call_false_disables
    assert_equal [false, {}], resolve(false)
  end

  def test_per_call_hash_implies_true_and_carries_options
    assert_equal [true, { ttl: 5 }], resolve(ttl: 5)
  end

  def test_per_call_false_overrides_class_true
    FlagTestKlass.synchronize_create_default = true
    assert_equal [false, {}], resolve(false)
  end

  def test_per_call_false_overrides_global_true
    Parse.synchronize_create_default = true
    assert_equal [false, {}], resolve(false)
  end

  def test_per_call_hash_overrides_class_default
    FlagTestKlass.synchronize_create_default = false
    assert_equal [true, { wait: 1.0 }], resolve(wait: 1.0)
  end

  # --- Per-class default applies when kwarg is nil ----------------------

  def test_nil_kwarg_with_class_true
    FlagTestKlass.synchronize_create_default = true
    assert_equal [true, {}], resolve(nil)
  end

  def test_nil_kwarg_with_class_false
    FlagTestKlass.synchronize_create_default = false
    assert_equal [false, {}], resolve(nil)
  end

  def test_nil_kwarg_with_class_hash_implies_true_with_options
    FlagTestKlass.synchronize_create_default = { ttl: 10 }
    assert_equal [true, { ttl: 10 }], resolve(nil)
  end

  def test_class_default_overrides_global
    FlagTestKlass.synchronize_create_default = false
    Parse.synchronize_create_default = true
    assert_equal [false, {}], resolve(nil), "explicit class false must beat global true"
  end

  # --- Module-level default is the floor --------------------------------

  def test_nil_kwarg_nil_class_with_global_true
    Parse.synchronize_create_default = true
    assert_equal [true, {}], resolve(nil)
  end

  def test_nil_kwarg_nil_class_with_global_false
    Parse.synchronize_create_default = false
    assert_equal [false, {}], resolve(nil)
  end

  def test_nil_kwarg_nil_class_with_global_default_falsey
    Parse.synchronize_create_default = nil
    assert_equal [false, {}], resolve(nil)
  end

  # --- Invalid input ----------------------------------------------------

  def test_invalid_kwarg_raises_argument_error
    err = assert_raises(ArgumentError) { resolve("yes") }
    assert_match(/synchronize:/, err.message)
  end

  def test_invalid_kwarg_array_raises_argument_error
    assert_raises(ArgumentError) { resolve([:ttl, 5]) }
  end

  # --- Subclass inheritance via class_attribute -------------------------

  class FlagParent < Parse::Object
    parse_class "FlagParentUnitTest"
  end

  class FlagChild < FlagParent
    parse_class "FlagChildUnitTest"
  end

  def test_subclass_inherits_parent_default
    # class_attribute propagates writes downward unless the subclass writes
    # its own value.
    FlagParent.synchronize_create_default = true
    assert_equal true, FlagChild.synchronize_create_default,
                 "subclass should inherit parent's class_attribute write"

    FlagChild.synchronize_create_default = false
    assert_equal true, FlagParent.synchronize_create_default,
                 "subclass write must not clobber the parent"
    assert_equal false, FlagChild.synchronize_create_default
  ensure
    FlagParent.synchronize_create_default = nil
    FlagChild.synchronize_create_default = nil
  end

  # --- Options merge resolution ----------------------------------------

  def test_merged_options_combine_global_and_per_call
    Parse.synchronize_create_options = { ttl: 7, wait: 1.0 }
    merged = FlagTestKlass.send(:_merged_synchronize_options, { wait: 0.5 })
    assert_equal 7, merged[:ttl]
    assert_equal 0.5, merged[:wait], "per-call options must override global"
  ensure
    Parse.synchronize_create_options = {}
  end

  def test_merged_options_with_nil_per_call_returns_global
    Parse.synchronize_create_options = { ttl: 7 }
    merged = FlagTestKlass.send(:_merged_synchronize_options, nil)
    assert_equal({ ttl: 7 }, merged)
  ensure
    Parse.synchronize_create_options = {}
  end
end
