# encoding: UTF-8
# frozen_string_literal: true

require "faraday"
require_relative "response"
require_relative "protocol"
require "active_support"
require "active_support/core_ext"
require "active_model/serializers/json"

module Parse

  # @!attribute self.logging
  # Sets {Parse::Middleware::BodyBuilder} logging.
  # You may specify `:debug` for additional verbosity.
  # @return (see Parse::Middleware::BodyBuilder.logging)
  def self.logging
    Parse::Middleware::BodyBuilder.logging
  end
  # @!visibility private
  def self.logging=(value)
    Parse::Middleware::BodyBuilder.logging = value
  end

  # Namespace for Parse-Stack related middleware.
  module Middleware
    # This middleware takes an incoming Parse response, after an outgoing request,
    # and creates a Parse::Response object.
    class BodyBuilder < Faraday::Middleware
      include Parse::Protocol
      # Header sent when a GET requests exceeds the limit.
      HTTP_METHOD_OVERRIDE = "X-Http-Method-Override"
      # Maximum url length for most server requests before HTTP Method Override is used.
      MAX_URL_LENGTH = 2_000.freeze
      # Fields that should be redacted from log output.
      SENSITIVE_FIELDS = %w[password token sessionToken session_token access_token authData].freeze
      SENSITIVE_PATTERN = /(#{SENSITIVE_FIELDS.join("|")})(["']?\s*[=:>]\s*["']?)([^"&\s,}\]]+)/i
      # Request headers that must never be printed verbatim in debug logs.
      # Matched case-insensitively against Faraday header keys.
      REDACTED_HEADERS = [
        Parse::Protocol::MASTER_KEY,
        Parse::Protocol::API_KEY,
        Parse::Protocol::SESSION_TOKEN,
        "X-Parse-JavaScript-Key",
        "Authorization",
        "Cookie",
      ].map(&:downcase).freeze

      class << self
        # Allows logging. Set to `true` to enable logging, `false` to disable.
        # You may specify `:debug` for additional verbosity.
        # @return [Boolean]
        attr_accessor :logging
      end

      # Redacts sensitive fields from a string for safe logging.
      # @param str [String] the string to redact.
      # @return [String] the redacted string.
      def self.redact(str)
        str.to_s.gsub(SENSITIVE_PATTERN) { "#{$1}#{$2}[FILTERED]" }
      end

      # Thread-safety
      # @!visibility private
      def call(env)
        dup.call!(env)
      end

      # @!visibility private
      def call!(env)
        # the maximum url size is ~2KB, so if we request a Parse API url greater than this
        # (which is most likely a very complicated query), we need to override the request method
        # to be POST instead of GET and send the query parameters in the body of the POST request.
        # The standard maximum POST request (which is a server setting), is usually set to 20MBs
        if env[:method] == :get && env[:url].to_s.length >= MAX_URL_LENGTH
          env[:request_headers][HTTP_METHOD_OVERRIDE] = "GET"
          env[:request_headers][CONTENT_TYPE] = "application/x-www-form-urlencoded"
          # parse-sever looks for method overrides in the body under the `_method` param.
          # so we will add it to the query string, which will now go into the body.
          env[:body] = "_method=GET&" + env[:url].query
          env[:url].query = nil
          #override
          env[:method] = :post
          # else if not a get, always make sure the request is JSON encoded if the content type matches
        elsif env[:request_headers][CONTENT_TYPE] == CONTENT_TYPE_FORMAT &&
              (env[:body].is_a?(Hash) || env[:body].is_a?(Array))
          env[:body] = env[:body].to_json
        end

        if self.class.logging
          puts "[Request #{env.method.upcase}] #{self.class.redact(env[:url].to_s)}"
          env[:request_headers].each do |k, v|
            if REDACTED_HEADERS.include?(k.to_s.downcase)
              puts "[Header] #{k} : [FILTERED]"
            else
              puts "[Header] #{k} : #{v}"
            end
          end

          puts "[Request Body] #{self.class.redact(env[:body].to_s)}"
        end
        @app.call(env).on_complete do |response_env|
          # on a response, create a new Parse::Response and replace the :body
          # of the env
          # @todo CHECK FOR HTTP STATUS CODES
          if self.class.logging
            puts "[[Response #{response_env[:status]}]] ----------------------------------"
            puts self.class.redact(response_env.body.to_s)
            puts "[[Response]] --------------------------------------\n"
          end

          begin
            r = Parse::Response.new(response_env.body)
          rescue => e
            r = Parse::Response.new
            r.code = response_env.status
            r.error = "Invalid response for #{env[:method]} #{env[:url]}: #{e}"
          end
          r.http_status = response_env[:status]
          r.headers = response_env[:response_headers]
          r.code ||= response_env[:status] if r.error.present?
          response_env[:body] = r
        end
      end
    end
  end #Middleware
end
