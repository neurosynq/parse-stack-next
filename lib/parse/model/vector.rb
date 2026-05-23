# encoding: UTF-8
# frozen_string_literal: true

require_relative "model"

module Parse
  # Wraps a dense numeric embedding stored on a Parse object. Backs the
  # `:vector` property data type and the `embed` DSL. The value is just
  # an array of Floats — `Parse::Vector` adds dimension awareness,
  # finite-value validation, and JSON serialization helpers so the
  # provider/index plumbing can rely on a single concrete shape.
  #
  # @example
  #   class Document < Parse::Object
  #     property :embedding, :vector, dimensions: 1536,
  #                                   provider: :openai,
  #                                   model: "text-embedding-3-small",
  #                                   similarity: :cosine
  #   end
  #
  #   doc = Document.new(embedding: Array.new(1536) { rand })
  #   doc.embedding         # => #<Parse::Vector dims=1536>
  #   doc.embedding.to_a    # => [0.123, 0.456, ...]
  class Vector
    include Enumerable

    # Maximum dimensions a Parse::Vector will accept. Atlas Vector Search
    # caps individual vector indexes at 8192 dims as of MongoDB 7.0; we
    # keep some headroom but still refuse pathological inputs that would
    # blow up memory.
    MAX_DIMENSIONS = 16384

    # @return [Array<Float>] the underlying float array
    attr_reader :values

    # @param values [Array, Parse::Vector] dense numeric vector
    # @raise [ArgumentError] if any element is not finite numeric
    def initialize(values)
      values = values.values if values.is_a?(Parse::Vector)
      unless values.is_a?(Array)
        raise ArgumentError, "[Parse::Vector] expected Array, got #{values.class}."
      end
      if values.length > MAX_DIMENSIONS
        raise ArgumentError,
              "[Parse::Vector] refusing #{values.length}-dim vector; max #{MAX_DIMENSIONS}."
      end
      @values = values.map do |x|
        unless x.is_a?(Numeric) && x.respond_to?(:finite?) && x.finite?
          raise ArgumentError,
                "[Parse::Vector] all elements must be finite Numeric (got #{x.inspect})."
        end
        x.to_f
      end.freeze
    end

    # @return [Integer] number of dimensions
    def dimensions
      @values.length
    end
    alias_method :length, :dimensions
    alias_method :size, :dimensions

    # @return [Array<Float>] the underlying float array
    def to_a
      @values.dup
    end

    # @return [Array<Float>] passes the float array through as JSON
    # MongoDB / Parse server store this as a plain BSON array.
    def as_json(*)
      @values
    end

    # @return [String] JSON representation
    def to_json(*opts)
      @values.to_json(*opts)
    end

    def each(&block)
      @values.each(&block)
    end

    # @return [Boolean] equality by element-wise comparison
    def ==(other)
      case other
      when Parse::Vector then @values == other.values
      when Array         then @values == other
      else false
      end
    end
    alias_method :eql?, :==

    def hash
      @values.hash
    end

    # @!visibility private
    def inspect
      "#<Parse::Vector dims=#{dimensions}>"
    end
  end
end
