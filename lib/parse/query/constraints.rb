# encoding: UTF-8
# frozen_string_literal: true

require_relative "constraint"

# Each constraint type is a subclass of Parse::Constraint
# We register each keyword (which is the Parse query operator)
# and the local operator we want to use. Each of the registered local
# operators are added as methods to the Symbol class.
# For more information: https://parse.com/docs/rest/guide#queries
# For more information about the query design pattern from DataMapper
# that inspired this, see http://datamapper.org/docs/find.html

module Parse
  class Constraint
    # A constraint for matching by a specific objectId value.
    #
    #  # where this Parse object equals the object in the column `field`.
    #  q.where :field => Parse::Pointer("Field", "someObjectId")
    #  # alias, shorthand when we infer `:field` maps to `Field` parse class.
    #  q.where :field.id => "someObjectId"
    #  # "field":{"__type":"Pointer","className":"Field","objectId":"someObjectId"}}
    #
    #  class Artist < Parse::Object
    #  end
    #
    #  class Song < Parse::Object
    #    belongs_to :artist
    #  end
    #
    #  artist = Artist.first # get any artist
    #  artist_id = artist.id # ex. artist.id
    #
    #  # find all songs for this artist object
    #  Song.all :artist => artist
    #
    # In some cases, you do not have the Parse object, but you have its `objectId`.
    # You can use the objectId in the query as follows:
    #
    #  # shorthand if you are using convention. Will infer class `Artist`
    #  Song.all :artist.id => artist_id
    #
    #  # other approaches, same result
    #  Song.all :artist.id => artist # safely supported Parse::Pointer
    #  Song.all :artist => Artist.pointer(artist_id)
    #  Song.all :artist => Parse::Pointer.new("Artist", artist_id)
    #
    class ObjectIdConstraint < Constraint
      # @!method id
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.id => "someObjectId"
      #  q.where :field.id => pointer # safely supported
      # @return [ObjectIdConstraint]
      register :id

      # @return [Hash] the compiled constraint.
      def build
        className = operand.to_parse_class
        value = formatted_value
        # if it is already a pointer value, just return the constraint. Allows for
        # supporting strings, symbols and pointers.
        return { @operation.operand => value } if value.is_a?(Parse::Pointer)

        begin
          klass = className.constantize
        rescue NameError => e
          klass = Parse::Model.find_class className
        end

        unless klass.present? && klass.is_a?(Parse::Object) == false
          raise ArgumentError, "#{self.class}: No Parse class defined for #{operand} as '#{className}'"
        end

        # allow symbols
        value = value.to_s if value.is_a?(Symbol)

        unless value.is_a?(String) && value.strip.present?
          raise ArgumentError, "#{self.class}: value must be of string type representing a Parse object id."
        end
        value.strip!
        return { @operation.operand => klass.pointer(value) }
      end
    end

    # Equivalent to the `$or` Parse query operation. This is useful if you want to
    # find objects that match several queries. We overload the `|` operator in
    # order to have a clean syntax for joining these `or` operations.
    #  or_query = query1 | query2 | query3
    #  query = Player.where(:wins.gt => 150) | Player.where(:wins.lt => 5)
    #
    #  query.or_where :field => value
    #
    class CompoundQueryConstraint < Constraint
      constraint_keyword :$or
      register :or

      # @return [Hash] the compiled constraint.
      def build
        or_clauses = formatted_value
        return { :$or => Array.wrap(or_clauses) }
      end
    end

    # Equivalent to the `$lte` Parse query operation. The alias `on_or_before` is provided for readability.
    #  q.where :field.lte => value
    #  q.where :field.on_or_before => date
    #
    #  q.where :created_at.on_or_before => DateTime.now
    # @see LessThanConstraint
    class LessThanOrEqualConstraint < Constraint
      # @!method lte
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$lte".
      # @example
      #  q.where :field.lte => value
      # @return [LessThanOrEqualConstraint]

      # @!method less_than_or_equal
      # Alias for {lte}
      # @return [LessThanOrEqualConstraint]

      # @!method on_or_before
      # Alias for {lte} that provides better readability when constraining dates.
      # @return [LessThanOrEqualConstraint]
      constraint_keyword :$lte
      register :lte
      register :less_than_or_equal
      register :on_or_before
    end

    # Equivalent to the `$lt` Parse query operation. The alias `before` is provided for readability.
    #  q.where :field.lt => value
    #  q.where :field.before => date
    #
    #  q.where :created_at.before => DateTime.now
    class LessThanConstraint < Constraint
      # @!method lt
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$lt".
      # @example
      #  q.where :field.lt => value
      # @return [LessThanConstraint]

      # @!method less_than
      # # Alias for {lt}.
      # @return [LessThanConstraint]

      # @!method before
      # Alias for {lt} that provides better readability when constraining dates.
      # @return [LessThanConstraint]
      constraint_keyword :$lt
      register :lt
      register :less_than
      register :before
    end

    # Equivalent to the `$gt` Parse query operation. The alias `after` is provided for readability.
    #  q.where :field.gt => value
    #  q.where :field.after => date
    #
    #  q.where :created_at.after => DateTime.now
    # @see GreaterThanOrEqualConstraint
    class GreaterThanConstraint < Constraint
      # @!method gt
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$gt".
      # @example
      #  q.where :field.gt => value
      # @return [GreaterThanConstraint]

      # @!method greater_than
      # # Alias for {gt}.
      # @return [GreaterThanConstraint]

      # @!method after
      # Alias for {gt} that provides better readability when constraining dates.
      # @return [GreaterThanConstraint]
      constraint_keyword :$gt
      register :gt
      register :greater_than
      register :after
    end

    # Equivalent to the `$gte` Parse query operation. The alias `on_or_after` is provided for readability.
    #  q.where :field.gte => value
    #  q.where :field.on_or_after => date
    #
    #  q.where :created_at.on_or_after => DateTime.now
    # @see GreaterThanConstraint
    class GreaterThanOrEqualConstraint < Constraint
      # @!method gte
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$gte".
      # @example
      #  q.where :field.gte => value
      # @return [GreaterThanOrEqualConstraint]

      # @!method greater_than_or_equal
      # # Alias for {gte}.
      # @return [GreaterThanOrEqualConstraint]

      # @!method on_or_after
      # Alias for {gte} that provides better readability when constraining dates.
      # @return [GreaterThanOrEqualConstraint]
      constraint_keyword :$gte
      register :gte
      register :greater_than_or_equal
      register :on_or_after
    end

    # Equivalent to the `$ne` Parse query operation. Where a particular field is not equal to value.
    #  q.where :field.not => value
    class NotEqualConstraint < Constraint
      # @!method not
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$ne".
      # @example
      #  q.where :field.not => value
      # @return [NotEqualConstraint]

      # @!method ne
      # # Alias for {not}.
      # @return [NotEqualConstraint]
      constraint_keyword :$ne
      register :not
      register :ne
    end

    # Provides a mechanism using the equality operator to check for `(undefined)` values.
    # Nullabiliity constraint maps the `$exists` Parse clause to enable checking for
    # existance in a column when performing geoqueries due to a Parse limitation.
    #  q.where :field.null => false
    # @note Parse currently has a bug that if you select items near a location
    #  and want to make sure a different column has a value, you need to
    #  search where the column does not contanin a null/undefined value.
    #  Therefore we override the build method to change the operation to a
    #  {NotEqualConstraint}.
    # @see ExistsConstraint
    class NullabilityConstraint < Constraint
      # @!method null
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.null => true
      # @return [NullabilityConstraint]
      constraint_keyword :$exists
      register :null

      # @return [Hash] the compiled constraint.
      def build
        # if nullability is equal true, then $exists should be set to false

        value = formatted_value
        unless value == true || value == false
          raise ArgumentError, "#{self.class}: Non-Boolean value passed, it must be either `true` or `false`"
        end

        if value == true
          return { @operation.operand => { key => false } }
        else
          #current bug in parse where if you want exists => true with geo queries
          # we should map it to a "not equal to null" constraint
          return { @operation.operand => { Parse::Constraint::NotEqualConstraint.key => nil } }
        end
      end
    end

    # Equivalent to the `#exists` Parse query operation. Checks whether a value is
    # set for key. The difference between this operation and the nullability check
    # is when using compound queries with location.
    #  q.where :field.exists => true
    #
    # @see NullabilityConstraint
    class ExistsConstraint < Constraint
      # @!method exists
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$exists".
      # @example
      #  q.where :field.exists => true
      # @return [ExistsConstraint]
      constraint_keyword :$exists
      register :exists

      # @return [Hash] the compiled constraint.
      def build
        # if nullability is equal true, then $exists should be set to false
        value = formatted_value

        unless value == true || value == false
          raise ArgumentError, "#{self.class}: Non-Boolean value passed, it must be either `true` or `false`"
        end

        return { @operation.operand => { key => value } }
      end
    end

    # Checks whether an array field contains any elements
    #  q.where :field.empty => true
    #
    # @see NullabilityConstraint
    class EmptyConstraint < Constraint
      # @!method empty
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.empty => true
      # @return [ExistsConstraint]
      constraint_keyword :$exists
      register :empty

      # @return [Hash] the compiled constraint.
      def build
        # if nullability is equal true, then $empty should be set to false
        value = formatted_value

        unless value == true || value == false
          raise ArgumentError, "#{self.class}: Non-Boolean value passed, it must be either `true` or `false`"
        end

        return { "#{@operation.operand}.0" => { key => !value } }
      end
    end

    # Equivalent to the `$in` Parse query operation. Checks whether the value in the
    # column field is contained in the set of values in the target array. If the
    # field is an array data type, it checks whether at least one value in the
    # field array is contained in the set of values in the target array.
    #  q.where :field.in => array
    #  q.where :score.in => [1,3,5,7,9]
    #
    # @see ContainsAllConstraint
    # @see NotContainedInConstraint
    class ContainedInConstraint < Constraint
      # @!method in
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$in".
      # @example
      #  q.where :field.in => array
      # @return [ContainedInConstraint]

      # @!method contained_in
      # Alias for {in}
      # @return [ContainedInConstraint]
      # @!method any
      # Alias for {in} - more readable when checking if array contains any of the values
      # @example
      #  q.where :tags.any => ["rock", "pop"]  # has at least one of these tags
      # @return [ContainedInConstraint]
      constraint_keyword :$in
      register :in
      register :contained_in
      register :any

      # @return [Hash] the compiled constraint.
      def build
        val = formatted_value
        val = [val].compact unless val.is_a?(Array)

        # Convert Parse objects to pointers for array contains queries
        if val.is_a?(Array)
          val = val.map do |item|
            item.respond_to?(:pointer) ? item.pointer : item
          end
        end

        { @operation.operand => { key => val } }
      end
    end

    # Equivalent to the `$nin` Parse query operation. Checks whether the value in
    # the column field is *not* contained in the set of values in the target
    # array. If the field is an array data type, it checks whether at least one
    # value in the field array is *not* contained in the set of values in the
    # target array.
    #
    #  q.where :field.not_in => array
    #  q.where :player_name.not_in => ["Jonathan", "Dario", "Shawn"]
    # @see ContainedInConstraint
    # @see ContainsAllConstraint
    class NotContainedInConstraint < Constraint
      # @!method not_in
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$nin".
      # @example
      #  q.where :field.not_in => array
      # @return [NotContainedInConstraint]

      # @!method nin
      # Alias for {not_in}
      # @return [NotContainedInConstraint]

      # @!method not_contained_in
      # Alias for {not_in}
      # @return [NotContainedInConstraint]
      # @!method none
      # Alias for {not_in} - more readable when checking if array contains none of the values
      # @example
      #  q.where :tags.none => ["rock", "pop"]  # has none of these tags
      # @return [NotContainedInConstraint]
      constraint_keyword :$nin
      register :not_in
      register :nin
      register :not_contained_in
      register :none

      # @return [Hash] the compiled constraint.
      def build
        val = formatted_value
        val = [val].compact unless val.is_a?(Array)

        # Convert Parse objects to pointers for array contains queries
        if val.is_a?(Array)
          val = val.map do |item|
            item.respond_to?(:pointer) ? item.pointer : item
          end
        end

        { @operation.operand => { key => val } }
      end
    end

    # Equivalent to the $all Parse query operation. Checks whether the value in
    # the column field contains all of the given values provided in the array. Note
    # that the field column should be of type {Array} in your Parse class.
    #
    #  q.where :field.all => array
    #  q.where :array_key.all => [2,3,4]
    #
    # @see ContainedInConstraint
    # @see NotContainedInConstraint
    class ContainsAllConstraint < Constraint
      # @!method all
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$all".
      # @example
      #  q.where :field.all => array
      # @return [ContainsAllConstraint]

      # @!method contains_all
      # Alias for {all}
      # @return [ContainsAllConstraint]

      # @!method superset_of
      # Alias for {all} - semantically clearer when checking if array is a superset
      # @example
      #  q.where :tags.superset_of => ["rock"]  # contains at least "rock" (and possibly more)
      # @return [ContainsAllConstraint]
      constraint_keyword :$all
      register :all
      register :contains_all
      register :superset_of

      # @return [Hash] the compiled constraint.
      def build
        val = formatted_value
        val = [val].compact unless val.is_a?(Array)
        { @operation.operand => { key => val } }
      end
    end

    # Array size constraint using MongoDB aggregation.
    # Parse Server does not natively support $size query constraint, so we use
    # MongoDB aggregation pipeline with $expr and $size to check array length.
    #
    #  # Exact size match
    #  q.where :field.size => 2
    #  q.where :tags.size => 5
    #
    #  # Comparison operators via hash
    #  q.where :tags.size => { gt: 3 }      # size > 3
    #  q.where :tags.size => { gte: 2 }     # size >= 2
    #  q.where :tags.size => { lt: 5 }      # size < 5
    #  q.where :tags.size => { lte: 4 }     # size <= 4
    #  q.where :tags.size => { ne: 0 }      # size != 0
    #
    #  # Combine for range
    #  q.where :tags.size => { gte: 2, lt: 10 }  # 2 <= size < 10
    #
    # @note This constraint uses aggregation pipeline because Parse Server
    #   does not support the $size query operator natively.
    #
    # @note This constraint uses MongoDB aggregation pipeline. While $expr expressions
    #   cannot utilize field indexes, aggregation is efficient for array size operations
    #   that would otherwise require client-side filtering.
    #
    # @see ContainsAllConstraint
    # @see ArraySetEqualsConstraint
    class ArraySizeConstraint < Constraint
      # @!method size
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.size => 2
      #  q.where :field.size => { gt: 3, lte: 10 }
      # @return [ArraySizeConstraint]
      register :size

      # Mapping of constraint keys to MongoDB comparison operators
      COMPARISON_OPERATORS = {
        gt: "$gt",
        gte: "$gte",
        lt: "$lt",
        lte: "$lte",
        ne: "$ne",
        eq: "$eq"
      }.freeze

      # @return [Hash] the compiled constraint using aggregation pipeline.
      def build
        value = formatted_value
        field_name = @operation.operand.to_s
        size_expr = { "$size" => { "$ifNull" => ["$#{field_name}", []] } }

        if value.is_a?(Integer)
          # Simple exact match
          raise ArgumentError, "#{self.class}: Size value must be non-negative" if value < 0

          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$eq" => [size_expr, value]
                }
              }
            }
          ]
        elsif value.is_a?(Hash)
          # Hash with comparison operators
          conditions = []

          value.each do |op, val|
            op_sym = op.to_sym
            unless COMPARISON_OPERATORS.key?(op_sym)
              raise ArgumentError, "#{self.class}: Unknown operator '#{op}'. Valid operators: #{COMPARISON_OPERATORS.keys.join(', ')}"
            end
            unless val.is_a?(Integer) && val >= 0
              raise ArgumentError, "#{self.class}: Value for '#{op}' must be a non-negative integer"
            end

            mongo_op = COMPARISON_OPERATORS[op_sym]
            conditions << { mongo_op => [size_expr, val] }
          end

          # Combine multiple conditions with $and
          expr = conditions.length == 1 ? conditions.first : { "$and" => conditions }

          pipeline = [
            {
              "$match" => {
                "$expr" => expr
              }
            }
          ]
        else
          raise ArgumentError, "#{self.class}: Value must be an integer or hash with comparison operators (gt, gte, lt, lte, ne, eq)"
        end

        { "__aggregation_pipeline" => pipeline }
      end
    end

    # Array empty constraint - shorthand for size == 0.
    # Matches arrays that have no elements.
    #
    #  q.where :tags.arr_empty => true   # arrays with 0 elements
    #  q.where :tags.arr_empty => false  # arrays with 1+ elements (same as nempty)
    #
    # @note This uses the arr_empty name to avoid conflict with the existing empty constraint
    #   which checks if the first array element exists.
    #
    # @see ArraySizeConstraint
    # @see ArrayNotEmptyConstraint
    class ArrayEmptyConstraint < Constraint
      # @!method arr_empty
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.arr_empty => true
      # @return [ArrayEmptyConstraint]
      register :arr_empty

      # @return [Hash] the compiled constraint using aggregation pipeline.
      def build
        value = formatted_value
        unless value == true || value == false
          raise ArgumentError, "#{self.class}: Value must be true or false"
        end

        field_name = @operation.operand.to_s
        size_expr = { "$size" => { "$ifNull" => ["$#{field_name}", []] } }

        # If true, match size == 0; if false, match size > 0
        comparison = value ? { "$eq" => [size_expr, 0] } : { "$gt" => [size_expr, 0] }

        pipeline = [
          {
            "$match" => {
              "$expr" => comparison
            }
          }
        ]

        { "__aggregation_pipeline" => pipeline }
      end
    end

    # Array not-empty constraint - shorthand for size > 0.
    # Matches arrays that have at least one element.
    #
    #  q.where :tags.arr_nempty => true   # arrays with 1+ elements
    #  q.where :tags.arr_nempty => false  # arrays with 0 elements (same as empty)
    #
    # @see ArraySizeConstraint
    # @see ArrayEmptyConstraint
    class ArrayNotEmptyConstraint < Constraint
      # @!method arr_nempty
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.arr_nempty => true
      # @return [ArrayNotEmptyConstraint]
      register :arr_nempty

      # @return [Hash] the compiled constraint using aggregation pipeline.
      def build
        value = formatted_value
        unless value == true || value == false
          raise ArgumentError, "#{self.class}: Value must be true or false"
        end

        field_name = @operation.operand.to_s
        size_expr = { "$size" => { "$ifNull" => ["$#{field_name}", []] } }

        # If true, match size > 0; if false, match size == 0
        comparison = value ? { "$gt" => [size_expr, 0] } : { "$eq" => [size_expr, 0] }

        pipeline = [
          {
            "$match" => {
              "$expr" => comparison
            }
          }
        ]

        { "__aggregation_pipeline" => pipeline }
      end
    end

    # Set equality constraint using MongoDB aggregation with $setEquals.
    # Matches arrays that contain exactly the same elements, regardless of order.
    # This is order-independent matching: [A, B] matches [B, A] but not [A, B, C].
    #
    #  q.where :field.set_equals => ["rock", "pop"]
    #  q.where :tags.set_equals => [category1, category2]  # for pointers
    #
    # For pointer arrays (has_many relations), pass Parse objects or pointers.
    # The constraint will automatically extract objectIds for comparison.
    #
    # @note This constraint uses aggregation pipeline with MongoDB $setEquals.
    #
    # @see ContainsAllConstraint
    # @see ArrayEqConstraint
    class ArraySetEqualsConstraint < Constraint
      # @!method set_equals
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.set_equals => ["value1", "value2"]
      #  q.where :categories.set_equals => [cat1, cat2]
      # @return [ArraySetEqualsConstraint]
      register :set_equals

      # @return [Hash] the compiled constraint using aggregation pipeline.
      def build
        val = formatted_value
        val = [val].compact unless val.is_a?(Array)

        field_name = @operation.operand.to_s

        # Check if values are pointers (Parse objects or pointer objects)
        is_pointer_array = val.any? do |item|
          item.respond_to?(:pointer) || item.is_a?(Parse::Pointer)
        end

        if is_pointer_array
          # Extract objectIds from pointers for comparison
          target_ids = val.map do |item|
            if item.respond_to?(:id)
              item.id
            elsif item.is_a?(Parse::Pointer)
              item.id
            else
              item
            end
          end

          # Validate all IDs are present (unsaved objects have nil IDs)
          if target_ids.any?(&:nil?)
            raise ArgumentError, "#{self.class.name}: Cannot use unsaved objects (missing ID) in array constraint"
          end

          # For pointer arrays, we need to map the objectIds from the stored pointers
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$setEquals" => [
                    { "$map" => { "input" => "$#{field_name}", "as" => "p", "in" => "$$p.objectId" } },
                    target_ids
                  ]
                }
              }
            }
          ]
        else
          # For simple value arrays (strings, numbers, etc.)
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$setEquals" => ["$#{field_name}", val]
                }
              }
            }
          ]
        end

        { "__aggregation_pipeline" => pipeline }
      end
    end

    # Exact array equality constraint using MongoDB aggregation with $eq.
    # Matches arrays that are exactly equal, including element order.
    # This is order-dependent matching: [A, B] does NOT match [B, A].
    #
    #  q.where :field.eq_array => ["rock", "pop"]
    #  q.where :tags.eq_array => [category1, category2]  # for pointers
    #
    # For pointer arrays (has_many relations), pass Parse objects or pointers.
    # The constraint will automatically extract objectIds for comparison.
    #
    # @note This constraint uses aggregation pipeline with MongoDB $eq on arrays.
    #
    # @see ContainsAllConstraint
    # @see ArraySetEqualsConstraint
    class ArrayEqConstraint < Constraint
      # @!method eq_array
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.eq_array => ["value1", "value2"]
      #  q.where :categories.eq_array => [cat1, cat2]
      # @return [ArrayEqConstraint]
      #
      # @note Use :eq_array for explicit array equality matching.
      #   Simple :eq is handled by the base Constraint class for scalar equality.
      register :eq_array

      # @return [Hash] the compiled constraint using aggregation pipeline.
      def build
        val = formatted_value
        val = [val].compact unless val.is_a?(Array)

        field_name = @operation.operand.to_s

        # Check if values are pointers (Parse objects or pointer objects)
        is_pointer_array = val.any? do |item|
          item.respond_to?(:pointer) || item.is_a?(Parse::Pointer)
        end

        if is_pointer_array
          # Extract objectIds from pointers for comparison
          target_ids = val.map do |item|
            if item.respond_to?(:id)
              item.id
            elsif item.is_a?(Parse::Pointer)
              item.id
            else
              item
            end
          end

          # Validate all IDs are present (unsaved objects have nil IDs)
          if target_ids.any?(&:nil?)
            raise ArgumentError, "#{self.class.name}: Cannot use unsaved objects (missing ID) in array constraint"
          end

          # For pointer arrays, compare mapped objectIds with exact equality (order matters)
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$eq" => [
                    { "$map" => { "input" => "$#{field_name}", "as" => "p", "in" => "$$p.objectId" } },
                    target_ids
                  ]
                }
              }
            }
          ]
        else
          # For simple value arrays, direct $eq comparison (order matters)
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$eq" => ["$#{field_name}", val]
                }
              }
            }
          ]
        end

        { "__aggregation_pipeline" => pipeline }
      end
    end

    # Array not-equal constraint using MongoDB aggregation with $ne.
    # Matches arrays that are NOT exactly equal (including element order).
    # This is order-dependent: [A, B] does NOT match [A, B] but DOES match [B, A].
    #
    #  q.where :field.neq => ["rock", "pop"]
    #  q.where :tags.neq => [category1, category2]  # for pointers
    #
    # @note This constraint uses aggregation pipeline with MongoDB $ne on arrays.
    #
    # @see ArrayEqConstraint
    # @see ArrayNotSetEqualsConstraint
    class ArrayNeqConstraint < Constraint
      # @!method neq
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.neq => ["value1", "value2"]
      #  q.where :categories.neq => [cat1, cat2]
      # @return [ArrayNeqConstraint]
      register :neq

      # @return [Hash] the compiled constraint using aggregation pipeline.
      def build
        val = formatted_value
        val = [val].compact unless val.is_a?(Array)

        field_name = @operation.operand.to_s

        # Check if values are pointers (Parse objects or pointer objects)
        is_pointer_array = val.any? do |item|
          item.respond_to?(:pointer) || item.is_a?(Parse::Pointer)
        end

        if is_pointer_array
          # Extract objectIds from pointers for comparison
          target_ids = val.map do |item|
            if item.respond_to?(:id)
              item.id
            elsif item.is_a?(Parse::Pointer)
              item.id
            else
              item
            end
          end

          # Validate all IDs are present (unsaved objects have nil IDs)
          if target_ids.any?(&:nil?)
            raise ArgumentError, "#{self.class.name}: Cannot use unsaved objects (missing ID) in array constraint"
          end

          # For pointer arrays, compare mapped objectIds with $ne (order matters)
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$ne" => [
                    { "$map" => { "input" => "$#{field_name}", "as" => "p", "in" => "$$p.objectId" } },
                    target_ids
                  ]
                }
              }
            }
          ]
        else
          # For simple value arrays, direct $ne comparison (order matters)
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$ne" => ["$#{field_name}", val]
                }
              }
            }
          ]
        end

        { "__aggregation_pipeline" => pipeline }
      end
    end

    # Not-set-equals constraint using MongoDB aggregation with $not and $setEquals.
    # Matches arrays that do NOT contain exactly the same elements (regardless of order).
    # This is order-independent: [A, B, C] does NOT match [A, B] but [C, B, A] DOES match.
    #
    #  q.where :field.nlike => ["rock", "pop"]
    #  q.where :field.not_set_equals => ["rock", "pop"]
    #  q.where :tags.nlike => [category1, category2]  # for pointers
    #
    # @note This constraint uses aggregation pipeline with MongoDB $not and $setEquals.
    #
    # @see ArraySetEqualsConstraint
    # @see ArrayNeqConstraint
    class ArrayNotSetEqualsConstraint < Constraint
      # @!method not_set_equals
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.not_set_equals => ["value1", "value2"]
      #  q.where :categories.not_set_equals => [cat1, cat2]
      # @return [ArrayNotSetEqualsConstraint]
      register :not_set_equals

      # @return [Hash] the compiled constraint using aggregation pipeline.
      def build
        val = formatted_value
        val = [val].compact unless val.is_a?(Array)

        field_name = @operation.operand.to_s

        # Check if values are pointers (Parse objects or pointer objects)
        is_pointer_array = val.any? do |item|
          item.respond_to?(:pointer) || item.is_a?(Parse::Pointer)
        end

        if is_pointer_array
          # Extract objectIds from pointers for comparison
          target_ids = val.map do |item|
            if item.respond_to?(:id)
              item.id
            elsif item.is_a?(Parse::Pointer)
              item.id
            else
              item
            end
          end

          # Validate all IDs are present (unsaved objects have nil IDs)
          if target_ids.any?(&:nil?)
            raise ArgumentError, "#{self.class.name}: Cannot use unsaved objects (missing ID) in array constraint"
          end

          # For pointer arrays, use $not with $setEquals on mapped objectIds
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$not" => {
                    "$setEquals" => [
                      { "$map" => { "input" => "$#{field_name}", "as" => "p", "in" => "$$p.objectId" } },
                      target_ids
                    ]
                  }
                }
              }
            }
          ]
        else
          # For simple value arrays, use $not with $setEquals
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$not" => {
                    "$setEquals" => ["$#{field_name}", val]
                  }
                }
              }
            }
          ]
        end

        { "__aggregation_pipeline" => pipeline }
      end
    end

    # Element match constraint for arrays of objects.
    # Matches documents where at least one array element matches all specified criteria.
    #
    #  # Find posts where comments array has an approved comment by the user
    #  q.where :comments.elem_match => { author: user, approved: true }
    #
    #  # Find items where tags array has a tag with specific properties
    #  q.where :tags.elem_match => { name: "featured", priority: { "$gt" => 5 } }
    #
    # @note While $elemMatch is a standard MongoDB query operator, Parse Server's
    #   REST API query endpoint does not support it directly (returns "bad constraint").
    #   This constraint uses aggregation pipeline to work around this limitation.
    #   Aggregation is efficient for complex multi-field element matching that would
    #   otherwise require multiple queries or client-side filtering.
    #
    # @see ContainsAllConstraint
    class ArrayElemMatchConstraint < Constraint
      # @!method elem_match
      # A registered method on a symbol to create the constraint.
      # Uses aggregation pipeline since Parse Server doesn't support $elemMatch in queries.
      # @example
      #  q.where :comments.elem_match => { author: user, approved: true }
      # @return [ArrayElemMatchConstraint]
      register :elem_match

      # @return [Hash] the compiled constraint using aggregation pipeline.
      def build
        val = formatted_value
        unless val.is_a?(Hash)
          raise ArgumentError, "#{self.class}: Value must be a hash of criteria for element matching"
        end

        field_name = @operation.operand.to_s

        # Convert any Parse objects to pointers in the criteria
        converted_val = convert_criteria(val)

        # Build the aggregation pipeline with $elemMatch
        # Parse Server doesn't support $elemMatch as a native query constraint,
        # but it works within aggregation pipeline $match stages
        pipeline = [
          {
            "$match" => {
              field_name => {
                "$elemMatch" => converted_val
              }
            }
          }
        ]

        { "__aggregation_pipeline" => pipeline }
      end

      private

      def convert_criteria(criteria)
        criteria.transform_values do |v|
          if v.respond_to?(:pointer)
            v.pointer
          elsif v.is_a?(Hash)
            convert_criteria(v)
          else
            v
          end
        end
      end
    end

    # Subset constraint - array only contains elements from the given set.
    # Uses MongoDB aggregation with $setIsSubset.
    #
    #  # Find items where tags only contain elements from the allowed list
    #  q.where :tags.subset_of => ["rock", "pop", "jazz"]
    #
    #  # This will match:
    #  #   ["rock"] - yes (subset)
    #  #   ["rock", "pop"] - yes (subset)
    #  #   ["rock", "classical"] - no ("classical" not in allowed set)
    #
    # @note This constraint uses MongoDB aggregation pipeline with $setIsSubset.
    #   While $expr expressions cannot utilize field indexes, aggregation enables
    #   set operations not available in standard Parse queries.
    #
    # @see ContainsAllConstraint
    class ArraySubsetOfConstraint < Constraint
      # @!method subset_of
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :tags.subset_of => ["rock", "pop", "jazz"]
      # @return [ArraySubsetOfConstraint]
      register :subset_of

      # @return [Hash] the compiled constraint using aggregation pipeline.
      def build
        val = formatted_value
        val = [val].compact unless val.is_a?(Array)

        field_name = @operation.operand.to_s

        # Check if values are pointers
        is_pointer_array = val.any? do |item|
          item.respond_to?(:pointer) || item.is_a?(Parse::Pointer)
        end

        if is_pointer_array
          # Extract objectIds from pointers
          target_ids = val.map do |item|
            if item.respond_to?(:id)
              item.id
            elsif item.is_a?(Parse::Pointer)
              item.id
            else
              item
            end
          end

          # Validate all IDs are present (unsaved objects have nil IDs)
          if target_ids.any?(&:nil?)
            raise ArgumentError, "#{self.class.name}: Cannot use unsaved objects (missing ID) in array constraint"
          end

          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$setIsSubset" => [
                    { "$map" => { "input" => "$#{field_name}", "as" => "p", "in" => "$$p.objectId" } },
                    target_ids
                  ]
                }
              }
            }
          ]
        else
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$setIsSubset" => ["$#{field_name}", val]
                }
              }
            }
          ]
        end

        { "__aggregation_pipeline" => pipeline }
      end
    end

    # First element constraint - match based on the first element of an array.
    # Uses MongoDB aggregation with $arrayElemAt.
    #
    #  q.where :tags.first => "rock"  # first element equals "rock"
    #
    # @note This constraint uses MongoDB aggregation pipeline with $arrayElemAt.
    #   While $expr expressions cannot utilize field indexes, aggregation enables
    #   positional array access not available in standard Parse queries.
    #
    # @see ArrayLastConstraint
    class ArrayFirstConstraint < Constraint
      # @!method first
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :tags.first => "rock"
      # @return [ArrayFirstConstraint]
      register :first

      # @return [Hash] the compiled constraint using aggregation pipeline.
      def build
        val = formatted_value
        field_name = @operation.operand.to_s

        # Handle pointer values
        if val.respond_to?(:id)
          compare_val = val.id
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$eq" => [
                    { "$arrayElemAt" => [{ "$map" => { "input" => "$#{field_name}", "as" => "p", "in" => "$$p.objectId" } }, 0] },
                    compare_val
                  ]
                }
              }
            }
          ]
        elsif val.is_a?(Parse::Pointer)
          compare_val = val.id
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$eq" => [
                    { "$arrayElemAt" => [{ "$map" => { "input" => "$#{field_name}", "as" => "p", "in" => "$$p.objectId" } }, 0] },
                    compare_val
                  ]
                }
              }
            }
          ]
        else
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$eq" => [
                    { "$arrayElemAt" => ["$#{field_name}", 0] },
                    val
                  ]
                }
              }
            }
          ]
        end

        { "__aggregation_pipeline" => pipeline }
      end
    end

    # Last element constraint - match based on the last element of an array.
    # Uses MongoDB aggregation with $arrayElemAt and index -1.
    #
    #  q.where :tags.last => "pop"  # last element equals "pop"
    #
    # @note This constraint uses MongoDB aggregation pipeline with $arrayElemAt.
    #   While $expr expressions cannot utilize field indexes, aggregation enables
    #   positional array access not available in standard Parse queries.
    #
    # @see ArrayFirstConstraint
    class ArrayLastConstraint < Constraint
      # @!method last
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :tags.last => "pop"
      # @return [ArrayLastConstraint]
      register :last

      # @return [Hash] the compiled constraint using aggregation pipeline.
      def build
        val = formatted_value
        field_name = @operation.operand.to_s

        # Handle pointer values
        if val.respond_to?(:id)
          compare_val = val.id
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$eq" => [
                    { "$arrayElemAt" => [{ "$map" => { "input" => "$#{field_name}", "as" => "p", "in" => "$$p.objectId" } }, -1] },
                    compare_val
                  ]
                }
              }
            }
          ]
        elsif val.is_a?(Parse::Pointer)
          compare_val = val.id
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$eq" => [
                    { "$arrayElemAt" => [{ "$map" => { "input" => "$#{field_name}", "as" => "p", "in" => "$$p.objectId" } }, -1] },
                    compare_val
                  ]
                }
              }
            }
          ]
        else
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$eq" => [
                    { "$arrayElemAt" => ["$#{field_name}", -1] },
                    val
                  ]
                }
              }
            }
          ]
        end

        { "__aggregation_pipeline" => pipeline }
      end
    end

    # Equivalent to the `$select` Parse query operation. This matches a value for a
    # key in the result of a different query.
    #  q.where :field.select => { key: "field", query: query }
    #
    #  # example
    #  value = { key: 'city', query: Artist.where(:fan_count.gt => 50) }
    #  q.where :hometown.select => value
    #
    #  # if the local field is the same name as the foreign table field, you can omit hash
    #  # assumes key: 'city'
    #  q.where :city.select => Artist.where(:fan_count.gt => 50)
    #
    class SelectionConstraint < Constraint
      # @!method select
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$select".
      # @return [SelectionConstraint]
      constraint_keyword :$select
      register :select

      # @return [Hash] the compiled constraint.
      def build

        # if it's a hash, then it should be {:key=>"objectId", :query=>[]}
        remote_field_name = @operation.operand
        query = nil
        if @value.is_a?(Hash)
          res = @value.symbolize_keys
          remote_field_name = res[:key] || remote_field_name
          query = res[:query]
          unless query.is_a?(Parse::Query)
            raise ArgumentError, "Invalid Parse::Query object provided in :query field of value: #{@operation.operand}.#{$dontSelect} => #{@value}"
          end
          query = query.compile(encode: false, includeClassName: true)
        elsif @value.is_a?(Parse::Query)
          # if its a query, then assume dontSelect key is the same name as operand.
          query = @value.compile(encode: false, includeClassName: true)
        else
          raise ArgumentError, "Invalid `:select` query constraint. It should follow the format: :field.select => { key: 'key', query: '<Parse::Query>' }"
        end
        { @operation.operand => { :$select => { key: remote_field_name, query: query } } }
      end
    end

    # Equivalent to the `$dontSelect` Parse query operation. Requires that a field's
    # value not match a value for a key in the result of a different query.
    #
    #  q.where :field.reject => { key: :other_field, query: query }
    #
    #  value = { key: 'city', query: Artist.where(:fan_count.gt => 50) }
    #  q.where :hometown.reject => value
    #
    #  # if the local field is the same name as the foreign table field, you can omit hash
    #  # assumes key: 'city'
    #  q.where :city.reject => Artist.where(:fan_count.gt => 50)
    #
    # @see SelectionConstraint
    class RejectionConstraint < Constraint

      # @!method dont_select
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$dontSelect".
      # @example
      #  q.where :field.reject => { key: :other_field, query: query }
      # @return [RejectionConstraint]

      # @!method reject
      # Alias for {dont_select}
      # @return [RejectionConstraint]
      constraint_keyword :$dontSelect
      register :reject
      register :dont_select

      # @return [Hash] the compiled constraint.
      def build

        # if it's a hash, then it should be {:key=>"objectId", :query=>[]}
        remote_field_name = @operation.operand
        query = nil
        if @value.is_a?(Hash)
          res = @value.symbolize_keys
          remote_field_name = res[:key] || remote_field_name
          query = res[:query]
          unless query.is_a?(Parse::Query)
            raise ArgumentError, "Invalid Parse::Query object provided in :query field of value: #{@operation.operand}.#{$dontSelect} => #{@value}"
          end
          query = query.compile(encode: false, includeClassName: true)
        elsif @value.is_a?(Parse::Query)
          # if its a query, then assume dontSelect key is the same name as operand.
          query = @value.compile(encode: false, includeClassName: true)
        else
          raise ArgumentError, "Invalid `:reject` query constraint. It should follow the format: :field.reject => { key: 'key', query: '<Parse::Query>' }"
        end
        { @operation.operand => { :$dontSelect => { key: remote_field_name, query: query } } }
      end
    end

    # Equivalent to the `$regex` Parse query operation. Requires that a field value
    # match a regular expression.
    #
    #  q.where :field.like => /ruby_regex/i
    #  :name.like => /Bob/i
    #
    class RegularExpressionConstraint < Constraint
      #Requires that a key's value match a regular expression

      # @!method like
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$regex".
      # @example
      #  q.where :field.like => /ruby_regex/i
      # @return [RegularExpressionConstraint]

      # @!method regex
      # Alias for {like}
      # @return [RegularExpressionConstraint]
      constraint_keyword :$regex
      register :like
      register :regex
    end

    # Equivalent to the `$relatedTo` Parse query operation. If you want to
    # retrieve objects that are members of a `Relation` field in your Parse class.
    #
    #  q.where :field.related_to => pointer
    #
    #  # find all Users who have liked this post object
    #  post = Post.first
    #  users = Parse::User.all :likes.related_to => post
    #
    class RelationQueryConstraint < Constraint
      # @!method related_to
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$relatedTo".
      # @example
      #   q.where :field.related_to => pointer
      # @return [RelationQueryConstraint]

      # @!method rel
      # Alias for {related_to}
      # @return [RelationQueryConstraint]
      constraint_keyword :$relatedTo
      register :related_to
      register :rel

      # @return [Hash] the compiled constraint.
      def build
        # pointer = formatted_value
        # unless pointer.is_a?(Parse::Pointer)
        #   raise "Invalid Parse::Pointer passed to :related(#{@operation.operand}) constraint : #{pointer}"
        # end
        { :$relatedTo => { object: formatted_value, key: @operation.operand } }
      end
    end

    # Equivalent to the `$inQuery` Parse query operation. Useful if you want to
    # retrieve objects where a field contains an object that matches another query.
    #
    #  q.where :field.matches => query
    #  # assume Post class has an image column.
    #  q.where :post.matches => Post.where(:image.exists => true )
    #
    class InQueryConstraint < Constraint
      # @!method matches
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$inQuery".
      # @example
      #  q.where :field.matches => query
      # @return [InQueryConstraint]

      # @!method in_query
      # Alias for {matches}
      # @return [InQueryConstraint]
      constraint_keyword :$inQuery
      register :matches
      register :in_query
    end

    # Equivalent to the `$notInQuery` Parse query operation. Useful if you want to
    # retrieve objects where a field contains an object that does not match another query.
    # This is the inverse of the {InQueryConstraint}.
    #
    #  q.where :field.excludes => query
    #
    #  q.where :post.excludes => Post.where(:image.exists => true
    #
    class NotInQueryConstraint < Constraint
      # @!method excludes
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$notInQuery".
      # @example
      #   q.where :field.excludes => query
      # @return [NotInQueryConstraint]

      # @!method not_in_query
      # Alias for {excludes}
      # @return [NotInQueryConstraint]
      constraint_keyword :$notInQuery
      register :excludes
      register :not_in_query
    end

    # Equivalent to the `$nearSphere` Parse query operation. This is only applicable
    # if the field is of type `GeoPoint`. This will query Parse and return a list of
    # results ordered by distance with the nearest object being first.
    #
    #  q.where :field.near => geopoint
    #
    #  geopoint = Parse::GeoPoint.new(30.0, -20.0)
    #  PlaceObject.all :location.near => geopoint
    # If you wish to constrain the geospatial query to a maximum number of _miles_,
    # you can utilize the `max_miles` method on a `Parse::GeoPoint` object. This
    # is equivalent to the `$maxDistanceInMiles` constraint used with `$nearSphere`.
    #
    #  q.where :field.near => geopoint.max_miles(distance)
    #  # or provide a triplet includes max miles constraint
    #  q.where :field.near => [lat, lng, miles]
    #
    #  geopoint = Parse::GeoPoint.new(30.0, -20.0)
    #  PlaceObject.all :location.near => geopoint.max_miles(10)
    #
    # @todo Add support $maxDistanceInKilometers (for kms) and $maxDistanceInRadians (for radian angle).
    class NearSphereQueryConstraint < Constraint
      # @!method near
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$nearSphere".
      # @example
      #  q.where :field.near => geopoint
      #  q.where :field.near => geopoint.max_miles(distance)
      # @return [NearSphereQueryConstraint]
      constraint_keyword :$nearSphere
      register :near

      # @return [Hash] the compiled constraint.
      def build
        point = formatted_value
        max_miles = nil
        if point.is_a?(Array) && point.count > 1
          max_miles = point[2] if point.count == 3
          point = { __type: "GeoPoint", latitude: point[0], longitude: point[1] }
        end
        if max_miles.present? && max_miles > 0
          return { @operation.operand => { key => point, :$maxDistanceInMiles => max_miles.to_f } }
        end
        { @operation.operand => { key => point } }
      end
    end

    # Equivalent to the `$within` Parse query operation and `$box` geopoint
    # constraint. The rectangular bounding box is defined by a southwest point as
    # the first parameter, followed by the a northeast point. Please note that Geo
    # box queries that cross the international date lines are not currently
    # supported by Parse.
    #
    #  q.where :field.within_box => [soutwestGeoPoint, northeastGeoPoint]
    #
    #  sw = Parse::GeoPoint.new 32.82, -117.23 # San Diego
    #  ne = Parse::GeoPoint.new 36.12, -115.31 # Las Vegas
    #
    #  # get all PlaceObjects inside this bounding box
    #  PlaceObject.all :location.within_box => [sw,ne]
    #
    class WithinGeoBoxQueryConstraint < Constraint
      # @!method within_box
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$within".
      # @example
      #  q.where :field.within_box => [soutwestGeoPoint, northeastGeoPoint]
      # @return [WithinGeoBoxQueryConstraint]
      constraint_keyword :$within
      register :within_box

      # @return [Hash] the compiled constraint.
      def build
        geopoint_values = formatted_value
        unless geopoint_values.is_a?(Array) && geopoint_values.count == 2 &&
               geopoint_values.first.is_a?(Parse::GeoPoint) && geopoint_values.last.is_a?(Parse::GeoPoint)
          raise(ArgumentError, "[Parse::Query] Invalid query value parameter passed to `within_box` constraint. " +
                               "Values in array must be `Parse::GeoPoint` objects and " +
                               "it should be in an array format: [southwestPoint, northeastPoint]")
        end
        { @operation.operand => { :$within => { :$box => geopoint_values } } }
      end
    end

    # Equivalent to the `$geoWithin` Parse query operation and `$polygon` geopoints
    # constraint. The polygon area is defined by a list of {Parse::GeoPoint}
    # objects that make up the enclosed area. A polygon query should have 3 or more geopoints.
    # Please note that some Geo queries that cross the international date lines are not currently
    # supported by Parse.
    #
    #  # As many points as you want, minimum 3
    #  q.where :field.within_polygon => [geopoint1, geopoint2, geopoint3]
    #
    #  # Polygon for the Bermuda Triangle
    #  bermuda  = Parse::GeoPoint.new 32.3078000,-64.7504999 # Bermuda
    #  miami    = Parse::GeoPoint.new 25.7823198,-80.2660226 # Miami, FL
    #  san_juan = Parse::GeoPoint.new 18.3848232,-66.0933608 # San Juan, PR
    #
    #  # get all sunken ships inside the Bermuda Triangle
    #  SunkenShip.all :location.within_polygon => [bermuda, san_juan, miami]
    #
    class WithinPolygonQueryConstraint < Constraint
      # @!method within_polygon
      # A registered method on a symbol to create the constraint. Maps to Parse
      # operator "$geoWithin" with "$polygon" subconstraint. Takes an array of {Parse::GeoPoint} objects.
      # @example
      #  # As many points as you want
      #  q.where :field.within_polygon => [geopoint1, geopoint2, geopoint3]
      # @return [WithinPolygonQueryConstraint]
      # @version 1.7.0 (requires Server v2.4.2 or later)
      constraint_keyword :$geoWithin
      register :within_polygon

      # @return [Hash] the compiled constraint.
      def build
        geopoint_values = formatted_value
        unless geopoint_values.is_a?(Array) &&
               geopoint_values.all? { |point| point.is_a?(Parse::GeoPoint) } &&
               geopoint_values.count > 2
          raise ArgumentError, "[Parse::Query] Invalid query value parameter passed to" \
                " `within_polygon` constraint: Value must be an array with 3" \
                " or more `Parse::GeoPoint` objects"
        end

        { @operation.operand => { :$geoWithin => { :$polygon => geopoint_values } } }
      end
    end

    # Equivalent to the full text search support with `$text` with a set of search crieteria.
    class FullTextSearchQueryConstraint < Constraint
      # @!method text_search
      # A registered method on a symbol to create the constraint. Maps to Parse
      # operator "$text" with "$search" subconstraint. Takes a hash of parameters.
      # @example
      #  # As many points as you want
      #  q.where :field.text_search => {parameters}
      #
      # Where `parameters` can be one of:
      #   $term : Specify a field to search (Required)
      #   $language : Determines the list of stop words and the rules for tokenizer.
      #   $caseSensitive : Enable or disable case sensitive search.
      #   $diacriticSensitive : Enable or disable diacritic sensitive search
      #
      # @note This method will automatically add `$` to each key of the parameters
      # hash if it doesn't already have it.
      # @return [WithinPolygonQueryConstraint]
      # @version 1.8.0 (requires Server v2.5.0 or later)
      constraint_keyword :$text
      register :text_search

      # @return [Hash] the compiled constraint.
      def build
        params = formatted_value

        params = { :$term => params.to_s } if params.is_a?(String) || params.is_a?(Symbol)

        unless params.is_a?(Hash)
          raise ArgumentError, "[Parse::Query] Invalid query value parameter passed to" \
                " `text_search` constraint: Value must be a string or a hash of parameters."
        end

        params = params.inject({}) do |h, (k, v)|
          u = k.to_s
          u = u.columnize.prepend("$") unless u.start_with?("$")
          h[u] = v
          h
        end

        unless params["$term"].present?
          raise ArgumentError, "[Parse::Query] Invalid query value parameter passed to" \
                " `text_search` constraint: Missing required `$term` subkey.\n" \
                "\tExample: #{@operation.operand}.text_search => { term: 'text to search' }"
        end

        { @operation.operand => { :$text => { :$search => params } } }
      end
    end

    # Equivalent to the `$select` Parse query operation but for key matching.
    # This matches objects where a field's value equals another field's value from a different query.
    # Useful for performing join-like operations where fields from different classes match.
    #
    #  # Find users where user.company equals customer.company
    #  customer_query = Customer.where(:active => true)
    #  user_query = User.where(:company.matches_key => { key: "company", query: customer_query })
    #
    #  # If the local field has the same name as the remote field, you can omit the key
    #  # assumes key: 'company'
    #  user_query = User.where(:company.matches_key => customer_query)
    #
    class MatchesKeyInQueryConstraint < Constraint
      # @!method matches_key_in_query
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.matches_key_in_query => { key: "remote_field", query: query }
      #  q.where :field.matches_key_in_query => query # assumes same field name
      # @return [MatchesKeyInQueryConstraint]

      # @!method matches_key
      # Alias for {matches_key_in_query}
      # @return [MatchesKeyInQueryConstraint]
      constraint_keyword :$select
      register :matches_key_in_query
      register :matches_key

      # @return [Hash] the compiled constraint.
      def build
        remote_field_name = @operation.operand
        query = nil
        
        if @value.is_a?(Hash)
          res = @value.symbolize_keys
          remote_field_name = res[:key] || remote_field_name
          query = res[:query]
          unless query.is_a?(Parse::Query)
            raise ArgumentError, "Invalid Parse::Query object provided in :query field of value: #{@operation.operand}.matches_key_in_query => #{@value}"
          end
          query = query.compile(encode: false, includeClassName: true)
        elsif @value.is_a?(Parse::Query)
          # if its a query, then assume key is the same name as operand.
          query = @value.compile(encode: false, includeClassName: true)
        else
          raise ArgumentError, "Invalid `:matches_key_in_query` query constraint. It should follow the format: :field.matches_key_in_query => { key: 'key', query: '<Parse::Query>' }"
        end
        
        { @operation.operand => { :$select => { key: remote_field_name, query: query } } }
      end
    end

    # Equivalent to the `$dontSelect` Parse query operation but for key matching.
    # This matches objects where a field's value does NOT equal another field's value from a different query.
    # This is the inverse of the {MatchesKeyInQueryConstraint}.
    #
    #  # Find users where user.company does NOT equal customer.company
    #  customer_query = Customer.where(:active => true)
    #  user_query = User.where(:company.does_not_match_key => { key: "company", query: customer_query })
    #
    #  # If the local field has the same name as the remote field, you can omit the key
    #  # assumes key: 'company'
    #  user_query = User.where(:company.does_not_match_key => customer_query)
    #
    class DoesNotMatchKeyInQueryConstraint < Constraint
      # @!method does_not_match_key_in_query
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.does_not_match_key_in_query => { key: "remote_field", query: query }
      #  q.where :field.does_not_match_key_in_query => query # assumes same field name
      # @return [DoesNotMatchKeyInQueryConstraint]

      # @!method does_not_match_key
      # Alias for {does_not_match_key_in_query}
      # @return [DoesNotMatchKeyInQueryConstraint]
      constraint_keyword :$dontSelect
      register :does_not_match_key_in_query
      register :does_not_match_key

      # @return [Hash] the compiled constraint.
      def build
        remote_field_name = @operation.operand
        query = nil
        
        if @value.is_a?(Hash)
          res = @value.symbolize_keys
          remote_field_name = res[:key] || remote_field_name
          query = res[:query]
          unless query.is_a?(Parse::Query)
            raise ArgumentError, "Invalid Parse::Query object provided in :query field of value: #{@operation.operand}.does_not_match_key_in_query => #{@value}"
          end
          query = query.compile(encode: false, includeClassName: true)
        elsif @value.is_a?(Parse::Query)
          # if its a query, then assume key is the same name as operand.
          query = @value.compile(encode: false, includeClassName: true)
        else
          raise ArgumentError, "Invalid `:does_not_match_key_in_query` query constraint. It should follow the format: :field.does_not_match_key_in_query => { key: 'key', query: '<Parse::Query>' }"
        end
        
        { @operation.operand => { :$dontSelect => { key: remote_field_name, query: query } } }
      end
    end

    # Equivalent to using the `$regex` Parse query operation with a prefix pattern.
    # This is useful for autocomplete functionality and prefix matching.
    #
    #  # Find users whose name starts with "John"
    #  User.where(:name.starts_with => "John")
    #  # Generates: "name": { "$regex": "^John", "$options": "i" }
    #
    class StartsWithConstraint < Constraint
      # @!method starts_with
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$regex".
      # @example
      #  q.where :field.starts_with => "prefix"
      # @return [StartsWithConstraint]
      constraint_keyword :$regex
      register :starts_with

      # @return [Hash] the compiled constraint.
      def build
        value = formatted_value
        unless value.is_a?(String)
          raise ArgumentError, "#{self.class}: Value must be a string for starts_with constraint"
        end
        
        # Escape special regex characters in the prefix
        escaped_value = Regexp.escape(value)
        regex_pattern = "^#{escaped_value}"
        
        { @operation.operand => { :$regex => regex_pattern, :$options => "i" } }
      end
    end

    # Equivalent to using the `$regex` Parse query operation with a contains pattern.
    # This is useful for case-insensitive text search within fields.
    #
    #  # Find posts whose title contains "parse"
    #  Post.where(:title.contains => "parse")
    #  # Generates: "title": { "$regex": ".*parse.*", "$options": "i" }
    #
    class ContainsConstraint < Constraint
      # @!method contains
      # A registered method on a symbol to create the constraint. Maps to Parse operator "$regex".
      # @example
      #  q.where :field.contains => "text"
      # @return [ContainsConstraint]
      constraint_keyword :$regex
      register :contains

      # @return [Hash] the compiled constraint.
      def build
        value = formatted_value
        unless value.is_a?(String)
          raise ArgumentError, "#{self.class}: Value must be a string for contains constraint"
        end
        
        # Escape special regex characters in the search text
        escaped_value = Regexp.escape(value)
        regex_pattern = ".*#{escaped_value}.*"
        
        { @operation.operand => { :$regex => regex_pattern, :$options => "i" } }
      end
    end


    # A convenience constraint that combines greater-than-or-equal and less-than-or-equal
    # constraints for date/time range queries. This is equivalent to using both $gte and $lte.
    #
    #  # Find events between two dates
    #  Event.where(:created_at.between_dates => [start_date, end_date])
    #  # Generates: "created_at": { "$gte": start_date, "$lte": end_date }
    #
    class TimeRangeConstraint < Constraint
      # @!method between_dates
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.between_dates => [start_date, end_date]
      # @return [TimeRangeConstraint]
      register :between_dates

      # @return [Hash] the compiled constraint.
      def build
        value = formatted_value
        unless value.is_a?(Array) && value.length == 2
          raise ArgumentError, "#{self.class}: Value must be an array with exactly 2 elements [start_date, end_date]"
        end
        
        start_date, end_date = value
        
        # Format the dates using Parse's date formatting
        formatted_start = Parse::Constraint.formatted_value(start_date)
        formatted_end = Parse::Constraint.formatted_value(end_date)
        
        { @operation.operand => { 
          Parse::Constraint::GreaterThanOrEqualConstraint.key => formatted_start,
          Parse::Constraint::LessThanOrEqualConstraint.key => formatted_end
        } }
      end
    end

    # A general range constraint that combines greater-than-or-equal and less-than-or-equal
    # constraints for numeric, date/time, and string range queries. This is equivalent to using both $gte and $lte.
    # This constraint works with numbers, dates, times, strings (alphabetical), and any comparable values.
    #
    #  # Find products with price between 10 and 50
    #  Product.where(:price.between => [10, 50])
    #  # Generates: "price": { "$gte": 10, "$lte": 50 }
    #
    #  # Find events between two dates
    #  Event.where(:created_at.between => [start_date, end_date])
    #  # Generates: "created_at": { "$gte": start_date, "$lte": end_date }
    #
    #  # Find users with age between 18 and 65
    #  User.where(:age.between => [18, 65])
    #  # Generates: "age": { "$gte": 18, "$lte": 65 }
    #
    #  # Find users with names alphabetically between "Alice" and "John"
    #  User.where(:name.between => ["Alice", "John"])
    #  # Generates: "name": { "$gte": "Alice", "$lte": "John" }
    #
    class BetweenConstraint < Constraint
      # @!method between
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.between => [min_value, max_value]
      # @return [BetweenConstraint]
      register :between

      # @return [Hash] the compiled constraint.
      def build
        value = formatted_value
        unless value.is_a?(Array) && value.length == 2
          raise ArgumentError, "#{self.class}: Value must be an array with exactly 2 elements [min_value, max_value]"
        end
        
        min_value, max_value = value
        
        # Format the values using Parse's formatting (handles dates, numbers, etc.)
        formatted_min = Parse::Constraint.formatted_value(min_value)
        formatted_max = Parse::Constraint.formatted_value(max_value)
        
        { @operation.operand => { 
          Parse::Constraint::GreaterThanOrEqualConstraint.key => formatted_min,
          Parse::Constraint::LessThanOrEqualConstraint.key => formatted_max
        } }
      end
    end

    # A constraint for filtering objects based on ACL read permissions for specific users or roles.
    # This constraint queries the MongoDB _rperm field directly, which contains an array of user IDs 
    # and role names that have read access to the object.
    #
    #  # Find objects readable by a specific user (includes user ID + their roles)
    #  Post.where(:ACL.readable_by => user)
    #  
    #  # Find objects readable by specific role names (strings are treated as role names)
    #  Post.where(:ACL.readable_by => ["Admin", "Moderator"])
    #  
    #  # Find objects readable by a single role name
    #  Post.where(:ACL.readable_by => "Admin")
    #  
    #  # Mix users and role names
    #  Post.where(:ACL.readable_by => [user1, user2, "Admin", "Moderator"])
    #
    class ACLReadableByConstraint < Constraint
      # @!method readable_by
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :ACL.readable_by => user_or_roles
      # @return [ACLReadableByConstraint]
      register :readable_by

      # @return [Hash] the compiled constraint using _rperm field.
      def build
        value = formatted_value
        permissions_to_check = []
        
        # Handle different input types using duck typing
        if value.is_a?(Parse::User) || (value.respond_to?(:is_a?) && value.is_a?(Parse::User))
          # For a user, include their ID and all their role names
          permissions_to_check << value.id if value.respond_to?(:id) && value.id.present?
          
          # Automatically fetch user's roles from Parse
          # Parse stores user roles as objects in _Role collection that have this user in their 'users' relation
          begin
            if value.respond_to?(:id) && value.id.present? && defined?(Parse::Role)
              # Query roles that contain this user
              user_roles = Parse::Role.all(users: value)
              user_roles.each do |role|
                permissions_to_check << "role:#{role.name}" if role.respond_to?(:name) && role.name.present?
              end
            end
          rescue => e
            # If role fetching fails, continue with just the user ID
            # This allows the constraint to work even if role queries fail
          end
          
        elsif value.is_a?(Parse::Role) || (value.respond_to?(:is_a?) && value.is_a?(Parse::Role))
          # For a role, add the role name with "role:" prefix
          permissions_to_check << "role:#{value.name}" if value.respond_to?(:name) && value.name.present?
          
        elsif value.is_a?(Parse::Pointer) || (value.respond_to?(:parse_class) && value.respond_to?(:id))
          # Handle pointer to User or Role
          if value.respond_to?(:parse_class) && (value.parse_class == "User" || value.parse_class == "_User")
            permissions_to_check << value.id if value.respond_to?(:id) && value.id.present?

            # Query roles directly using the user pointer (no need to fetch the full user)
            begin
              if value.respond_to?(:id) && value.id.present? && defined?(Parse::Role)
                user_roles = Parse::Role.all(users: value)
                user_roles.each do |role|
                  permissions_to_check << "role:#{role.name}" if role.respond_to?(:name) && role.name.present?
                end
              end
            rescue => e
              # If role fetching fails, continue with just the user ID
            end
          elsif value.respond_to?(:parse_class) && (value.parse_class == "Role" || value.parse_class == "_Role")
            # For role pointers, we need the role name, but we only have the ID
            # We'd need to fetch the role to get its name, so for now skip this
            # or require that role names be passed as strings
          end
          
        elsif value.is_a?(Array)
          # Handle array of role names, user IDs, or mixed
          value.each do |item|
            if item.is_a?(Parse::User) || (item.respond_to?(:is_a?) && item.is_a?(Parse::User))
              permissions_to_check << item.id if item.respond_to?(:id) && item.id.present?
            elsif item.is_a?(Parse::Role) || (item.respond_to?(:is_a?) && item.is_a?(Parse::Role))
              permissions_to_check << "role:#{item.name}" if item.respond_to?(:name) && item.name.present?
            elsif item.is_a?(Parse::Pointer) || (item.respond_to?(:parse_class) && item.respond_to?(:id))
              # Handle pointer to User
              if item.respond_to?(:parse_class) && (item.parse_class == "User" || item.parse_class == "_User")
                permissions_to_check << item.id if item.respond_to?(:id) && item.id.present?
              end
            elsif item.is_a?(String)
              # Treat all strings as role names or public access
              if item == "*"
                # Special case for public access - don't add role: prefix
                permissions_to_check << "*"
              elsif item.start_with?("role:")
                permissions_to_check << item
              else
                # Assume it's a role name, add role: prefix
                permissions_to_check << "role:#{item}"
              end
            end
          end
          
        elsif value.is_a?(String)
          # Handle single string - only accept "*" for public access or "role:name" format
          if value == "*"
            # Special case for public access - don't add role: prefix
            permissions_to_check << "*"
          elsif value.start_with?("role:")
            permissions_to_check << value
          else
            # For role names, add role: prefix
            permissions_to_check << "role:#{value}"
          end
          
        else
          raise ArgumentError, "ACLReadableByConstraint: value must be a User, Role, String, or Array of these types"
        end
        
        if permissions_to_check.empty?
          raise ArgumentError, "ACLReadableByConstraint: no valid permissions found in provided value"
        end
        
        # Query the _rperm field through aggregation pipeline since Parse Server
        # doesn't expose _rperm/_wperm fields through regular REST API queries
        # _rperm contains an array of user IDs and role names that have read access
        # Also include public access "*" in the check
        permissions_with_public = permissions_to_check + ["*"]
        
        # Build the aggregation pipeline to match documents with _rperm field
        # Also match documents where _rperm doesn't exist (publicly accessible)
        pipeline = [
          {
            "$match" => {
              "$or" => [
                { "_rperm" => { "$in" => permissions_with_public } },
                { "_rperm" => { "$exists" => false } }
              ]
            }
          }
        ]
        
        # Return a special marker that indicates this needs aggregation pipeline processing
        { "__aggregation_pipeline" => pipeline }
      end
    end

    # A constraint for filtering objects based on ACL write permissions for specific users or roles.
    # This constraint queries the MongoDB _wperm field directly, which contains an array of user IDs 
    # and role names that have write access to the object.
    #
    #  # Find objects writable by a specific user (includes user ID + their roles)
    #  Post.where(:ACL.writable_by => user)
    #  
    #  # Find objects writable by specific role names (strings are treated as role names)
    #  Post.where(:ACL.writable_by => ["Admin", "Moderator"])
    #  
    #  # Find objects writable by a single role name
    #  Post.where(:ACL.writable_by => "Admin")
    #  
    #  # Mix users and role names
    #  Post.where(:ACL.writable_by => [user1, user2, "Admin", "Moderator"])
    #
    class ACLWritableByConstraint < Constraint
      # @!method writable_by
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :ACL.writable_by => user_or_roles
      # @return [ACLWritableByConstraint]
      register :writable_by

      # @return [Hash] the compiled constraint using _wperm field.
      def build
        value = formatted_value
        permissions_to_check = []
        
        # Handle different input types using duck typing
        if value.is_a?(Parse::User) || (value.respond_to?(:is_a?) && value.is_a?(Parse::User))
          # For a user, include their ID and all their role names
          permissions_to_check << value.id if value.respond_to?(:id) && value.id.present?
          
          # Automatically fetch user's roles from Parse
          # Parse stores user roles as objects in _Role collection that have this user in their 'users' relation
          begin
            if value.respond_to?(:id) && value.id.present? && defined?(Parse::Role)
              # Query roles that contain this user
              user_roles = Parse::Role.all(users: value)
              user_roles.each do |role|
                permissions_to_check << "role:#{role.name}" if role.respond_to?(:name) && role.name.present?
              end
            end
          rescue => e
            # If role fetching fails, continue with just the user ID
            # This allows the constraint to work even if role queries fail
          end
          
        elsif value.is_a?(Parse::Role) || (value.respond_to?(:is_a?) && value.is_a?(Parse::Role))
          # For a role, add the role name with "role:" prefix
          permissions_to_check << "role:#{value.name}" if value.respond_to?(:name) && value.name.present?
          
        elsif value.is_a?(Parse::Pointer) || (value.respond_to?(:parse_class) && value.respond_to?(:id))
          # Handle pointer to User or Role
          if value.respond_to?(:parse_class) && (value.parse_class == "User" || value.parse_class == "_User")
            permissions_to_check << value.id if value.respond_to?(:id) && value.id.present?

            # Query roles directly using the user pointer (no need to fetch the full user)
            begin
              if value.respond_to?(:id) && value.id.present? && defined?(Parse::Role)
                user_roles = Parse::Role.all(users: value)
                user_roles.each do |role|
                  permissions_to_check << "role:#{role.name}" if role.respond_to?(:name) && role.name.present?
                end
              end
            rescue => e
              # If role fetching fails, continue with just the user ID
            end
          elsif value.respond_to?(:parse_class) && (value.parse_class == "Role" || value.parse_class == "_Role")
            # For role pointers, we need the role name, but we only have the ID
            # We'd need to fetch the role to get its name, so for now skip this
            # or require that role names be passed as strings
          end
          
        elsif value.is_a?(Array)
          # Handle array of role names, user IDs, or mixed
          value.each do |item|
            if item.is_a?(Parse::User) || (item.respond_to?(:is_a?) && item.is_a?(Parse::User))
              permissions_to_check << item.id if item.respond_to?(:id) && item.id.present?
            elsif item.is_a?(Parse::Role) || (item.respond_to?(:is_a?) && item.is_a?(Parse::Role))
              permissions_to_check << "role:#{item.name}" if item.respond_to?(:name) && item.name.present?
            elsif item.is_a?(Parse::Pointer) || (item.respond_to?(:parse_class) && item.respond_to?(:id))
              # Handle pointer to User
              if item.respond_to?(:parse_class) && (item.parse_class == "User" || item.parse_class == "_User")
                permissions_to_check << item.id if item.respond_to?(:id) && item.id.present?
              end
            elsif item.is_a?(String)
              # Treat all strings as role names or public access
              if item == "*"
                # Special case for public access - don't add role: prefix
                permissions_to_check << "*"
              elsif item.start_with?("role:")
                permissions_to_check << item
              else
                # Assume it's a role name, add role: prefix
                permissions_to_check << "role:#{item}"
              end
            end
          end
          
        elsif value.is_a?(String)
          # Handle single string - only accept "*" for public access or "role:name" format
          if value == "*"
            # Special case for public access - don't add role: prefix
            permissions_to_check << "*"
          elsif value.start_with?("role:")
            permissions_to_check << value
          else
            # For role names, add role: prefix
            permissions_to_check << "role:#{value}"
          end
          
        else
          raise ArgumentError, "ACLWritableByConstraint: value must be a User, Role, String, or Array of these types"
        end
        
        if permissions_to_check.empty?
          raise ArgumentError, "ACLWritableByConstraint: no valid permissions found in provided value"
        end
        
        # Query the _wperm field through aggregation pipeline since Parse Server
        # doesn't expose _rperm/_wperm fields through regular REST API queries
        # _wperm contains an array of user IDs and role names that have write access
        # Also include public access "*" in the check
        permissions_with_public = permissions_to_check + ["*"]
        
        # Build the aggregation pipeline to match documents with _wperm field
        # Also match documents where _wperm doesn't exist (publicly writable)
        pipeline = [
          {
            "$match" => {
              "$or" => [
                { "_wperm" => { "$in" => permissions_with_public } },
                { "_wperm" => { "$exists" => false } }
              ]
            }
          }
        ]
        
        # Return a special marker that indicates this needs aggregation pipeline processing
        { "__aggregation_pipeline" => pipeline }
      end
    end

    # A constraint for comparing pointer fields through linked objects using MongoDB aggregation.
    # This allows comparing ObjectA.field1 with ObjectA.linkedObject.field2 where both are pointers.
    #
    #  # Find ObjectA where ObjectA.author equals ObjectA.project.owner
    #  ObjectA.where(:author.equals_linked_pointer => { through: :project, field: :owner })
    #  
    #  # This generates a MongoDB aggregation pipeline with $lookup and $expr
    #  # to compare pointer fields across linked documents
    #
    class PointerEqualsLinkedPointerConstraint < Constraint
      # @!method equals_linked_pointer
      # A registered method on a symbol to create the constraint.
      # @example
      #  q.where :field.equals_linked_pointer => { through: :linked_field, field: :target_field }
      # @return [PointerEqualsLinkedPointerConstraint]
      register :equals_linked_pointer

      # @return [Hash] the compiled constraint.
      def build
        unless @value.is_a?(Hash) && @value[:through] && @value[:field]
          raise ArgumentError, "equals_linked_pointer requires: { through: :linked_field, field: :target_field }"
        end

        through_field = @value[:through]
        target_field = @value[:field]
        local_field = @operation.operand

        # Format field names according to Parse conventions
        # Pointer fields in MongoDB are stored with _p_ prefix
        formatted_through = "_p_" + Parse::Query.format_field(through_field)
        formatted_target = "_p_" + Parse::Query.format_field(target_field)
        formatted_local = "_p_" + Parse::Query.format_field(local_field)

        # Determine the target collection name from the through field
        # Use classify to convert field name to class name (e.g., :project -> "Project")
        target_collection = through_field.to_s.classify

        # Build the aggregation pipeline
        # Use clean alias name without _p_ prefix for readability
        lookup_alias = "#{through_field.to_s.camelize(:lower)}_data"
        
        # Parse stores pointers as "ClassName$objectId" strings
        # We need to extract just the objectId part after the $
        pipeline = [
          {
            "$addFields" => {
              "#{formatted_through}_id" => {
                "$substr" => [
                  "$#{formatted_through}",
                  target_collection.length + 1,  # Skip "ClassName$"
                  -1  # Rest of string
                ]
              }
            }
          },
          {
            "$lookup" => {
              "from" => target_collection,
              "localField" => formatted_through,
              "foreignField" => "_id", 
              "as" => lookup_alias
            }
          },
          {
            "$match" => {
              "$expr" => {
                "$eq" => [
                  { "$arrayElemAt" => ["$#{lookup_alias}.#{formatted_target}", 0] },
                  "$#{formatted_local}"
                ]
              }
            }
          }
        ]

        # Return a special marker that indicates this needs aggregation pipeline processing
        { "__aggregation_pipeline" => pipeline }
      end
    end

    # Constraint for comparing pointer fields where they do NOT equal through linked objects.
    # Uses MongoDB's $lookup to join collections and $expr with $ne to compare fields.
    #
    # Usage:
    #   Asset.where(:project.does_not_equal_linked_pointer => { through: :capture, field: :project })
    #
    # This generates a MongoDB aggregation pipeline that:
    # 1. Uses $lookup to join the linked collection
    # 2. Uses $match with $expr and $ne to find records where fields do NOT match
    #
    # @example Find assets where the project does not equal the capture's project
    #   Asset.where(:project.does_not_equal_linked_pointer => { 
    #     through: :capture, 
    #     field: :project 
    #   })
    class DoesNotEqualLinkedPointerConstraint < Constraint
      register :does_not_equal_linked_pointer

      # Builds the MongoDB aggregation pipeline for the does-not-equal-linked-pointer constraint
      # @return [Hash] Hash containing the aggregation pipeline
      # @raise [ArgumentError] if required parameters are missing or invalid
      def build
        # Validate that value is a hash with required keys
        unless @value.is_a?(Hash) && @value[:through] && @value[:field]
          raise ArgumentError, "DoesNotEqualLinkedPointerConstraint requires a hash with :through and :field keys"
        end

        through_field = @value[:through]
        target_field = @value[:field]
        
        # Convert field names to Parse format (snake_case to camelCase) with _p_ prefix for pointers
        local_field_name = format_field_name(@operation.operand, is_pointer: true)
        through_field_name = format_field_name(through_field, is_pointer: true)
        target_field_name = format_field_name(target_field, is_pointer: true)
        
        # Determine the collection name for the lookup (Rails pluralization)
        through_class_name = through_field.to_s.classify
        lookup_collection = through_class_name
        
        # Generate unique alias name for the joined data (use clean name without _p_ prefix)
        lookup_alias = "#{through_field.to_s.camelize(:lower)}_data"
        
        # Build the MongoDB aggregation pipeline
        pipeline = []
        
        # Parse stores pointers as "ClassName$objectId" strings
        # We need to extract just the objectId part after the $
        # Stage 1: Add field with extracted objectId
        add_fields_stage = {
          "$addFields" => {
            "#{through_field_name}_id" => {
              "$substr" => [
                "$#{through_field_name}",
                lookup_collection.length + 1,  # Skip "ClassName$"
                -1  # Rest of string
              ]
            }
          }
        }
        pipeline << add_fields_stage
        
        # Stage 2: $lookup to join the linked collection
        lookup_stage = {
          "$lookup" => {
            "from" => lookup_collection,
            "localField" => through_field_name,
            "foreignField" => "_id", 
            "as" => lookup_alias
          }
        }
        pipeline << lookup_stage
        
        # Stage 2: $match with $expr to compare the fields using $ne (not equal)
        match_stage = {
          "$match" => {
            "$expr" => {
              "$ne" => [
                { "$arrayElemAt" => ["$#{lookup_alias}.#{target_field_name}", 0] },
                "$#{local_field_name}"
              ]
            }
          }
        }
        pipeline << match_stage
        
        # Return a special marker that indicates this needs aggregation pipeline processing
        { "__aggregation_pipeline" => pipeline }
      end
      
      private
      
      # Converts field names from snake_case to camelCase for Parse Server compatibility
      # and adds _p_ prefix for pointer fields in MongoDB
      # @param field [Symbol, String] the field name to format
      # @param is_pointer [Boolean] whether this field is a pointer field
      # @return [String] the formatted field name
      def format_field_name(field, is_pointer: true)
        formatted = field.to_s.camelize(:lower)
        # Add _p_ prefix for pointer fields as they're stored that way in MongoDB
        is_pointer ? "_p_#{formatted}" : formatted
      end
    end
  end
end
