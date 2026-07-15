# encoding: UTF-8
# frozen_string_literal: true

# Note: Do not require "../object" here - this file is loaded from object.rb
# and adding that require would create a circular dependency.

module Parse
  # This class represents the data and columns contained in the standard Parse
  # `_JobStatus` collection. Parse Server writes a row here every time a
  # background job (registered via `Parse.Cloud.job(...)`) runs, recording its
  # outcome and any status/message updates emitted via `response.message(...)`.
  #
  # The default schema for {JobStatus} is as follows:
  #
  #   class Parse::JobStatus < Parse::Object
  #      # See Parse::Object for inherited properties...
  #
  #      property :job_name
  #      property :source             # how the job was invoked
  #      property :status             # "running", "succeeded", "failed"
  #      property :message            # latest status message emitted by the job
  #      property :params, :object    # parameters the job was invoked with
  #      property :finished_at, :date # when the job stopped running
  #   end
  #
  # *Defining a job*
  #
  # Jobs are registered in your Parse Server's Cloud Code (server-side
  # JavaScript), not in this Ruby SDK. A minimal example:
  #
  #    // cloud/main.js
  #    Parse.Cloud.job("nightlyCleanup", async (request) => {
  #      const { params, headers, log, message } = request;
  #      message("Starting cleanup...");
  #      const query = new Parse.Query("_Session");
  #      query.lessThan("expiresAt", new Date());
  #      const sessions = await query.find({ useMasterKey: true });
  #      await Parse.Object.destroyAll(sessions, { useMasterKey: true });
  #      message(`Deleted ${sessions.length} sessions`);
  #      return `ok`;
  #    });
  #
  # *Invoking a job*
  #
  # Once registered, a job can be triggered ad-hoc via REST (requires the
  # master key):
  #
  #    POST /parse/jobs/nightlyCleanup
  #    X-Parse-Application-Id: ...
  #    X-Parse-Master-Key: ...
  #    Content-Type: application/json
  #
  #    { "someParam": "value" }
  #
  # The request returns immediately with a `_JobStatus` `objectId`; the job
  # itself runs asynchronously, and the `_JobStatus` row is updated as it
  # progresses. For *recurring* runs, configure a {Parse::JobSchedule} row
  # via the Parse Dashboard's "Jobs" tab — Parse Server's scheduler will
  # invoke the job at the configured times.
  #
  # *Reading job status from Ruby*
  #
  #    # Has the nightly cleanup run today?
  #    latest = Parse::JobStatus.latest_for("nightlyCleanup")
  #    puts "Last run: #{latest.status} at #{latest.created_at}"
  #    puts "Duration: #{latest.duration}s" if latest.finished?
  #
  #    # Find failed jobs in the last 24h
  #    yesterday = Time.now - 86_400
  #    Parse::JobStatus.failed.where(:created_at.gt => yesterday).all
  #
  # @note This collection is written by Parse Server itself and read access
  #   requires the master key. `_JobStatus` is hardcoded master-key-only at
  #   Parse Server's REST layer (`SharedRest.js`) — CLP changes via
  #   {Parse::Object.set_clp} have no effect. Use a master-key client (or a
  #   Cloud Code function) to read it. Parse Server does not garbage-collect
  #   `_JobStatus` rows — long-running deployments accumulate history and
  #   should implement their own retention policy.
  # @see Parse::JobSchedule for the corresponding scheduled-run configuration.
  # @see Parse::Object
  class JobStatus < Parse::Object
    parse_class Parse::Model::CLASS_JOB_STATUS

    # Note: This class is marked `agent_hidden` after
    # `Parse::Agent::MetadataDSL` is mixed into `Parse::Object` (the mixin
    # happens in `lib/parse/agent.rb`, which is required after this file
    # via `lib/parse/stack.rb`, so calling `agent_hidden` here in the class
    # body would raise NameError). The actual hide is performed by the
    # `Parse::JobStatus.agent_hidden` call at the bottom of
    # `lib/parse/agent.rb`. `_JobStatus` carries operational signal
    # (registered job names, status messages, error traces in {#message},
    # scheduler parameters) that an agent surface should not enumerate by
    # default.

    # @!attribute job_name
    # The name the job was registered under (the first argument to
    # `Parse.Cloud.job`).
    # @return [String]
    property :job_name

    # @!attribute source
    # How the job was invoked. Parse Server itself hard-codes `"api"` in
    # `StatusHandler.js` for runs triggered via `POST /parse/jobs/<name>`;
    # external schedulers (parse-server-scheduler, dashboard cron tooling)
    # may inject other values when they create the `_JobStatus` row.
    # @return [String]
    property :source

    # @!attribute status
    # Current state of the job run. Common values are `"running"`,
    # `"succeeded"`, and `"failed"`.
    # @return [String]
    property :status

    # @!attribute message
    # The most recent status message emitted by the job via
    # `response.message(...)`.
    # @return [String]
    property :message

    # @!attribute params
    # The parameters the job was invoked with.
    # @return [Hash]
    property :params, :object

    # @!attribute finished_at
    # Timestamp when the job stopped running. Nil while the job is still
    # in-flight.
    # @return [Parse::Date]
    property :finished_at, :date

    # Parse Server's terminal status values, written by `setFinalStatus` in
    # `StatusHandler.js`. Mirrored here so callers can compare against named
    # constants instead of hard-coding strings.
    STATUS_RUNNING = "running"
    STATUS_SUCCEEDED = "succeeded"
    STATUS_FAILED = "failed"

    class << self
      # Query for jobs currently in the running state.
      # @return [Parse::Query]
      def running
        query(status: STATUS_RUNNING)
      end

      # Query for jobs that completed successfully.
      # @return [Parse::Query]
      def succeeded
        query(status: STATUS_SUCCEEDED)
      end

      # Query for jobs that failed.
      # @return [Parse::Query]
      def failed
        query(status: STATUS_FAILED)
      end

      # Query for the most recent job status rows, newest first.
      # @param limit [Integer] number of rows to return (default: 100)
      # @return [Parse::Query]
      def recent(limit: 100)
        query.order(:created_at.desc).limit(limit)
      end

      # Query scope for runs of a specific job by name.
      # @param name [String, Symbol]
      # @return [Parse::Query]
      def for_job(name)
        query(job_name: name.to_s)
      end

      # The most recently *started* run of the named job (any status),
      # ordered by `created_at`. Useful for "did the nightly cleanup run
      # yet?" introspection. Note that for a still-running job this may
      # return the in-flight row even after subsequent attempts have
      # finished — `created_at` is the start time, not the finish time.
      # @param name [String, Symbol]
      # @return [Parse::JobStatus, nil]
      def latest_for(name)
        for_job(name).order(:created_at.desc).first
      end

      # Query scope for `_JobStatus` rows older than the given threshold.
      # @param days [Integer] number of days since the row's `created_at`
      #   (default: 30)
      # @return [Parse::Query]
      # @example
      #   stale = Parse::JobStatus.older_than(days: 90).all
      def older_than(days: 30)
        cutoff = Time.now - (days * 24 * 60 * 60)
        query(:created_at.lt => cutoff)
      end

      # Count `_JobStatus` rows older than the given threshold.
      # @param days [Integer] number of days since `created_at` (default: 30)
      # @return [Integer]
      def older_than_count(days: 30)
        older_than(days: days).count
      end

      # Delete `_JobStatus` rows older than the given threshold. Parse Server
      # does not garbage-collect this collection on its own, so long-running
      # deployments accumulate run history indefinitely. Mirrors
      # {Parse::Installation.cleanup_stale_tokens!}.
      #
      # By default (`terminal_only: true`), only rows in a terminal state
      # (`succeeded` or `failed`) are eligible — an orphaned
      # `status == "running"` row from a crashed worker is preserved, as is
      # any row with an external-scheduler-injected status the SDK doesn't
      # recognize. Set `terminal_only: false` to drop the status guard and
      # reap every row older than the cutoff regardless of state (use with
      # care for orphan cleanup).
      #
      # Use with caution — permanently removes job-history records.
      #
      # @param days [Integer] number of days since `created_at` (default: 30).
      #   Negative values are accepted and produce a future cutoff (useful in
      #   tests for "delete everything older than now-plus-a-minute").
      # @param terminal_only [Boolean] when true (default), restrict the
      #   destroy to rows whose status is `succeeded` or `failed`. When
      #   false, every row older than the cutoff is eligible.
      # @return [Integer] the number of rows deleted
      # @example
      #   deleted = Parse::JobStatus.cleanup_older_than!(days: 90)
      def cleanup_older_than!(days: 30, terminal_only: true)
        scope = older_than(days: days)
        if terminal_only
          scope = scope.where(:status.in => [STATUS_SUCCEEDED, STATUS_FAILED])
        end
        stale = scope.all
        stale.each(&:destroy)
        stale.count
      end
    end

    # @return [Boolean] true if this row is in the running state.
    def running?
      status == STATUS_RUNNING
    end

    # @return [Boolean] true if this run completed successfully.
    def succeeded?
      status == STATUS_SUCCEEDED
    end

    # @return [Boolean] true if this run failed.
    def failed?
      status == STATUS_FAILED
    end

    # @return [Boolean] true if the run has reached a terminal state
    #   (succeeded or failed). Parse Server writes `finished_at` at the same
    #   time it transitions out of `running`, so either signal is acceptable;
    #   we check `finished_at` first because it's the more authoritative one.
    def finished?
      !finished_at.nil? || succeeded? || failed?
    end

    # Wall-clock duration of the run as a `Float` number of seconds, or `nil`
    # while the job is still in-flight (or if either timestamp is missing).
    # @return [Float, nil]
    def duration
      return nil if finished_at.nil? || created_at.nil?
      finished_at.to_time - created_at.to_time
    end
  end
end
