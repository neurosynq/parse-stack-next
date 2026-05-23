# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Core
    # Enhanced change tracking for Parse::Object that provides additional
    # _was_changed? and enhanced _was methods for after_save hooks.
    #
    # This module adds _was_changed? methods that work correctly in after_save contexts
    # by using previous_changes, while keeping normal _changed? methods intact.
    #
    # Key benefits:
    # - _was_changed? methods work correctly in after_save hooks  
    # - _was methods return actual previous values (not current values) in after_save
    # - Normal _changed? methods remain unchanged (standard ActiveModel behavior)
    # - Automatically detects context using presence of previous_changes
    #
    # @example
    #   class Product < Parse::Object
    #     property :name, :string
    #     property :price, :float
    #     
    #     after_save :send_price_alert
    #     
    #     def send_price_alert
    #       if price_was_changed? && price_was < price
    #         AlertService.send("Price increased from $#{price_was} to $#{price}")
    #       end
    #     end
    #   end
    module EnhancedChangeTracking
      
      def self.included(base)
        base.extend(ClassMethods)
      end
      
      module ClassMethods
        # Override the property method to add enhanced change tracking
        # after the ActiveModel methods are defined
        def property(key, data_type = :string, **opts)
          result = super # Call the original property method
          
          # After property is defined, override the _changed? and _was methods
          enhance_change_tracking_for_field(key)
          
          result
        end
        
        private
        
        # Create enhanced versions of _was_changed? and _was methods for a field
        # @param field_name [Symbol] the field name to enhance
        def enhance_change_tracking_for_field(field_name)
          was_changed_method = "#{field_name}_was_changed?"
          was_method = "#{field_name}_was"

          # Store reference to original _was method if it exists
          # Only alias if not already aliased (prevents infinite recursion)
          original_was_method = "__original_#{was_method}".to_sym
          if instance_method_defined?(was_method) && !instance_method_defined?(original_was_method)
            alias_method original_was_method, was_method
          end
          
          # Define enhanced _was_changed? method (for after_save context)
          define_method(was_changed_method) do
            enhanced_field_changed?(field_name.to_s)
          end
          
          # Define enhanced _was method
          define_method(was_method) do
            enhanced_field_was(field_name.to_s)
          end
        end
        
        # Check if an instance method is defined
        # @param method_name [String, Symbol] the method name
        # @return [Boolean] true if the method is defined
        def instance_method_defined?(method_name)
          method_defined?(method_name) || private_method_defined?(method_name)
        end
      end
      
      private
      
      # Enhanced implementation of field_changed? that works in all contexts
      # @param field_name [String] the name of the field to check
      # @return [Boolean] true if the field was changed, false otherwise
      def enhanced_field_changed?(field_name)
        # In before_save context: use current changes (ActiveModel's changed? method)
        # In after_save context: use previous_changes to see what was just changed
        if in_after_save_context?
          # Use previous_changes for after_save hooks
          if previous_changes_available?
            return previous_changes.key?(field_name.to_s)
          end
        else
          # Use original ActiveModel method for before_save hooks and general usage
          original_method = "__original_#{field_name}_changed?".to_sym
          if respond_to?(original_method, true)
            return send(original_method)
          end
          
          # Fallback: check if field is in current changes
          return changed.include?(field_name.to_s) if respond_to?(:changed)
        end
        
        # Default fallback
        false
      end
      
      # Enhanced implementation of field_was that works in all contexts
      # @param field_name [String] the name of the field to get previous value for
      # @return [Object] the previous value of the field
      def enhanced_field_was(field_name)
        # In after_save context: use previous_changes to get what was just changed
        if in_after_save_context?
          if previous_changes_available? && previous_changes[field_name.to_s]
            return previous_changes[field_name.to_s][0] # [old_value, new_value]
          end
        else
          # In before_save context: use original ActiveModel method for current operation
          original_method = "__original_#{field_name}_was".to_sym
          if respond_to?(original_method, true)
            return send(original_method)
          end
          
          # Fallback: try to get from changes if field is currently changed
          if respond_to?(:changes) && changes[field_name.to_s]
            return changes[field_name.to_s][0] # [old_value, new_value]
          end
        end
        
        # Default fallback to current value if no change detected
        respond_to?(field_name) ? send(field_name) : nil
      end
      
      # Check if previous_changes is available and populated
      # @return [Boolean] true if previous_changes is available
      def previous_changes_available?
        respond_to?(:previous_changes) && 
        previous_changes.is_a?(Hash) && 
        !previous_changes.empty?
      end
      
      # Detect if we're currently in an after_save context
      # This is a heuristic based on the state of changes vs previous_changes
      # @return [Boolean] true if likely in after_save context
      def in_after_save_context?
        # In after_save context:
        # - previous_changes is populated (from the save that just completed)
        # - current changes should be empty (cleared by successful save)
        return false unless previous_changes_available?
        return false unless respond_to?(:changed)
        
        # If we have previous_changes but no current changes, we're likely in after_save
        changed.empty?
      end
    end
  end
end