# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for Parse::Retrieval.translate_pointer_filter_values — the
# v5.5 storage-form translation of pointer VALUES in caller-supplied
# filters: { owner: <Pointer _User$abc> } => { "_p_owner" => "_User$abc" }.
class RetrievalPointerFilterTest < Minitest::Test
  class PFDoc < Parse::Object
    parse_class "PFDoc"
    property :title, :string
    property :status, :string
    belongs_to :owner, as: :user
  end

  def translate(filter)
    Parse::Retrieval.translate_pointer_filter_values(PFDoc, filter)
  end

  def pointer
    Parse::Pointer.new("_User", "abc123")
  end

  def pointer_hash
    { "__type" => "Pointer", "className" => "_User", "objectId" => "abc123" }
  end

  def test_nil_and_non_hash_pass_through
    assert_nil translate(nil)
    assert_equal "x", Parse::Retrieval.translate_pointer_filter_values(PFDoc, "x")
  end

  def test_plain_values_untouched
    f = { "status" => "published", "title" => "hello" }
    assert_equal f, translate(f)
  end

  def test_parse_pointer_value_translates_to_storage_form
    out = translate({ owner: pointer })
    assert_equal({ "_p_owner" => "_User$abc123" }, out)
  end

  def test_wire_pointer_hash_translates
    out = translate({ "owner" => pointer_hash })
    assert_equal({ "_p_owner" => "_User$abc123" }, out)
  end

  def test_symbol_keyed_pointer_hash_translates
    out = translate({ owner: { __type: "Pointer", className: "_User", objectId: "abc123" } })
    assert_equal({ "_p_owner" => "_User$abc123" }, out)
  end

  def test_pointer_inside_in_operator
    out = translate({ owner: { "$in" => [pointer, pointer_hash] } })
    assert_equal({ "_p_owner" => { "$in" => %w[_User$abc123 _User$abc123] } }, out)
  end

  def test_pointer_inside_eq_and_ne
    out = translate({ owner: { "$ne" => pointer } })
    assert_equal({ "_p_owner" => { "$ne" => "_User$abc123" } }, out)
  end

  def test_operator_hash_without_pointers_untouched
    f = { "plays" => { "$gt" => 100 } }
    assert_equal f, translate(f)
  end

  def test_incomplete_pointer_hash_not_translated
    f = { "owner" => { "__type" => "Pointer", "className" => "_User" } }
    assert_equal f, translate(f)
  end

  def test_translation_is_idempotent
    once = translate({ owner: pointer })
    assert_equal once, translate(once)
  end

  def test_mixed_filter_translates_only_pointer_entries
    out = translate({ "status" => "published", :owner => pointer })
    assert_equal({ "status" => "published", "_p_owner" => "_User$abc123" }, out)
  end

  def test_retrieve_applies_translation_to_filters
    captured = {}
    fake = lambda do |text:, k:, field:, filter:, vector_filter:, raw:, **_opts|
      captured[:filter] = filter
      captured[:vector_filter] = vector_filter
      []
    end
    PFDoc.stub(:find_similar, fake) do
      Parse::Retrieval.retrieve(
        query: "find docs", klass: PFDoc, text_field: :title,
        filter: { owner: pointer },
        vector_filter: { "owner" => pointer_hash },
      )
    end
    assert_equal({ "_p_owner" => "_User$abc123" }, captured[:filter])
    assert_equal({ "_p_owner" => "_User$abc123" }, captured[:vector_filter])
  end
end
