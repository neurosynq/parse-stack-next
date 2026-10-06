# encoding: UTF-8
# frozen_string_literal: true

require "active_support"
require "active_support/inflector"

module Parse

  # An operation is the core part of {Parse::Constraint} when performing
  # queries. It contains an operand (the Parse field) and an operator (the Parse
  # operation). These combined with a value, provide you with a constraint.
  #
  # All operation registrations add methods to the Symbol class, through
  # the {Operation::SymbolMethods} module.
  class Operation

    # @!attribute operand
    # The field in Parse for this operation.
    # @return [Symbol]
    attr_accessor :operand

    # @!attribute operator
    # The type of Parse operation.
    # @return [Symbol]
    attr_accessor :operator

    class << self
      # @return [Hash] a hash containing all supported Parse operations mapped
      # to their {Parse::Constraint} subclass.
      attr_writer :operators

      def operators
        @operators ||= {}
      end
    end

    # Whether this operation is defined properly.
    def valid?
      !(@operand.nil? || @operator.nil? || handler.nil?)
    end

    # @return [Parse::Constraint] the constraint class designed to handle
    #  this operator.
    def handler
      Operation.operators[@operator] unless @operator.nil?
    end

    # MongoDB operators that are blocked in field names to prevent injection.
    BLOCKED_FIELD_OPERATORS = %w[$where $function $accumulator $expr].freeze

    # Create a new operation.
    # @param field [Symbol] the name of the Parse field
    # @param op [Symbol] the operator name (ex. :eq, :lt)
    # @raise [ArgumentError] if the field name contains a blocked MongoDB operator.
    def initialize(field, op)
      self.operand = field.to_sym
      self.operand = :objectId if operand == :id
      validate_field_name!(operand)
      self.operator = op.to_sym
    end

    private

    # Validates that a field name does not contain MongoDB operators that could
    # allow code execution or injection attacks.
    def validate_field_name!(field)
      field_str = field.to_s
      if field_str.start_with?("$") || field_str.include?(".$")
        blocked = BLOCKED_FIELD_OPERATORS.find { |op| field_str.include?(op) }
        if blocked || field_str.start_with?("$")
          raise ArgumentError, "Field name cannot contain MongoDB operators: #{field_str}"
        end
      end
    end

    public

    # @!visibility private
    def inspect
      "#{operator.inspect}(#{operand.inspect})"
    end

    # Create a new constraint based on the handler that had
    # been registered with this operation.
    # @param value [Object] a value to pass to the constraint subclass.
    # @return [Parse::Constraint] a constraint with this operation and value.
    def constraint(value = nil)
      handler.new(self, value)
    end

    # Operator names that are never installed as `Symbol` methods because
    # they would replace or shadow behavior other code relies on:
    #
    # - `:size` is Ruby's own `Symbol#size`; replacing it broke
    #   `sort_by(&:size)` and any code that measures a symbol.
    # - `:id` makes every symbol `respond_to?(:id)`, which ActiveRecord
    #   treats as a record. `where(status: :draft)` then raised
    #   `TypeError: can't cast Parse::Operation` (issue #83).
    #
    # Each one is installed under the alternate name given here instead.
    # The original name stays registered in {operators}, so an explicit
    # `Parse::Operation.new(:tags, :size)` still resolves.
    SYMBOL_METHOD_RENAMES = { id: :pointer_id, size: :array_size }.freeze

    # The module that carries the query DSL methods (`:plays.gt`,
    # `:tags.in`, ...). It is included into `Symbol` rather than defining
    # methods on `Symbol` directly, so a method another library defines on
    # `Symbol` (Mongoid's `Symbol#gt`, Sequel's `Symbol#desc`) is never
    # replaced by Parse, whichever library loads first.
    module SymbolMethods; end

    class << self
      # Operator names that were not installed on `Symbol` because another
      # library already defines a method of that name. Use the explicit
      # form `Parse::Operation.new(:field, :op) => value` for these.
      # @return [Array<Symbol>]
      def symbol_conflicts
        @symbol_conflicts ||= []
      end
    end

    # Register a new symbol operator method mapped to a specific {Parse::Constraint}.
    # @param op [Symbol] the operator name.
    # @param klass [Class] the {Parse::Constraint} subclass that handles it.
    def self.register(op, klass)
      op = op.to_sym
      Operation.operators[op] = klass
      method_name = SYMBOL_METHOD_RENAMES.fetch(op, op)
      Operation.operators[method_name] = klass
      install_symbol_method(method_name)
    end

    # Defines `method_name` on {SymbolMethods} unless `Symbol` already has
    # a method of that name from somewhere other than Parse.
    # @!visibility private
    def self.install_symbol_method(method_name)
      existing = ::Symbol.method_defined?(method_name) &&
                 ::Symbol.instance_method(method_name).owner
      if existing && existing != SymbolMethods
        symbol_conflicts << method_name unless symbol_conflicts.include?(method_name)
        return false
      end
      if SymbolMethods.method_defined?(method_name, false)
        SymbolMethods.send(:remove_method, method_name)
      end
      op = method_name
      SymbolMethods.send :define_method, method_name do |value = nil|
        operation = Operation.new self, op
        value.nil? ? operation : operation.constraint(value)
      end
      true
    end
  end
end

# Included (not prepended) so methods defined on Symbol itself, by Ruby or
# by another library, keep precedence over the Parse query DSL.
Symbol.include(Parse::Operation::SymbolMethods)
