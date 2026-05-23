require_relative "../../test_helper"

# Test model for validation context
class ValidationContextTestModel < Parse::Object
  property :name, :string
  property :create_only_field, :string
  property :update_only_field, :string
  property :always_required_field, :string

  # Track which callbacks were called
  attr_accessor :before_validation_create_called, :before_validation_update_called,
                :before_validation_always_called

  # Callbacks with context
  before_validation :set_before_validation_create_called, on: :create
  before_validation :set_before_validation_update_called, on: :update
  before_validation :set_before_validation_always_called

  # Validations with context
  validates :create_only_field, presence: true, on: :create
  validates :update_only_field, presence: true, on: :update
  validates :always_required_field, presence: true

  def set_before_validation_create_called
    self.before_validation_create_called = true
  end

  def set_before_validation_update_called
    self.before_validation_update_called = true
  end

  def set_before_validation_always_called
    self.before_validation_always_called = true
  end
end

# Test model for setting defaults in before_validation on: :create
class DefaultsTestModel < Parse::Object
  property :name, :string, required: true
  property :status, :string, required: true
  property :counter, :integer, required: true

  before_validation :set_defaults, on: :create

  def set_defaults
    self.status ||= "pending"
    self.counter ||= 0
  end
end

class ValidationContextTest < Minitest::Test
  def test_before_validation_on_create_only_runs_for_new_objects
    puts "\n=== Testing before_validation on: :create ==="

    model = ValidationContextTestModel.new(
      name: "Test",
      create_only_field: "value",
      always_required_field: "value",
    )

    # Simulate a new object validation (what save does)
    model.valid?(:create)

    assert model.before_validation_create_called,
           "before_validation with on: :create should be called for new objects"
    assert_nil model.before_validation_update_called,
               "before_validation with on: :update should NOT be called for new objects"
    assert model.before_validation_always_called,
           "before_validation without :on should always be called"

    puts "  before_validation_create_called: #{model.before_validation_create_called}"
    puts "  before_validation_update_called: #{model.before_validation_update_called.inspect}"
    puts "  before_validation_always_called: #{model.before_validation_always_called}"
  end

  def test_before_validation_on_update_only_runs_for_existing_objects
    puts "\n=== Testing before_validation on: :update ==="

    model = ValidationContextTestModel.new(
      name: "Test",
      update_only_field: "value",
      always_required_field: "value",
    )
    # Simulate an existing object by setting an id
    model.instance_variable_set(:@id, "existingId123")
    model.disable_autofetch!

    # Simulate an existing object validation (what save does)
    model.valid?(:update)

    assert_nil model.before_validation_create_called,
               "before_validation with on: :create should NOT be called for existing objects"
    assert model.before_validation_update_called,
           "before_validation with on: :update should be called for existing objects"
    assert model.before_validation_always_called,
           "before_validation without :on should always be called"

    puts "  before_validation_create_called: #{model.before_validation_create_called.inspect}"
    puts "  before_validation_update_called: #{model.before_validation_update_called}"
    puts "  before_validation_always_called: #{model.before_validation_always_called}"
  end

  def test_validates_on_create_only_validates_for_new_objects
    puts "\n=== Testing validates on: :create ==="

    # New object without create_only_field should fail
    model = ValidationContextTestModel.new(
      name: "Test",
      always_required_field: "value",
      # create_only_field is missing
    )

    assert !model.valid?(:create),
           "Validation should fail for new object missing create_only_field"
    assert model.errors[:create_only_field].present?,
           "Should have error for missing create_only_field"

    puts "  Errors on :create context: #{model.errors.full_messages}"

    # Same model should pass update validation (create_only_field not required)
    # But we need to set update_only_field which IS required on :update
    model.errors.clear
    model.instance_variable_set(:@id, "existingId123")
    model.disable_autofetch!
    model.update_only_field = "value"

    assert model.valid?(:update),
           "Validation should pass for existing object without create_only_field (but with update_only_field)"

    puts "  Errors on :update context: #{model.errors.full_messages.inspect}"
  end

  def test_validates_on_update_only_validates_for_existing_objects
    puts "\n=== Testing validates on: :update ==="

    # New object without update_only_field should pass
    model = ValidationContextTestModel.new(
      name: "Test",
      create_only_field: "value",
      always_required_field: "value",
      # update_only_field is missing
    )

    assert model.valid?(:create),
           "Validation should pass for new object without update_only_field"

    puts "  Errors on :create context: #{model.errors.full_messages.inspect}"

    # Existing object without update_only_field should fail
    model.errors.clear
    model.instance_variable_set(:@id, "existingId123")
    model.disable_autofetch!

    assert !model.valid?(:update),
           "Validation should fail for existing object missing update_only_field"
    assert model.errors[:update_only_field].present?,
           "Should have error for missing update_only_field"

    puts "  Errors on :update context: #{model.errors.full_messages}"
  end

  def test_setting_defaults_in_before_validation_on_create
    puts "\n=== Testing setting defaults in before_validation on: :create ==="

    model = DefaultsTestModel.new(name: "Test Item")

    # Before validation, defaults should not be set
    assert_nil model.status, "Status should be nil before validation"
    assert_nil model.counter, "Counter should be nil before validation"

    # Run validation with :create context
    result = model.valid?(:create)

    # Defaults should now be set
    assert_equal "pending", model.status, "Status should be set to default 'pending'"
    assert_equal 0, model.counter, "Counter should be set to default 0"
    assert result, "Model should be valid after defaults are set"

    puts "  status after validation: #{model.status}"
    puts "  counter after validation: #{model.counter}"
    puts "  valid?: #{result}"
  end

  def test_defaults_not_overwritten_if_already_set
    puts "\n=== Testing defaults not overwritten if already set ==="

    model = DefaultsTestModel.new(
      name: "Test Item",
      status: "active",
      counter: 5,
    )

    # Run validation with :create context
    model.valid?(:create)

    # Values should not be overwritten
    assert_equal "active", model.status, "Status should remain 'active'"
    assert_equal 5, model.counter, "Counter should remain 5"

    puts "  status after validation: #{model.status}"
    puts "  counter after validation: #{model.counter}"
  end

  def test_before_validation_on_create_not_called_on_update
    puts "\n=== Testing before_validation on: :create not called on update ==="

    model = DefaultsTestModel.new(name: "Test Item")
    model.instance_variable_set(:@id, "existingId123")
    model.disable_autofetch!

    # For existing objects, before_validation on: :create should NOT run
    # So status and counter will remain nil
    model.valid?(:update)

    assert_nil model.status, "Status should remain nil for update context"
    assert_nil model.counter, "Counter should remain nil for update context"

    puts "  status after :update validation: #{model.status.inspect}"
    puts "  counter after :update validation: #{model.counter.inspect}"
  end

  def test_save_uses_create_context_for_new_object
    puts "\n=== Testing save uses :create context for new objects ==="

    # We verify the context is passed by checking if the callbacks are triggered correctly
    # For new objects, before_validation on: :create should run
    model = ValidationContextTestModel.new(
      name: "Test",
      create_only_field: "value",
      always_required_field: "value",
    )

    # Determine context that save() would use
    validation_context = model.new? ? :create : :update
    assert_equal :create, validation_context, "New object should use :create context"

    # Run validation with the context save() would use
    model.valid?(validation_context)

    assert model.before_validation_create_called,
           "before_validation on: :create should be called for new object"
    assert_nil model.before_validation_update_called,
               "before_validation on: :update should NOT be called for new object"

    puts "  validation_context: #{validation_context}"
    puts "  before_validation_create_called: #{model.before_validation_create_called}"
    puts "  before_validation_update_called: #{model.before_validation_update_called.inspect}"
  end

  def test_save_uses_update_context_for_existing_object
    puts "\n=== Testing save uses :update context for existing objects ==="

    model = ValidationContextTestModel.new(
      name: "Test",
      update_only_field: "value",
      always_required_field: "value",
    )
    model.instance_variable_set(:@id, "existingId123")
    model.disable_autofetch!

    # Determine context that save() would use
    validation_context = model.new? ? :create : :update
    assert_equal :update, validation_context, "Existing object should use :update context"

    # Run validation with the context save() would use
    model.valid?(validation_context)

    assert_nil model.before_validation_create_called,
               "before_validation on: :create should NOT be called for existing object"
    assert model.before_validation_update_called,
           "before_validation on: :update should be called for existing object"

    puts "  validation_context: #{validation_context}"
    puts "  before_validation_create_called: #{model.before_validation_create_called.inspect}"
    puts "  before_validation_update_called: #{model.before_validation_update_called}"
  end
end
