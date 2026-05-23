# encoding: UTF-8
# frozen_string_literal: true

require_relative "stack/version"
require_relative "client"
require_relative "query"
require_relative "model/object"
require_relative "webhooks"

module Parse
  class Error < StandardError; end

  module Stack
  end

  # Configuration for query validation warnings
  # Set to false to disable warnings about unnecessary includes
  # @example Disable query warnings
  #   Parse.warn_on_query_issues = false
  @warn_on_query_issues = true

  # Configuration for debugging autofetch behavior.
  # When set to true, autofetch will raise Parse::AutofetchTriggeredError instead of
  # automatically fetching data. This helps identify where additional keys are needed
  # in queries to avoid unnecessary network requests.
  # @example Enable autofetch debugging
  #   Parse.autofetch_raise_on_missing_keys = true
  #   # Now accessing an unfetched field will raise an error:
  #   # Parse::AutofetchTriggeredError: Autofetch triggered on Post#abc123 - field :content was not fetched
  @autofetch_raise_on_missing_keys = false

  # Configuration for serialization of partially fetched objects.
  # When set to true (default), calling as_json or to_json on a partially fetched
  # object will only serialize the fields that were fetched, preventing autofetch
  # from being triggered during serialization. This is particularly useful for
  # webhook responses where you intentionally want to return partial data.
  # @example Disable (serialize all fields, triggering autofetch)
  #   Parse.serialize_only_fetched_fields = false
  # @example Override per-call
  #   user.as_json(only_fetched: false)  # Force full serialization
  @serialize_only_fetched_fields = true

  class << self
    attr_accessor :warn_on_query_issues, :autofetch_raise_on_missing_keys, :serialize_only_fetched_fields
  end

  # Error raised when autofetch would be triggered but Parse.autofetch_raise_on_missing_keys is true.
  # This helps developers identify where they need to add additional keys to their queries.
  class AutofetchTriggeredError < StandardError
    attr_reader :klass, :object_id, :field, :is_pointer

    def initialize(klass, object_id, field, is_pointer:)
      @klass = klass
      @object_id = object_id
      @field = field
      @is_pointer = is_pointer

      if is_pointer
        super("Autofetch triggered on #{klass}##{object_id} - pointer accessed field :#{field}. Add this field to your includes or fetch the object first.")
      else
        super("Autofetch triggered on #{klass}##{object_id} - field :#{field} was not included in partial fetch. Add :#{field} to your query keys.")
      end
    end
  end

  # Special class to support Modernistik Hyperdrive server.
  class Hyperdrive
    # Applies a remote JSON hash containing the ENV keys and values from a remote
    # URL. Values from the JSON hash are only applied to the current ENV hash ONLY if
    # it does not already have a value. Therefore local ENV values will take precedence
    # over remote ones. By default, it uses the url in environment value in 'CONFIG_URL' or 'HYPERDRIVE_URL'.
    # @param url [String] the remote url that responds with the JSON body.
    # @return [Boolean] true if the JSON hash was found and applied successfully.
    def self.config!(url = nil)
      url ||= ENV["HYPERDRIVE_URL"] || ENV["CONFIG_URL"]
      if url.present?
        begin
          remote_config = JSON.load open(url)
          remote_config.each do |key, value|
            k = key.upcase
            next unless ENV[k].nil?
            ENV[k] ||= value.to_s
          end
          return true
        rescue => e
          warn "[Parse::Stack] Error loading config: #{url} (#{e})"
        end
      end
      false
    end
  end
end

require_relative "stack/railtie" if defined?(::Rails)
