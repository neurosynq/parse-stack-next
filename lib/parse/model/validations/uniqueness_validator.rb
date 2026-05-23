# encoding: UTF-8
# frozen_string_literal: true

require "active_model"

module Parse
  module Validations
    # A custom validator that checks if a field value is unique in the Parse collection.
    #
    # This validator queries Parse Server to check if another record exists with the
    # same value for the specified field. It properly handles:
    # - New records (no id yet)
    # - Existing records (excludes self from the check)
    # - Case-insensitive matching (optional)
    # - Scoped uniqueness (unique within a subset of records)
    #
    # @example Basic uniqueness
    #   class User < Parse::Object
    #     property :email, :string
    #     validates :email, uniqueness: true
    #   end
    #
    # @example Case-insensitive uniqueness
    #   class User < Parse::Object
    #     property :username, :string
    #     validates :username, uniqueness: { case_sensitive: false }
    #   end
    #
    # @example Scoped uniqueness (unique within an organization)
    #   class Employee < Parse::Object
    #     property :employee_id, :string
    #     belongs_to :organization
    #     validates :employee_id, uniqueness: { scope: :organization }
    #   end
    #
    # @example With custom message
    #   class User < Parse::Object
    #     property :email, :string
    #     validates :email, uniqueness: { message: "is already registered" }
    #   end
    #
    class UniquenessValidator < ActiveModel::EachValidator
      # @param record [Parse::Object] the object being validated
      # @param attribute [Symbol] the attribute name being validated
      # @param value [Object] the current value of the attribute
      def validate_each(record, attribute, value)
        return if value.blank? && options[:allow_blank]
        return if value.nil? && options[:allow_nil]

        # Build the query to check for existing records
        klass = record.class

        # Get the Parse field name for this attribute (available for debugging)
        _parse_field = klass.field_map[attribute] || attribute.to_s.columnize

        # Build query conditions
        conditions = {}

        if options[:case_sensitive] == false && value.is_a?(String)
          # Case-insensitive search using regex
          conditions[attribute.to_sym] = /\A#{Regexp.escape(value)}\z/i
        else
          conditions[attribute.to_sym] = value
        end

        # Add scope conditions if specified
        if options[:scope]
          scope_fields = Array(options[:scope])
          scope_fields.each do |scope_field|
            scope_value = record.send(scope_field)
            conditions[scope_field.to_sym] = scope_value
          end
        end

        # Build and execute the query
        query = klass.query(conditions)

        # Exclude the current record if it's not new
        unless record.new?
          query.where(:id.not => record.id)
        end

        # Check if any matching records exist
        query.limit(1)
        existing = query.first

        if existing.present?
          error_message = options[:message] || "has already been taken"
          record.errors.add(attribute, error_message)
        end
      end
    end
  end
end

# Register the validator with ActiveModel so it can be used with validates helper
ActiveModel::Validations::UniquenessValidator = Parse::Validations::UniquenessValidator
