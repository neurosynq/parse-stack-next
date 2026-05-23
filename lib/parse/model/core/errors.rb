# encoding: UTF-8
# frozen_string_literal: true

# The set of all Parse errors.
module Parse
  # An abstract parent class for all Parse::Error types.
  #
  # Supports both legacy single-argument construction (`raise Parse::Error, "msg"`)
  # and two-argument construction with a Parse error code
  # (`raise Parse::Error.new(code, "msg")`). When a code is provided it is
  # exposed via {#code} and prefixed onto the message.
  class Error < StandardError
    # @return [Integer, String, nil] the Parse error code when constructed with one.
    attr_reader :code

    def initialize(code_or_message = nil, message = nil)
      if message.nil?
        super(code_or_message)
      else
        @code = code_or_message
        super("[#{code_or_message}] #{message}")
      end
    end
  end

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
