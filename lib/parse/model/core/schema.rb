# encoding: UTF-8
# frozen_string_literal: true

require_relative "properties"

module Parse
  module Core
    # Defines the Schema methods applied to a Parse::Object.
    module Schema

      # Generate a Parse-server compatible schema hash for performing changes to the
      # structure of the remote collection.
      # @return [Hash] the schema for this Parse::Object subclass.
      def schema
        sch = { className: parse_class, fields: {} }
        #first go through all the attributes
        attributes.each do |k, v|
          # don't include the base Parse fields
          next if Parse::Properties::BASE.include?(k)
          next if v.nil?
          result = { type: v.to_s.camelize }
          # if it is a basic column property, find the right datatype
          case v
          when :integer, :float
            result[:type] = Parse::Model::TYPE_NUMBER
          when :geopoint, :geo_point
            result[:type] = Parse::Model::TYPE_GEOPOINT
          when :pointer
            result = { type: Parse::Model::TYPE_POINTER, targetClass: references[k] }
          when :acl
            result[:type] = Parse::Model::ACL
          when :timezone, :time_zone
            result[:type] = "String" # no TimeZone native in Parse
          else
            result[:type] = v.to_s.camelize
          end

          sch[:fields][k] = result
        end
        #then add all the relational column attributes
        relations.each do |k, v|
          sch[:fields][k] = { type: Parse::Model::TYPE_RELATION, targetClass: relations[k] }
        end
        sch
      end

      # Update the remote schema for this Parse collection.
      # @param schema_updates [Hash] the changes to be made to the schema.
      # @return [Parse::Response]
      def update_schema(schema_updates = nil)
        schema_updates ||= schema
        client.update_schema parse_class, schema_updates
      end

      # Create a new collection for this model with the schema defined by the local
      # model.
      # @return [Parse::Response]
      # @see Schema.schema
      def create_schema
        client.create_schema parse_class, schema
      end

      # Fetche the current schema for this collection from Parse server.
      # @return [Parse::Response]
      def fetch_schema
        client.schema parse_class
      end

      # System classes that cannot be created or modified via the schema API.
      # These are managed automatically by Parse Server.
      SCHEMA_READONLY_CLASSES = [
        Parse::Model::CLASS_PUSH_STATUS,
        Parse::Model::CLASS_SCHEMA
      ].freeze

      # Default CLP that grants public access to all operations.
      # Used to reset CLPs before applying new ones.
      DEFAULT_PUBLIC_CLP = {
        "find" => { "*" => true },
        "get" => { "*" => true },
        "count" => { "*" => true },
        "create" => { "*" => true },
        "update" => { "*" => true },
        "delete" => { "*" => true },
        "addField" => { "*" => true }
      }.freeze

      # Reset the CLP on the server to public defaults.
      # This clears any existing restrictive permissions.
      #
      # @param client [Parse::Client] optional client to use
      # @return [Parse::Response] the response from the server
      #
      # @example Reset CLPs to public
      #   Song.reset_clp!
      def reset_clp!(client: nil)
        client ||= self.client

        unless client.master_key.present?
          warn "[Parse] CLP reset for #{parse_class} requires the master key!"
          return nil
        end

        client.update_schema(parse_class, { "classLevelPermissions" => DEFAULT_PUBLIC_CLP })
      end

      # A class method for non-destructive auto upgrading a remote schema based
      # on the properties and relations you have defined in your local model. If
      # the collection doesn't exist, we create the schema. If the collection already
      # exists, the current schema is fetched, and only add the additional fields
      # that are missing.
      #
      # Also updates Class-Level Permissions (CLPs) if defined on the model using
      # the `set_clp` and `protect_fields` DSL methods.
      #
      # @note This feature requires use of the master_key. No columns or fields are removed, this is a safe non-destructive upgrade.
      # @param include_clp [Boolean] whether to also update CLPs (default: true)
      # @return [Parse::Response] if the remote schema was modified.
      # @return [Boolean] if no changes were made to the schema, it returns true.
      def auto_upgrade!(include_clp: true)
        # Skip read-only system classes that Parse Server manages automatically
        if SCHEMA_READONLY_CLASSES.include?(parse_class)
          warn "[Parse] Skipping #{parse_class} - managed automatically by Parse Server"
          return true
        end

        unless client.master_key.present?
          warn "[Parse] Schema changes for #{parse_class} is only available with the master key!"
          return false
        end
        # fetch the current schema (requires master key)
        response = fetch_schema

        # if it's a core class that doesn't exist, then create the collection without any fields,
        # since parse-server will automatically create the collection with the set of core fields.
        # then fetch the schema again, to add the missing fields.
        if response.error? && self.to_s.start_with?("Parse::") #is it a core class?
          client.create_schema parse_class, {}
          response = fetch_schema
          # if it still wasn't able to be created, raise an error.
          if response.error?
            warn "[Parse] Schema error: unable to create class #{parse_class}"
            return response
          end
        end

        if response.success?
          #let's figure out the diff fields
          remote_fields = response.result["fields"]
          current_schema = schema
          current_schema[:fields] = current_schema[:fields].reduce({}) do |h, (k, v)|
            #if the field does not exist in Parse, then add it to the update list
            h[k] = v if remote_fields[k.to_s].nil?
            h
          end

          # Handle CLP updates if configured and requested
          if include_clp && respond_to?(:class_permissions) && class_permissions.present?
            # First, reset CLPs to public defaults to clear any old restrictive permissions.
            # Parse Server merges CLPs rather than replacing them, so old keys can persist
            # and cause "Permission denied" errors if not explicitly cleared.
            reset_clp!

            # Now apply the new CLP configuration
            current_schema[:classLevelPermissions] = class_permissions.as_json(include_defaults: true)
          end

          return true if current_schema[:fields].empty? && !current_schema[:classLevelPermissions]
          return update_schema(current_schema)
        end

        # Create new schema (class doesn't exist)
        initial_schema = schema
        # Include CLPs in initial schema creation if configured
        if include_clp && respond_to?(:class_permissions) && class_permissions.present?
          initial_schema[:classLevelPermissions] = class_permissions.as_json(include_defaults: true)
        end
        client.create_schema parse_class, initial_schema
      end
    end
  end
end
