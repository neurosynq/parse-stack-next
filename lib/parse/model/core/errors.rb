# encoding: UTF-8
# frozen_string_literal: true

# The set of all Parse errors.
module Parse
  # An abstract parent class for all Parse::Error types.
  class Error < StandardError; end

  # Raised when attempting to access a field that was not fetched on a partially
  # fetched object when autofetch has been disabled.
  class UnfetchedFieldAccessError < Error
    attr_reader :field_name, :object_class

    def initialize(field_name, object_class)
      @field_name = field_name
      @object_class = object_class
      super("Attempted to access unfetched field '#{field_name}' on #{object_class} with autofetch disabled. " \
            "Either fetch the object first, include this field in the keys parameter, or enable autofetch.")
    end
  end
end
