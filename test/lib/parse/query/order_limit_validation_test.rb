require_relative "../../../test_helper"

class TestOrderLimitValidation < Minitest::Test
  extend Minitest::Spec::DSL

  def setup
    @query = Parse::Query.new("Song")
  end

  # --- order ---

  def test_order_accepts_symbol
    @query.order(:name)
    assert_equal "name", @query.compile[:order]
  end

  def test_order_accepts_string
    @query.order("name")
    assert_equal "name", @query.compile[:order]
  end

  def test_order_accepts_parse_order
    @query.order(:created_at.desc)
    assert_equal "-createdAt", @query.compile[:order]
  end

  def test_order_accepts_array
    @query.order([:like_count.desc, :name])
    assert_equal "-likeCount,name", @query.compile[:order]
  end

  def test_order_accepts_hash_with_symbol_direction
    @query.order(:created_at => :desc)
    assert_equal "-createdAt", @query.compile[:order]
  end

  def test_order_accepts_hash_with_string_direction
    @query.order(:created_at => "desc")
    assert_equal "-createdAt", @query.compile[:order]
  end

  def test_order_accepts_multi_pair_hash
    @query.order(:created_at => :desc, :name => :asc)
    assert_equal "-createdAt,name", @query.compile[:order]
  end

  def test_order_raises_on_invalid_direction
    err = assert_raises(ArgumentError) { @query.order(:created_at => :reverse) }
    assert_match(/Invalid order direction/, err.message)
  end

  def test_order_raises_on_nil
    assert_raises(ArgumentError) { @query.order(nil) }
  end

  def test_order_raises_on_integer
    assert_raises(ArgumentError) { @query.order(42) }
  end

  # --- limit ---

  def test_limit_accepts_integer
    @query.limit(50)
    assert_equal 50, @query.compile[:limit]
  end

  def test_limit_accepts_max_symbol
    @query.limit(:max)
    # :max is not emitted as a numeric :limit in compile
    refute @query.compile.key?(:limit)
  end

  def test_limit_accepts_numeric_string
    @query.limit("50")
    assert_equal 50, @query.compile[:limit]
  end

  def test_limit_accepts_nil_to_clear
    @query.limit(100)
    @query.limit(nil)
    refute @query.compile.key?(:limit)
  end

  def test_limit_raises_on_garbage_string
    assert_raises(ArgumentError) { @query.limit("fifty") }
  end

  def test_limit_raises_on_symbol_other_than_max
    assert_raises(ArgumentError) { @query.limit(:lots) }
  end

  def test_limit_raises_on_hash
    assert_raises(ArgumentError) { @query.limit({ count: 50 }) }
  end

  # --- skip ---

  def test_skip_accepts_integer
    @query.skip(20)
    assert_equal 20, @query.compile[:skip]
  end

  def test_skip_accepts_numeric_string
    @query.skip("20")
    assert_equal 20, @query.compile[:skip]
  end

  def test_skip_accepts_nil_as_zero
    @query.skip(nil)
    refute @query.compile.key?(:skip) # @skip == 0, so compile omits it
  end

  def test_skip_clamps_negative_to_zero
    @query.skip(-5)
    refute @query.compile.key?(:skip)
  end

  def test_skip_raises_on_garbage_string
    assert_raises(ArgumentError) { @query.skip("abc") }
  end

  def test_skip_raises_on_hash
    assert_raises(ArgumentError) { @query.skip({ skip: 5 }) }
  end

  def test_skip_raises_on_symbol
    assert_raises(ArgumentError) { @query.skip(:lots) }
  end

  # --- first ---

  # Stub out the network-touching `results` method so we can assert the
  # @limit side-effect without booting a Parse client.
  def stub_results!(query)
    query.define_singleton_method(:results) { |**_kw| [] }
  end

  def test_first_accepts_integer
    stub_results!(@query)
    @query.first(5)
    assert_equal 5, @query.instance_variable_get(:@limit)
  end

  def test_first_accepts_numeric_string
    stub_results!(@query)
    @query.first("3")
    assert_equal 3, @query.instance_variable_get(:@limit)
  end

  def test_first_accepts_hash_constraints
    stub_results!(@query)
    @query.first(:limit => 4, :name => "Bob")
    assert_equal 4, @query.instance_variable_get(:@limit)
  end

  def test_first_raises_on_garbage_string
    assert_raises(ArgumentError) { @query.first("abc") }
  end

  def test_first_raises_on_nil
    assert_raises(ArgumentError) { @query.first(nil) }
  end

  def test_first_raises_on_symbol
    assert_raises(ArgumentError) { @query.first(:lots) }
  end
end
