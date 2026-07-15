# encoding: UTF-8
# frozen_string_literal: true

require "faraday"
require "logger"
require_relative "url_redaction"

module Parse
  module Middleware
    # Faraday middleware that logs Parse API requests and responses.
    #
    # This middleware provides detailed logging of HTTP requests and responses
    # with configurable log levels and optional body truncation for large payloads.
    #
    # @example Basic setup
    #   Parse.logging = true
    #
    # @example Detailed configuration
    #   Parse.configure do |config|
    #     config.logging = true
    #     config.log_level = :debug
    #     config.logger = Rails.logger  # or Logger.new(STDOUT)
    #   end
    #
    # Log levels:
    # - :info  - Logs request method, URL, status, and timing
    # - :debug - Also logs headers and truncated body content
    # - :warn  - Only logs errors and warnings
    #
    class Logging < Faraday::Middleware
      # Maximum length of body content to log before truncation
      MAX_BODY_LENGTH = 500

      class << self
        # @return [Boolean] Whether logging is enabled
        attr_accessor :enabled

        # @return [Symbol] The log level (:info, :debug, :warn)
        attr_accessor :log_level

        # @return [Logger] The logger instance to use
        attr_accessor :logger

        # @return [Integer] Maximum body length to log (defaults to MAX_BODY_LENGTH)
        attr_accessor :max_body_length

        # Default logger instance
        # @return [Logger]
        def default_logger
          @default_logger ||= begin
              l = Logger.new(STDOUT)
              l.progname = "Parse"
              l.formatter = proc do |severity, datetime, progname, msg|
                "[#{progname}] #{msg}\n"
              end
              l
            end
        end

        # Get the configured logger or default
        # @return [Logger]
        def current_logger
          logger || default_logger
        end

        # Get the current log level (defaults to :info)
        # @return [Symbol]
        def current_log_level
          log_level || :info
        end

        # Get the max body length (defaults to MAX_BODY_LENGTH)
        # @return [Integer]
        def current_max_body_length
          max_body_length || MAX_BODY_LENGTH
        end
      end

      # Thread-safety: duplicate the middleware for each request
      # @!visibility private
      def call(env)
        dup.call!(env)
      end

      # @!visibility private
      def call!(env)
        return @app.call(env) unless self.class.enabled

        start_time = Time.now
        log_request(env)

        @app.call(env).on_complete do |response_env|
          elapsed_ms = ((Time.now - start_time) * 1000).round(2)
          log_response(response_env, elapsed_ms)
        end
      end

      private

      def log_request(env)
        logger = self.class.current_logger
        level = self.class.current_log_level

        method = env[:method].to_s.upcase
        url = sanitize_url(env[:url].to_s)

        case level
        when :debug
          logger.debug "▶ #{method} #{url}"
          log_headers(env[:request_headers], "Request")
          log_body(env[:body], "Request")
        when :info
          logger.info "▶ #{method} #{url}"
        end
      end

      def log_response(response_env, elapsed_ms)
        logger = self.class.current_logger
        level = self.class.current_log_level
        status = response_env[:status]

        # Determine if this is an error response
        is_error = status >= 400

        case level
        when :debug
          log_debug_response(logger, response_env, elapsed_ms, is_error)
        when :info
          log_info_response(logger, response_env, elapsed_ms, is_error)
        when :warn
          log_warn_response(logger, response_env, elapsed_ms) if is_error
        end
      end

      def log_debug_response(logger, response_env, elapsed_ms, is_error)
        status = response_env[:status]
        status_indicator = is_error ? "✗" : "◀"

        logger.debug "#{status_indicator} #{status} (#{elapsed_ms}ms)"
        log_body(response_body_content(response_env), "Response")
      end

      def log_info_response(logger, response_env, elapsed_ms, is_error)
        status = response_env[:status]
        status_indicator = is_error ? "✗" : "◀"

        if is_error
          logger.info "#{status_indicator} #{status} (#{elapsed_ms}ms) - #{error_summary(response_env)}"
        else
          logger.info "#{status_indicator} #{status} (#{elapsed_ms}ms)"
        end
      end

      def log_warn_response(logger, response_env, elapsed_ms)
        status = response_env[:status]
        logger.warn "✗ #{status} (#{elapsed_ms}ms) - #{error_summary(response_env)}"
      end

      def log_headers(headers, prefix)
        return unless headers
        logger = self.class.current_logger
        headers.each do |key, value|
          # Don't log sensitive headers. Reuses the canonical denylist on
          # Parse::Middleware::BodyBuilder so Authorization, Cookie, and
          # X-Parse-JavaScript-Key are also redacted (the prior regex only
          # caught master-key / api-key / session-token shaped names).
          if Parse::Middleware::BodyBuilder::REDACTED_HEADERS.include?(key.to_s.downcase)
            logger.debug "  [#{prefix} Header] #{key}: [FILTERED]"
          else
            logger.debug "  [#{prefix} Header] #{key}: #{value}"
          end
        end
      end

      def log_body(body, prefix)
        return unless body
        logger = self.class.current_logger
        max_length = self.class.current_max_body_length

        content = if body.is_a?(String)
            body
          else
            begin
              body.to_json
            rescue JSON::GeneratorError, Encoding::UndefinedConversionError
              body.to_s
            end
          end

        # Scrub credentials before logging. At :debug level this method emits
        # both the request body (login/signup carries a cleartext `password`)
        # and the response body (auth responses carry a fresh `sessionToken`,
        # `authData`, and MFA secrets). `log_headers` already redacts headers;
        # the body path must use the same canonical scrubber or it leaks live
        # credentials to anyone with log access. Redact BEFORE the length cap
        # so truncation can't split a token across the boundary and slip past.
        content = Parse::Middleware::BodyBuilder.redact(content)

        if content.length > max_length
          logger.debug "  [#{prefix} Body] #{content[0...max_length]}... (truncated, #{content.length} total)"
        elsif content.length > 0
          logger.debug "  [#{prefix} Body] #{content}"
        end
      end

      def response_body_content(response_env)
        body = response_env[:body]
        if body.is_a?(Parse::Response)
          begin
            body.result.to_json
          rescue JSON::GeneratorError, Encoding::UndefinedConversionError
            body.to_s
          end
        else
          body
        end
      end

      def error_summary(response_env)
        body = response_env[:body]
        if body.is_a?(Parse::Response) && body.error?
          "#{body.code}: #{body.error}"
        elsif body.is_a?(Hash)
          body["error"] || body[:error] || "Unknown error"
        else
          "HTTP #{response_env[:status]}"
        end
      end

      def sanitize_url(url)
        # Redact credential-bearing query params from logged URLs. Shared
        # with the profiling middleware via Parse::Middleware::URLRedaction
        # so the two sanitizers can't drift.
        Parse::Middleware::URLRedaction.sanitize(url)
      end
    end
  end

  # Module-level configuration methods for logging
  class << self
    # Enable or disable request/response logging
    # @example Enable logging
    #   Parse.logging_enabled = true
    # @param value [Boolean]
    def logging_enabled=(value)
      Middleware::Logging.enabled = value
    end

    # @return [Boolean] whether logging is enabled
    def logging_enabled
      Middleware::Logging.enabled
    end

    # Set the log level for Parse requests
    # @example Set debug level
    #   Parse.log_level = :debug
    # @param value [Symbol] one of :info, :debug, :warn
    def log_level=(value)
      unless [:info, :debug, :warn].include?(value)
        raise ArgumentError, "Invalid log level: #{value}. Use :info, :debug, or :warn"
      end
      Middleware::Logging.log_level = value
    end

    # @return [Symbol] the current log level
    def log_level
      Middleware::Logging.current_log_level
    end

    # Set a custom logger for Parse requests
    # @example Use Rails logger
    #   Parse.logger = Rails.logger
    # @param value [Logger]
    def logger=(value)
      Middleware::Logging.logger = value
    end

    # @return [Logger] the current logger
    def logger
      Middleware::Logging.current_logger
    end

    # Set the maximum body length to log before truncation
    # @param value [Integer]
    def log_max_body_length=(value)
      Middleware::Logging.max_body_length = value.to_i
    end

    # @return [Integer] the maximum body length
    def log_max_body_length
      Middleware::Logging.current_max_body_length
    end

    # Configure Parse logging with a block
    # @example
    #   Parse.configure_logging do |config|
    #     config.enabled = true
    #     config.log_level = :debug
    #     config.logger = Rails.logger
    #   end
    def configure_logging
      yield Middleware::Logging if block_given?
    end
  end
end
