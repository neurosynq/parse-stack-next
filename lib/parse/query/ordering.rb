# encoding: UTF-8
# frozen_string_literal: true

module Parse
  # This class adds support for describing ordering for Parse queries. You can
  # either order by ascending (asc) or descending (desc) order.
  #
  # Ordering is implemented similarly to constraints in which we add
  # special methods to the Symbol class. The developer can then pass one
  # or an array of fields (as symbols) and call the particular ordering
  # polarity (ex. _:name.asc_ would create a Parse::Order where we want
  # things to be sorted by the name field in ascending order)
  # For more information about the query design pattern from DataMapper
  # that inspired this, see http://datamapper.org/docs/find.html'
  # @example
  #   :name.asc # => Parse::Order by ascending :name
  #   :like_count.desc # => Parse::Order by descending :like_count
  #
  class Order
    # The Parse operators to indicate ordering direction.
    ORDERING = { asc: "", desc: "-" }.freeze

    # @!attribute [rw] field
    # @return [Symbol] the name of the field
    attr_reader :field

    # @!attribute [rw] direction
    # The direction of the sorting. This is either `:asc` or `:desc`.
    # @return [Symbol]
    attr_accessor :direction

    def initialize(field, order = :asc)
      @field = field.to_sym || :objectId
      @direction = order
    end

    def field=(f)
      @field = f.to_sym
    end

    # @return [String] the sort direction
    def polarity
      ORDERING[@direction] || ORDERING[:asc]
    end # polarity

    # @return [String] the ordering as a string
    def to_s
      "" if @field.nil?
      polarity + @field.to_s
    end

    # @!visibility private
    def inspect
      "#{@direction.to_s}(#{@field.inspect})"
    end
  end # Order
end

module Parse
  class Order
    # Carries the `:field.asc` / `:field.desc` sort helpers. Included into
    # `Symbol` rather than defined on it, and skipped for any name another
    # library already defines on `Symbol` (Mongoid, Sequel core extensions),
    # so Parse never replaces another library's `Symbol#asc` or `#desc`.
    # Use `Parse::Order.new(:field, :desc)` when such a library is loaded.
    module SymbolMethods; end

    # Converts another library's sort key (Mongoid's `:field.desc` when
    # Mongoid owns `Symbol#desc`) into a {Parse::Order}.
    # @param value [Object]
    # @return [Parse::Order, nil] nil when `value` is not a known foreign sort key.
    def self.from_foreign(value)
      return value if value.is_a?(Parse::Order)
      if defined?(::Mongoid::Criteria::Queryable::Key) &&
         value.is_a?(::Mongoid::Criteria::Queryable::Key)
        case value.operator
        when 1, "1" then return new(value.name, :asc)
        when -1, "-1" then return new(value.name, :desc)
        end
      end
      nil
    end

    ORDERING.keys.each do |sym|
      existing = ::Symbol.method_defined?(sym) && ::Symbol.instance_method(sym).owner
      next if existing && existing != SymbolMethods
      SymbolMethods.send(:define_method, sym) do
        Parse::Order.new self, sym
      end
    end
  end
end

Symbol.include(Parse::Order::SymbolMethods)
