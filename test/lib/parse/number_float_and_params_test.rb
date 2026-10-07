# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "open3"
require "rbconfig"
require "bigdecimal"
require "ostruct"
require "set"

# `:number` properties and schema-built Number columns keep integral values
# as Integer and fractional values as Float; the increment helpers send and
# apply fractional amounts once; hash-like parameters (Rails strong
# parameters, Struct, OpenStruct) are accepted by Parse::Object.new while
# other `to_h` responders are ignored; and the cache middleware's error
# fallback does not depend on Redis being loaded.
class NumberFloatAndParamsTest < Minitest::Test
  class Scored < Parse::Object
    parse_class "NumberFloatScored"
    property :score, :number
    property :visits, :integer
    property :ratio, :float
  end

  # Mimics ActionController::Parameters: not a Hash, responds to
  # `permitted?`, and `to_h` refuses unpermitted input.
  class FakeParams
    def initialize(hash, permitted:)
      @hash = hash
      @permitted = permitted
    end

    def permitted?
      @permitted
    end

    def to_h
      raise ArgumentError, "unpermitted parameters" unless @permitted
      @hash.dup
    end
  end

  ScoreStruct = Struct.new(:score, :visits)

  class IntAlias < Parse::Object
    parse_class "NumberFloatIntAlias"
    property :count, :int
  end

  class Redefined < Parse::Object
    parse_class "NumberFloatRedefine"
    property :amount, :integer
  end

  # --- :number typecast -----------------------------------------------------

  def test_number_is_a_distinct_data_type
    assert_includes Parse::Properties::TYPES, :number
    assert_equal :number, Scored.fields[:score]
    assert_equal :integer, Scored.fields[:visits]
    assert_equal :float, Scored.fields[:ratio]
  end

  def test_number_keeps_the_decimal_part
    assert_equal 4.75, Scored.new(score: 4.75).score
    assert_equal 4.5, Scored.new("score" => "4.5").score
    assert_kind_of Float, Scored.new(score: 4.75).score
  end

  def test_number_keeps_integral_values_as_integer
    [5, 5.0, "5.0", "5", " 5 ", BigDecimal("5")].each do |input|
      value = Scored.new(score: input).score
      assert_equal 5, value, "#{input.inspect} should cast to 5"
      assert_kind_of Integer, value, "#{input.inspect} should cast to an Integer"
    end
  end

  def test_number_casts_fractional_bigdecimal_and_rational_to_float
    assert_equal 4.5, Scored.new(score: BigDecimal("4.5")).score
    assert_equal 1.5, Scored.new(score: Rational(3, 2)).score
  end

  def test_number_blank_and_invalid_values_are_nil
    assert_nil Scored.new(score: nil).score
    assert_nil Scored.new(score: "").score
    assert_raises(Parse::Properties::TypecastError) { Scored.new(score: "abc") }
    assert_raises(Parse::Properties::TypecastError) { Scored.new(score: "0x1A") }
  end

  def test_integer_and_float_types_are_unchanged
    assert_equal 7, Scored.new(visits: 7.9).visits, ":integer still truncates"
    value = Scored.new(ratio: 5).ratio
    assert_equal 5.0, value
    assert_kind_of Float, value, ":float still casts to Float"
  end

  def test_int_alias_stays_integer
    assert_equal :integer, IntAlias.fields[:count]
  end

  # --- increment helpers ----------------------------------------------------

  def test_integer_increment_adds_the_amount_once
    obj = Scored.new(visits: 5)
    sent = nil
    obj.stub(:operate_field!, ->(_field, op) { sent = op; true }) do
      assert obj.visits_increment!(2)
    end
    assert_equal 7, obj.visits
    assert_equal 2, sent[:amount]
    assert_kind_of Integer, sent[:amount]
  end

  def test_number_increment_sends_and_applies_the_fractional_amount
    obj = Scored.new(score: 5.0)
    sent = nil
    obj.stub(:operate_field!, ->(_field, op) { sent = op; true }) do
      assert obj.score_increment!(1.5)
    end
    assert_equal 6.5, obj.score
    assert_equal 1.5, sent[:amount]
    assert_equal :Increment, sent[:__op]
  end

  def test_number_decrement_applies_once
    obj = Scored.new(score: 10)
    obj.stub(:operate_field!, true) { obj.score_decrement!(0.25) }
    assert_equal 9.75, obj.score
  end

  def test_op_increment_sends_non_integer_amounts_as_float
    obj = Scored.new(ratio: 1.0)
    sent = nil
    obj.stub(:operate_field!, ->(_field, op) { sent = op; true }) do
      obj.op_increment!(:ratio, BigDecimal("0.5"))
    end
    assert_kind_of Float, sent[:amount]
    assert_equal 0.5, sent[:amount]
    assert_equal 1.5, obj.ratio
  end

  def test_failed_increment_leaves_local_value
    obj = Scored.new(visits: 5)
    obj.stub(:operate_field!, false) { refute obj.visits_increment!(2) }
    assert_equal 5, obj.visits
  end

  # --- schema-built Number columns -----------------------------------------

  def test_schema_number_columns_map_to_number
    assert_equal :number, Parse::Schema::TYPE_MAP["Number"]
    assert_equal "Number", Parse::Schema::REVERSE_TYPE_MAP[:number]
    schema = Parse::Schema::SchemaInfo.new(
      "className" => "NumberFloatServer",
      "fields" => { "price" => { "type" => "Number" } },
    )
    assert_equal :number, schema.fields["price"][:type]
  end

  def test_builder_creates_number_properties_from_schema
    klass = Parse::Model::Builder.build!(
      "className" => "NumberFloatBuilt",
      "fields" => { "price" => { "type" => "Number" }, "qty" => { "type" => "Number" } },
    )
    assert_equal :number, klass.fields[:price]
    obj = klass.new(price: 4.75, qty: 3)
    assert_equal 4.75, obj.price
    assert_equal 3, obj.qty
    assert_kind_of Integer, obj.qty
    assert obj.respond_to?(:price_increment!), "Number columns get increment helpers"
  end

  def test_number_property_schema_and_diff_use_number
    assert_equal "Number", Scored.schema[:fields][:score][:type]
    diff = Parse::Schema::SchemaDiff.allocate
    assert_equal :number, diff.send(:normalize_type, :number)
    assert_equal :number, diff.send(:normalize_type, :float)
  end

  def test_graphql_maps_number_to_float
    begin
      require "parse/graphql"
    rescue LoadError
      skip "graphql not available"
    end
    assert_equal ::GraphQL::Types::Float, Parse::GraphQL::TypeGenerator::SCALAR_TYPE_MAP[:number]
  end

  # --- redefinition warning -------------------------------------------------

  def test_non_strict_redefinition_warning_names_the_existing_type
    previous = Parse.strict_property_redefinition
    Parse.strict_property_redefinition = false
    klass = Redefined
    _out, err = capture_io { klass.property :amount, :float }
    assert_match(/already defined with data type :integer/, err)
    assert_match(/redeclaration as :float/, err)
    assert_equal :integer, klass.fields[:amount]
  ensure
    Parse.strict_property_redefinition = previous
  end

  # --- hash-like input ------------------------------------------------------

  def test_object_new_accepts_permitted_hash_like_params
    obj = Scored.new(FakeParams.new({ "score" => 9.99 }, permitted: true))
    assert_equal 9.99, obj.score
  end

  def test_object_new_keeps_strong_parameter_refusal
    assert_raises(ArgumentError) { Scored.new(FakeParams.new({ "score" => 1 }, permitted: false)) }
  end

  def test_object_new_accepts_struct_and_openstruct
    assert_equal 3, Scored.new(ScoreStruct.new(3, 4)).score
    assert_equal 4, Scored.new(ScoreStruct.new(3, 4)).visits
    assert_equal 2.5, Scored.new(OpenStruct.new(score: 2.5)).score
  end

  def test_object_new_ignores_other_to_h_responders
    [Set.new([1]), (1..2), Object.new].each do |input|
      obj = Scored.new(input)
      assert_nil obj.score, "#{input.class} input must be ignored"
    end
  end

  # --- cache fallback -------------------------------------------------------

  # Run in a separate process so Redis is guaranteed not to be loaded (other
  # test files may load it into this one).
  def test_cache_fallback_does_not_need_redis_loaded
    {
      "TypeError" => "status=200",
      "Errno::ECONNREFUSED" => "status=200",
      "IOError" => "store down (IOError)",
    }.each do |error, expected|
      out, = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", cache_probe(error))
      refute_match(/NameError/, out, "#{error}: the rescue list must not reference an unloaded Redis")
      assert_includes out, expected, out
    end
  end

  def test_cache_store_errors_include_redis_connection_errors_when_loaded
    begin
      require "redis"
    rescue LoadError
      skip "redis gem not available"
    end
    middleware = Parse::Middleware::Caching.allocate
    errors = middleware.send(:cache_store_errors)
    assert_includes errors, Errno::ECONNREFUSED
    assert_includes errors, ::Redis::BaseConnectionError if defined?(::Redis::BaseConnectionError)
    assert_includes errors, ::Redis::ReadOnlyError if defined?(::Redis::ReadOnlyError)
    assert_includes errors, ::Redis::CommandError
    assert_includes errors, ::RedisClient::Error if defined?(::RedisClient::Error)
  end

  private

  def cache_probe(error)
    <<~RUBY
      require "parse-stack-next"
      abort "Redis loaded" if defined?(::Redis)
      store = Moneta.new(:Memory)
      def store.key?(*) = raise(#{error}, "store down")
      def store.[](*) = raise(#{error}, "store down")
      conn = Faraday.new(url: "http://localhost:1/parse") do |f|
        f.use Parse::Middleware::Caching, store, expires: 10
        f.adapter :test do |stub|
          stub.get("/parse/classes/Song") { [200, { "Content-Type" => "application/json" }, '{"results":[]}'] }
        end
      end
      puts "status=\#{conn.get("classes/Song").status}"
    RUBY
  end
end
