# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module API
    # Defines the Parse webhooks interface for the Parse REST API
    module Hooks
      # @!visibility private
      HOOKS_PREFIX = "hooks/"
      # The allowed set of Parse webhook triggers. Mirrors Parse Server's
      # `triggers.Types` so registration of the auth / LiveQuery / password-
      # reset hooks is no longer pre-rejected by the SDK.
      #
      # NOTE: this allowlist gates *registration* only. The webhook router in
      # {Parse::Webhooks} currently shapes payloads for the object triggers
      # (before/after save/delete/find); the login / connect / subscribe /
      # password-reset payloads carry a different shape (no `object`) and
      # their first-class routing is a follow-up. `beforeConnect` is a
      # connection-global trigger whose Parse-canonical className is the
      # `@Connect` sentinel; file triggers use `@File`. Both are accepted by
      # the trigger-className validator ({Parse::API::PathSegment.trigger_class_name!}).
      TRIGGER_NAMES = [
        :afterDelete, :afterFind, :afterSave,
        :beforeDelete, :beforeFind, :beforeSave,
        :beforeLogin, :afterLogin, :afterLogout, :beforePasswordResetRequest,
        :beforeConnect, :beforeSubscribe, :afterEvent,
      ].freeze
      # @!visibility private
      TRIGGER_NAMES_LOCAL = [
        :after_delete, :after_find, :after_save,
        :before_delete, :before_find, :before_save,
        :before_login, :after_login, :after_logout, :before_password_reset_request,
        :before_connect, :before_subscribe, :after_event,
      ].freeze

      # `beforeCreate` / `afterCreate` are NOT Parse Server trigger types —
      # Parse Server rejects them ("invalid hook declaration"). They exist only
      # as Parse-Stack ActiveModel callbacks (`before_create` / `after_create`),
      # which the webhook router runs INSIDE the `beforeSave` / `afterSave`
      # handler for new objects (gated on `original.nil?`). So there is nothing
      # to register for them — register `beforeSave` / `afterSave` instead and
      # the create callbacks fire within it.
      # @!visibility private
      def _verify_trigger(triggerName)
        camel = triggerName.to_s.camelize(:lower).to_sym
        if %i[beforeCreate afterCreate].include?(camel)
          save     = camel == :beforeCreate ? "beforeSave" : "afterSave"
          callback = camel == :beforeCreate ? "before_create" : "after_create"
          raise ArgumentError,
                "Parse Server has no #{camel} webhook trigger. Register a " \
                "#{save} webhook instead — Parse Stack runs your #{callback} " \
                "ActiveModel callbacks within the #{save} handler for new objects."
        end
        raise ArgumentError, "Invalid trigger name #{camel}" unless TRIGGER_NAMES.include?(camel)
        camel
      end

      # Fetch all defined cloud code functions.
      # @return [Parse::Response]
      def functions
        opts = { cache: false }
        request :get, "#{HOOKS_PREFIX}functions", opts: opts
      end

      # Fetch information about a specific registered cloud function.
      # @param functionName [String] the name of the cloud code function.
      # @return [Parse::Response]
      def fetch_function(functionName)
        safe = Parse::API::PathSegment.identifier!(functionName, kind: "function name")
        request :get, "#{HOOKS_PREFIX}functions/#{safe}"
      end

      # Register a cloud code webhook function pointing to a endpoint url.
      # @param functionName [String] the name of the cloud code function.
      # @param url [String] the url endpoint for this cloud code function.
      # @return [Parse::Response]
      def create_function(functionName, url)
        request :post, "#{HOOKS_PREFIX}functions", body: { functionName: functionName, url: url }
      end

      # Updated the endpoint url for a registered cloud code webhook function.
      # @param functionName [String] the name of the cloud code function.
      # @param url [String] the new url endpoint for this cloud code function.
      # @return [Parse::Response]
      def update_function(functionName, url)
        # If you add _method => "PUT" to the JSON body,
        # and send it as a POST request and parse will accept it as a PUT.
        safe = Parse::API::PathSegment.identifier!(functionName, kind: "function name")
        request :put, "#{HOOKS_PREFIX}functions/#{safe}", body: { url: url }
      end

      # Remove a registered cloud code webhook function.
      # @param functionName [String] the name of the cloud code function.
      # @return [Parse::Response]
      def delete_function(functionName)
        safe = Parse::API::PathSegment.identifier!(functionName, kind: "function name")
        request :put, "#{HOOKS_PREFIX}functions/#{safe}", body: { __op: "Delete" }
      end

      # Get the set of registered triggers.
      # @return [Parse::Response]
      def triggers
        opts = { cache: false }
        request :get, "#{HOOKS_PREFIX}triggers", opts: opts
      end

      # Fetch information about a registered webhook trigger.
      # @param triggerName [String] the name of the trigger. (ex. beforeSave, afterSave)
      # @param className [String] the name of the Parse collection for the trigger.
      # @return [Parse::Response]
      # @see TRIGGER_NAMES
      def fetch_trigger(triggerName, className)
        triggerName = _verify_trigger(triggerName)
        safe_class = Parse::API::PathSegment.trigger_class_name!(className, kind: "class name")
        request :get, "#{HOOKS_PREFIX}triggers/#{safe_class}/#{triggerName}"
      end

      # Register a new cloud code webhook trigger with an endpoint url.
      # @param triggerName [String] the name of the trigger. (ex. beforeSave, afterSave)
      # @param className [String] the name of the Parse collection for the trigger.
      # @param url [String] the url endpoint for this webhook trigger.
      # @return [Parse::Response]
      # @see Parse::API::Hooks::TRIGGER_NAMES
      def create_trigger(triggerName, className, url)
        triggerName = _verify_trigger(triggerName)
        body = { className: className, triggerName: triggerName, url: url }
        request :post, "#{HOOKS_PREFIX}triggers", body: body
      end

      # Updated the registered endpoint for this cloud code webhook trigger.
      # @param triggerName [String] the name of the trigger. (ex. beforeSave, afterSave)
      # @param className [String] the name of the Parse collection for the trigger.
      # @param url [String] the new url endpoint for this webhook trigger.
      # @return [Parse::Response]
      # @see Parse::API::Hooks::TRIGGER_NAMES
      def update_trigger(triggerName, className, url)
        triggerName = _verify_trigger(triggerName)
        safe_class = Parse::API::PathSegment.trigger_class_name!(className, kind: "class name")
        request :put, "#{HOOKS_PREFIX}triggers/#{safe_class}/#{triggerName}", body: { url: url }
      end

      # Remove a registered cloud code webhook trigger.
      # @param triggerName [String] the name of the trigger. (ex. beforeSave, afterSave)
      # @param className [String] the name of the Parse collection for the trigger.
      # @return [Parse::Response]
      # @see Parse::API::Hooks::TRIGGER_NAMES
      def delete_trigger(triggerName, className)
        triggerName = _verify_trigger(triggerName)
        safe_class = Parse::API::PathSegment.trigger_class_name!(className, kind: "class name")
        request :put, "#{HOOKS_PREFIX}triggers/#{safe_class}/#{triggerName}", body: { __op: "Delete" }
      end
    end
  end
end
