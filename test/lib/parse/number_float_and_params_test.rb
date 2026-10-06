# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "open3"
require "rbconfig"

# Parse's Number type holds floating-point values, so `:number` properties
# and schema-built Number columns keep their decimal part; hash-like
# parameters (Rails strong parameters) are accepted by Parse::Object.new;
# and the cache middleware's error fallback does not depend on Redis being
# loaded.
class NumberFloatAndParamsTest < Minitest::Test
  class Scored < Parse::Object
    parse_class "NumberFloatScored"
    property :score, :number
    property :visits, :integer
  end

  # Mimics ActionController::Parameters: not a Hash, and `to_h` refuses
  # unpermitted input.
  class FakeParams
    def initialize(hash, permitted:)
      @hash = hash
      @permitted = permitted
    end

    def to_h
      raise ArgumentError, "unpermitted parameters" unless @permitted
      @hash.dup
    end
  end

  def test_number_property_keeps_the_decimal_part
    assert_equal :float, Scored.fields[:score]
    assert_equal 4.75, Scored.new(score: 4.75).score
    assert_equal 4.75, Scored.new("score" => "4.75").score
    assert_equal 7, Scored.new(visits: 7.9).visits, ":integer still casts to an Integer"
  end

  def test_number_increment_keeps_float_values
    obj = Scored.new(score: 1.5)
    obj.stub(:op_increment!, true) { obj.score_increment!(0.25) }
    assert_equal 1.75, obj.score
  end

  def test_schema_number_columns_map_to_float
    assert_equal :float, Parse::Schema::TYPE_MAP["Number"]
    schema = Parse::Schema::SchemaInfo.new(
      "className" => "NumberFloatServer",
      "fields" => { "price" => { "type" => "Number" } },
    )
    assert_equal :float, schema.fields["price"][:type]
  end

  def test_object_new_accepts_permitted_hash_like_params
    obj = Scored.new(FakeParams.new({ "score" => 9.99 }, permitted: true))
    assert_equal 9.99, obj.score
  end

  def test_object_new_keeps_strong_parameter_refusal
    assert_raises(ArgumentError) { Scored.new(FakeParams.new({ "score" => 1 }, permitted: false)) }
  end

  # Run in a separate process so Redis is guaranteed not to be loaded (other
  # test files may load it into this one).
  def test_cache_fallback_does_not_need_redis_loaded
    {
      "TypeError" => "status=200",
      "IOError" => "store down (IOError)",
    }.each do |error, expected|
      out, = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", cache_probe(error))
      refute_match(/NameError/, out, "#{error}: the rescue list must not reference an unloaded Redis")
      assert_includes out, expected, out
    end
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
