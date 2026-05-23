# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # DSL module that adds agent metadata capabilities to Parse::Object models.
    # Allows models to self-document with descriptions and expose safe methods
    # to the Parse Agent for LLM interaction.
    #
    # @example Define a model with agent metadata
    #   class Team < Parse::Object
    #     agent_description "A group of users contributing to a Project"
    #
    #     property :name, :string, description: "The team's display name"
    #     property :member_count, :integer, description: "Number of active members"
    #
    #     agent_method :active_projects, "Returns projects currently in progress"
    #     agent_method :member_names, "Returns array of member display names"
    #
    #     def self.active_projects
    #       Project.query(status: "active")
    #     end
    #
    #     def member_names
    #       members.map(&:display_name)
    #     end
    #   end
    #
    module MetadataDSL
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # Mark this class as visible to agents.
        # Only classes marked with agent_visible will be included in schema listings.
        # If no classes are marked, all classes are shown (backwards compatible).
        #
        # @example Mark a class as agent-visible
        #   class Song < Parse::Object
        #     agent_visible
        #     agent_description "A music track"
        #   end
        #
        # @return [Boolean] true
        def agent_visible
          @agent_visible = true
          Parse::Agent::MetadataRegistry.register_visible_class(self)
          true
        end

        # Check if this class is marked as visible to agents
        # @return [Boolean]
        def agent_visible?
          @agent_visible == true
        end

        # Set or get the class-level description for agent context.
        # This description helps LLMs understand what this class represents.
        #
        # @example Set a description
        #   agent_description "A music track in the catalog"
        #
        # @example Get the description
        #   Song.agent_description # => "A music track in the catalog"
        #
        # @param text [String, nil] the description to set, or nil to get
        # @return [String, nil] the current description
        def agent_description(text = nil)
          if text
            @agent_description = text.to_s.freeze
          else
            @agent_description
          end
        end

        # Property descriptions are stored in Parse::Properties module.
        # This method is provided there via the `property` DSL with `_description:` option.
        # @see Parse::Properties::ClassMethods#property_descriptions

        # Storage hash for agent-allowed methods.
        # Maps method names (symbols) to their metadata hashes.
        #
        # @return [Hash<Symbol, Hash>]
        def agent_methods
          @agent_methods ||= {}
        end

        # Permission levels for agent methods (matches Parse::Agent permission levels)
        AGENT_METHOD_PERMISSIONS = %i[readonly write admin].freeze

        # Patterns that suggest a method performs write operations
        # Used to warn developers who may have misclassified a method as readonly
        WRITE_METHOD_PATTERNS = [
          /save/i, /update/i, /delete/i, /destroy/i, /create/i, /remove/i,
          /insert/i, /upsert/i, /modify/i, /set/i, /clear/i, /reset/i,
          /add/i, /append/i, /push/i, /increment/i, /decrement/i,
        ].freeze

        # Mark a method as callable by the agent with an optional description.
        # Only methods marked with this DSL can be invoked via the `call_method` tool.
        #
        # @example Mark a readonly class method (default)
        #   agent_method :find_popular, "Find songs with over 1000 plays"
        #
        # @example Mark an instance method requiring write permission
        #   agent_method :update_play_count, "Increment play count", permission: :write
        #
        # @example Mark a method requiring admin permission
        #   agent_method :reset_all_counts, "Reset all play counts to zero", permission: :admin
        #
        # @param method_name [Symbol, String] the name of the method to expose
        # @param description [String, nil] optional description for LLM context
        # @param permission [Symbol] required permission level (:readonly, :write, :admin)
        # @return [Hash] the method metadata
        def agent_method(method_name, description = nil, permission: :readonly)
          method_sym = method_name.to_sym

          unless AGENT_METHOD_PERMISSIONS.include?(permission)
            raise ArgumentError, "Invalid permission level: #{permission}. Must be one of: #{AGENT_METHOD_PERMISSIONS.join(", ")}"
          end

          # Determine if this is an instance or class method
          # Note: method_defined? checks instance methods, respond_to? checks class methods
          method_type = if method_defined?(method_sym)
              :instance
            elsif respond_to?(method_sym) || singleton_methods.include?(method_sym)
              :class
            else
              # Method not yet defined - we'll check again at runtime
              :unknown
            end

          agent_methods[method_sym] = {
            description: description&.to_s&.freeze,
            type: method_type,
            permission: permission,
          }
        end

        # Convenience method: mark a method as readonly-accessible (default)
        #
        # WARNING: This method checks if the method name suggests write behavior
        # (save, update, delete, etc.) and emits a warning. This helps developers
        # catch potential security misconfigurations early.
        #
        # @example
        #   agent_readonly :find_popular, "Find songs with over 1000 plays"
        #
        # @param method_name [Symbol, String] the method to expose
        # @param description [String, nil] optional description
        # @return [Hash] the method metadata
        def agent_readonly(method_name, description = nil)
          method_str = method_name.to_s

          # Warn if method name suggests it performs write operations
          if WRITE_METHOD_PATTERNS.any? { |pattern| method_str.match?(pattern) }
            warn "[Parse::Agent::MetadataDSL] WARNING: Method '#{method_name}' on #{name} " \
                 "is marked as agent_readonly but its name suggests it may perform writes. " \
                 "Consider using agent_write or agent_admin if this method modifies data."
          end

          agent_method(method_name, description, permission: :readonly)
        end

        # Convenience method: mark a method as requiring write permission
        #
        # @example
        #   agent_write :update_play_count, "Increment the play count"
        #
        # @param method_name [Symbol, String] the method to expose
        # @param description [String, nil] optional description
        # @return [Hash] the method metadata
        def agent_write(method_name, description = nil)
          agent_method(method_name, description, permission: :write)
        end

        # Convenience method: mark a method as requiring admin permission
        #
        # @example
        #   agent_admin :reset_all_counts, "Reset all play counts to zero"
        #
        # @param method_name [Symbol, String] the method to expose
        # @param description [String, nil] optional description
        # @return [Hash] the method metadata
        def agent_admin(method_name, description = nil)
          agent_method(method_name, description, permission: :admin)
        end

        # Check if this model has any agent metadata defined.
        #
        # @return [Boolean] true if any metadata is present
        def has_agent_metadata?
          !agent_description.nil? ||
            !property_descriptions.empty? ||
            !agent_methods.empty?
        end

        # Get all agent metadata as a hash for serialization.
        #
        # @return [Hash] all agent metadata
        def agent_metadata
          {
            description: agent_description,
            property_descriptions: property_descriptions.dup,
            methods: agent_methods.dup,
          }
        end

        # Check if a specific method is allowed for agent invocation.
        #
        # @param method_name [Symbol, String] the method name to check
        # @return [Boolean] true if the method is agent-allowed
        def agent_method_allowed?(method_name)
          agent_methods.key?(method_name.to_sym)
        end

        # Get metadata for a specific agent-allowed method.
        #
        # @param method_name [Symbol, String] the method name
        # @return [Hash, nil] the method metadata or nil if not allowed
        def agent_method_info(method_name)
          agent_methods[method_name.to_sym]
        end

        # Check if an agent with given permission can call a specific method.
        # Permission hierarchy: admin > write > readonly
        #
        # @param method_name [Symbol, String] the method to check
        # @param agent_permission [Symbol] the agent's permission level
        # @return [Boolean] true if the agent can call this method
        def agent_can_call?(method_name, agent_permission)
          method_info = agent_methods[method_name.to_sym]
          return false unless method_info

          required_permission = method_info[:permission] || :readonly
          permission_allows?(agent_permission, required_permission)
        end

        # Get all methods available to an agent with given permission level.
        #
        # @param agent_permission [Symbol] the agent's permission level
        # @return [Hash<Symbol, Hash>] methods the agent can call
        def agent_methods_for(agent_permission)
          agent_methods.select do |_name, info|
            permission_allows?(agent_permission, info[:permission] || :readonly)
          end
        end

        private

        # Check if agent_permission level can access required_permission level.
        # Permission hierarchy: admin > write > readonly
        #
        # @param agent_permission [Symbol] what the agent has
        # @param required_permission [Symbol] what the method requires
        # @return [Boolean]
        def permission_allows?(agent_permission, required_permission)
          hierarchy = { readonly: 0, write: 1, admin: 2 }
          agent_level = hierarchy[agent_permission] || 0
          required_level = hierarchy[required_permission] || 0
          agent_level >= required_level
        end
      end

      # Instance method to access class-level agent description
      #
      # @return [String, nil]
      def agent_description
        self.class.agent_description
      end

      # Instance method to access class-level property descriptions
      #
      # @return [Hash<Symbol, String>]
      def property_descriptions
        self.class.property_descriptions
      end

      # Instance method to access class-level agent methods
      #
      # @return [Hash<Symbol, Hash>]
      def agent_methods
        self.class.agent_methods
      end
    end
  end
end
