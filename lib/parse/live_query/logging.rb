# encoding: UTF-8
# frozen_string_literal: true

require "logger"

module Parse
  module LiveQuery
    # Structured logging module for LiveQuery.
    #
    # Provides leveled logging with context support. Disabled by default.
    #
    # @example Enable logging
    #   Parse::LiveQuery::Logging.enabled = true
    #   Parse::LiveQuery::Logging.log_level = :debug
    #
    # @example Use custom logger
    #   Parse::LiveQuery::Logging.logger = Rails.logger
    #
    module Logging
      # Log levels in order of verbosity
      LEVELS = [:debug, :info, :warn, :error].freeze

      class << self
        # @return [Boolean] whether logging is enabled
        attr_accessor :enabled

        # @return [Logger, nil] custom logger instance
        attr_accessor :logger

        # @return [Symbol] current log level (:debug, :info, :warn, :error)
        attr_reader :log_level

        # Set log level with validation
        # @param level [Symbol] one of :debug, :info, :warn, :error
        def log_level=(level)
          unless LEVELS.include?(level)
            raise ArgumentError, "Invalid log level: #{level}. Must be one of #{LEVELS.inspect}"
          end
          @log_level = level
        end

        # Get or create the default logger
        # @return [Logger]
        def default_logger
          @default_logger ||= begin
              l = ::Logger.new($stdout)
              l.progname = "Parse::LiveQuery"
              l.formatter = proc do |severity, datetime, progname, msg|
                "[#{datetime.strftime("%Y-%m-%d %H:%M:%S")}] #{severity} -- #{progname}: #{msg}\n"
              end
              l
            end
        end

        # Get the current logger (custom or default)
        # @return [Logger]
        def current_logger
          logger || default_logger
        end

        # Log a debug message
        # @param message [String] the message
        # @param context [Hash] optional context data
        def debug(message, **context)
          log(:debug, message, context)
        end

        # Log an info message
        # @param message [String] the message
        # @param context [Hash] optional context data
        def info(message, **context)
          log(:info, message, context)
        end

        # Log a warning message
        # @param message [String] the message
        # @param context [Hash] optional context data
        def warn(message, **context)
          log(:warn, message, context)
        end

        # Log an error message
        # @param message [String] the message
        # @param context [Hash] optional context data
        def error(message, **context)
          log(:error, message, context)
        end

        # Reset logging configuration to defaults
        def reset!
          @enabled = false
          @logger = nil
          @log_level = :info
          @default_logger = nil
        end

        private

        # Check if a level should be logged based on current log_level
        # @param level [Symbol] the level to check
        # @return [Boolean]
        def should_log?(level)
          return false unless enabled

          current_level_index = LEVELS.index(@log_level || :info)
          message_level_index = LEVELS.index(level)
          message_level_index >= current_level_index
        end

        # Internal log method
        # @param level [Symbol] log level
        # @param message [String] the message
        # @param context [Hash] context data
        def log(level, message, context)
          return unless should_log?(level)

          formatted = if context.any?
              "#{message} #{format_context(context)}"
            else
              message
            end

          current_logger.send(level, formatted)
        end

        # Format context hash for logging
        # @param context [Hash] context data
        # @return [String]
        def format_context(context)
          context.map do |k, v|
            value = case v
              when Exception
                "#{v.class}: #{v.message}"
              when String
                v.length > 100 ? "#{v[0..97]}..." : v
              else
                v.inspect
              end
            "#{k}=#{value}"
          end.join(" ")
        end
      end

      # Initialize defaults
      @enabled = false
      @log_level = :info
    end
  end
end
