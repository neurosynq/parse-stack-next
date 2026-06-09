# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit coverage for the opt-in `{ value:, unicode: true }` form on the regex
# builders. The bare-value form must compile byte-for-byte as before; the
# unicode flag adds `u` to the compiled `$options` for correct multibyte
# (e.g. accented / CJK) case-insensitive matching.
class RegexUnicodeOptionUnitTest < Minitest::Test
  def where_clause(constraint)
    Parse::Query.new("Post").where(constraint).compile(encode: false)[:where]
  end

  # --------------------------------------------------------------------------
  # Bare forms are unchanged (back-compat guard).
  # --------------------------------------------------------------------------

  def test_starts_with_bare_form_unchanged
    assert_equal({ "name" => { :$regex => "^John", :$options => "i" } },
                 where_clause(:name.starts_with => "John"))
  end

  def test_contains_bare_form_unchanged
    assert_equal({ "title" => { :$regex => ".*parse.*", :$options => "i" } },
                 where_clause(:title.contains => "parse"))
  end

  def test_ends_with_bare_form_unchanged
    assert_equal({ "name" => { :$regex => "\\.pdf$", :$options => "i" } },
                 where_clause(:name.ends_with => ".pdf"))
  end

  def test_like_bare_form_uses_inline_flags
    # The bare Regexp form stringifies to PCRE inline flags and emits no
    # $options. This is the pre-existing behavior we must not change.
    assert_equal({ "name" => { :$regex => "(?i-mx:Bob)" } },
                 where_clause(:name.like => /Bob/i))
  end

  # --------------------------------------------------------------------------
  # Unicode opt-in appends `u`.
  # --------------------------------------------------------------------------

  def test_starts_with_unicode_opt_in
    assert_equal({ "name" => { :$regex => "^café", :$options => "iu" } },
                 where_clause(:name.starts_with => { value: "café", unicode: true }))
  end

  def test_contains_unicode_opt_in
    assert_equal({ "title" => { :$regex => ".*café.*", :$options => "iu" } },
                 where_clause(:title.contains => { value: "café", unicode: true }))
  end

  def test_ends_with_unicode_opt_in
    assert_equal({ "title" => { :$regex => "café$", :$options => "iu" } },
                 where_clause(:title.ends_with => { value: "café", unicode: true }))
  end

  def test_like_unicode_opt_in_with_casefold
    assert_equal({ "name" => { :$regex => "café", :$options => "iu" } },
                 where_clause(:name.like => { value: /café/i, unicode: true }))
  end

  def test_like_unicode_opt_in_without_casefold
    assert_equal({ "name" => { :$regex => "café", :$options => "u" } },
                 where_clause(:name.like => { value: /café/, unicode: true }))
  end

  # --------------------------------------------------------------------------
  # Hash form without the flag does not leak `u`.
  # --------------------------------------------------------------------------

  def test_starts_with_hash_without_unicode_keeps_i
    assert_equal({ "name" => { :$regex => "^John", :$options => "i" } },
                 where_clause(:name.starts_with => { value: "John" }))
  end

  def test_starts_with_unicode_false_keeps_i
    assert_equal({ "name" => { :$regex => "^John", :$options => "i" } },
                 where_clause(:name.starts_with => { value: "John", unicode: false }))
  end

  def test_like_hash_form_without_unicode_emits_structured_shape
    # The hash form always compiles to the explicit $regex/$options shape
    # (not inline flags), so casefold becomes an explicit `i`.
    assert_equal({ "name" => { :$regex => "Bob", :$options => "i" } },
                 where_clause(:name.like => { value: /Bob/i }))
  end

  # --------------------------------------------------------------------------
  # String keys in the opt-in hash are accepted.
  # --------------------------------------------------------------------------

  def test_string_keys_in_opt_in_hash
    assert_equal({ "name" => { :$regex => "^café", :$options => "iu" } },
                 where_clause(:name.starts_with => { "value" => "café", "unicode" => true }))
  end
end
