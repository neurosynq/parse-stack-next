# encoding: UTF-8
# frozen_string_literal: true

# Note: Do not require "../object" here - this file is loaded from object.rb
# and adding that require would create a circular dependency.

module Parse
  # This class represents the data and columns contained in the standard Parse
  # `_PushStatus` collection. Push status records track the delivery status
  # and metrics of push notifications sent through Parse Server.
  #
  # Push status records are created automatically when a push is sent and
  # are updated as the push progresses through the delivery pipeline.
  #
  # Status lifecycle: pending → scheduled → running → succeeded/failed
  #
  # The default schema for the {PushStatus} class is as follows:
  #   class Parse::PushStatus < Parse::Object
  #      # See Parse::Object for inherited properties...
  #
  #      property :push_hash        # Unique hash identifying the push
  #      property :query, :object   # The query used to target installations
  #      property :payload, :object # The push payload that was sent
  #      property :source           # "rest" or "webUI"
  #      property :status           # "pending", "scheduled", "running", "succeeded", "failed"
  #      property :num_sent, :integer
  #      property :num_failed, :integer
  #      property :sent_per_type, :object
  #      property :failed_per_type, :object
  #      property :sent_per_utc_offset, :object
  #      property :failed_per_utc_offset, :object
  #      property :count, :integer  # Total installations targeted
  #      property :push_time, :date # When the push was/will be sent
  #      property :expiry, :date    # When the push expires
  #   end
  #
  # @example Checking push status
  #   status = Parse::PushStatus.find(push_id)
  #   puts "Sent: #{status.num_sent}, Failed: #{status.num_failed}"
  #   puts "Status: #{status.status}"
  #
  # @example Querying recent pushes
  #   recent = Parse::PushStatus.recent.limit(10).all
  #   recent.each { |s| puts "#{s.status}: #{s.num_sent} sent" }
  #
  # @note This collection requires master key access
  # @see Parse::Push
  # @see Parse::Object
  class PushStatus < Parse::Object
    parse_class Parse::Model::CLASS_PUSH_STATUS

    # @!attribute push_hash
    # A unique hash identifying this push notification.
    # @return [String] The push hash.
    property :push_hash

    # @!attribute query
    # The query constraints used to target installations.
    # @return [Hash] The query constraint hash.
    property :query, :object

    # @!attribute payload
    # The push payload that was sent.
    # @return [Hash] The payload data.
    property :payload, :object

    # @!attribute source
    # The source of the push ("rest" for API, "webUI" for dashboard).
    # @return [String] The push source.
    property :source

    # @!attribute status
    # The current status of the push.
    # One of: "pending", "scheduled", "running", "succeeded", "failed"
    # @return [String] The push status.
    property :status

    # @!attribute num_sent
    # The number of notifications successfully sent.
    # @return [Integer] The success count.
    property :num_sent, :integer

    # @!attribute num_failed
    # The number of notifications that failed to send.
    # @return [Integer] The failure count.
    property :num_failed, :integer

    # @!attribute sent_per_type
    # Breakdown of successful sends by device type (ios, android, etc.).
    # @return [Hash] Device type to count mapping.
    # @example
    #   status.sent_per_type  # => {"ios" => 800, "android" => 450}
    property :sent_per_type, :object

    # @!attribute failed_per_type
    # Breakdown of failed sends by device type.
    # @return [Hash] Device type to count mapping.
    property :failed_per_type, :object

    # @!attribute sent_per_utc_offset
    # Breakdown of successful sends by UTC timezone offset.
    # @return [Hash] UTC offset to count mapping.
    # @example
    #   status.sent_per_utc_offset  # => {"-8" => 500, "0" => 300, "5" => 200}
    property :sent_per_utc_offset, :object

    # @!attribute failed_per_utc_offset
    # Breakdown of failed sends by UTC timezone offset.
    # @return [Hash] UTC offset to count mapping.
    property :failed_per_utc_offset, :object

    # @!attribute count
    # Total number of installations targeted by this push.
    # @return [Integer] The target count.
    property :count, :integer

    # @!attribute push_time
    # When the push was/will be sent. For scheduled pushes, this is the future time.
    # @return [Parse::Date] The push time.
    property :push_time, :date

    # @!attribute expiry
    # When the push expires and will no longer be delivered.
    # @return [Parse::Date] The expiration time.
    property :expiry, :date

    # @!attribute error_message
    # Error message if the push failed.
    # @return [String, nil] The error message or nil.
    property :error_message

    # =========================================================================
    # Status Query Scopes
    # =========================================================================

    class << self
      # Query for pending pushes (not yet started).
      # @return [Parse::Query] a query for pending pushes
      def pending
        query(status: "pending")
      end

      # Query for scheduled pushes (waiting for push_time).
      # @return [Parse::Query] a query for scheduled pushes
      def scheduled
        query(status: "scheduled")
      end

      # Query for running pushes (currently being sent).
      # @return [Parse::Query] a query for running pushes
      def running
        query(status: "running")
      end

      # Query for succeeded pushes.
      # @return [Parse::Query] a query for succeeded pushes
      def succeeded
        query(status: "succeeded")
      end

      # Query for failed pushes.
      # @return [Parse::Query] a query for failed pushes
      def failed
        query(status: "failed")
      end

      # Query for recent pushes, ordered by creation time descending.
      # @return [Parse::Query] a query for recent pushes
      def recent
        query.order(:created_at.desc)
      end
    end

    # =========================================================================
    # Status Predicates
    # =========================================================================

    # Check if the push is pending (not yet started).
    # @return [Boolean] true if status is "pending"
    def pending?
      status == "pending"
    end

    # Check if the push is scheduled (waiting for push_time).
    # @return [Boolean] true if status is "scheduled"
    def scheduled?
      status == "scheduled"
    end

    # Check if the push is currently running.
    # @return [Boolean] true if status is "running"
    def running?
      status == "running"
    end

    # Check if the push succeeded.
    # @return [Boolean] true if status is "succeeded"
    def succeeded?
      status == "succeeded"
    end

    # Check if the push failed.
    # @return [Boolean] true if status is "failed"
    def failed?
      status == "failed"
    end

    # Check if the push is complete (either succeeded or failed).
    # @return [Boolean] true if the push has finished
    def complete?
      succeeded? || failed?
    end

    # Check if the push is still in progress.
    # @return [Boolean] true if pending, scheduled, or running
    def in_progress?
      !complete?
    end

    # =========================================================================
    # Metrics Methods
    # =========================================================================

    # Get the total number of notifications attempted (sent + failed).
    # @return [Integer] the total count
    def total_attempted
      (num_sent || 0) + (num_failed || 0)
    end

    # Get the success rate as a percentage.
    # @return [Float] the success rate (0.0 to 100.0)
    # @example
    #   status.success_rate  # => 98.5
    def success_rate
      total = total_attempted
      return 0.0 if total == 0
      ((num_sent || 0).to_f / total * 100).round(2)
    end

    # Get the failure rate as a percentage.
    # @return [Float] the failure rate (0.0 to 100.0)
    def failure_rate
      100.0 - success_rate
    end

    # Get a summary of the push metrics.
    # @return [Hash] summary hash with key metrics
    # @example
    #   status.summary
    #   # => { status: "succeeded", sent: 1250, failed: 12, success_rate: 99.05 }
    def summary
      {
        status: status,
        sent: num_sent || 0,
        failed: num_failed || 0,
        total_targeted: count || 0,
        success_rate: success_rate,
        sent_per_type: sent_per_type || {},
        failed_per_type: failed_per_type || {},
      }
    end
  end
end
