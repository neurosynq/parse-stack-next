# encoding: UTF-8
# frozen_string_literal: true

# Note: Do not require "../object" here - this file is loaded from object.rb
# and adding that require would create a circular dependency.

module Parse
  # This class represents the data and columns contained in the standard Parse
  # `_JobSchedule` collection. Rows here define recurring runs for background
  # jobs registered via `Parse.Cloud.job(...)`. The collection is populated by
  # the Parse Dashboard's "Schedule a Job" UI and consumed by Parse Server's
  # scheduler.
  #
  # The default schema for {JobSchedule} is as follows:
  #
  #   class Parse::JobSchedule < Parse::Object
  #      # See Parse::Object for inherited properties...
  #
  #      property :job_name
  #      property :description
  #      property :params              # JSON-encoded string of params (server stores as String)
  #      property :start_after         # ISO 8601 timestamp string for first run
  #      property :days_of_week, :array
  #      property :time_of_day         # "HH:MM:SS"
  #      property :last_run, :integer  # epoch seconds of the previous run
  #      property :repeat_minutes, :integer
  #   end
  #
  # *Defining and scheduling a job*
  #
  # The job itself is registered in Parse Server's Cloud Code (server-side
  # JavaScript). See {Parse::JobStatus} for the `Parse.Cloud.job(...)`
  # registration example.
  #
  # Schedules are normally created through the Parse Dashboard "Jobs" tab,
  # which writes the `_JobSchedule` row for you. The dashboard exposes:
  #
  #   - the registered job name to invoke
  #   - the parameters to pass (serialized to {#params} as JSON)
  #   - the start time ({#start_after}) and time-of-day ({#time_of_day})
  #   - the days of the week ({#days_of_week}) or repeat interval
  #     ({#repeat_minutes}) at which the run should fire
  #
  # `_JobSchedule` is a metadata collection: it stores schedule definitions
  # but Parse Server itself does not auto-trigger jobs from these rows. The
  # actual dispatch is performed by external tooling (e.g.
  # `parse-server-scheduler`, dashboard-driven cron wrappers, or a sidecar
  # process) which reads `_JobSchedule` and fires `POST /parse/jobs/<name>`
  # at the appropriate times. Run status rows then appear in
  # {Parse::JobStatus}.
  #
  # *Reading a schedule from Ruby*
  #
  #    schedule = Parse::JobSchedule.for_job("nightlyCleanup").first
  #    schedule.parsed_params # => { "dryRun" => false }   (decoded from `params`)
  #    schedule.time_of_day   # => "03:00:00"
  #    schedule.days_of_week  # => ["mon","tue","wed","thu","fri"]
  #
  # @note This collection is consumed by external scheduling tooling, not by
  #   Parse Server itself. {#params} is stored as a JSON string (not an
  #   Object) per the canonical Parse Server schema; use {#parsed_params} to
  #   decode. `_JobSchedule` is hardcoded master-key-only at Parse Server's
  #   REST layer (`SharedRest.js`) — CLP changes via
  #   {Parse::Object.set_clp} have no effect.
  # @see Parse::JobStatus
  # @see Parse::Object
  class JobSchedule < Parse::Object
    parse_class Parse::Model::CLASS_JOB_SCHEDULE

    # Note: This class is marked `agent_hidden` after
    # `Parse::Agent::MetadataDSL` is mixed into `Parse::Object` (the mixin
    # happens in `lib/parse/agent.rb`, which is required after this file
    # via `lib/parse/stack.rb`, so calling `agent_hidden` here in the class
    # body would raise NameError). The actual hide is performed by the
    # `Parse::JobSchedule.agent_hidden` call at the bottom of
    # `lib/parse/agent.rb`. `_JobSchedule` rows define recurring runs and
    # can contain scheduler parameters or credentials in {#params}.

    # @!attribute job_name
    # The registered job name to invoke on each run.
    # @return [String]
    property :job_name

    # @!attribute description
    # Free-form description of this scheduled job, as entered in the
    # dashboard.
    # @return [String]
    property :description

    # @!attribute params
    # JSON-encoded string of parameters to pass to the job. Stored as a String
    # in the canonical Parse Server schema to avoid the nested-key character
    # restrictions that apply to Object columns.
    # @return [String]
    property :params

    # @!attribute start_after
    # ISO 8601 timestamp string indicating the earliest time the first
    # scheduled run may fire.
    # @return [String]
    property :start_after

    # @!attribute days_of_week
    # Array of day-of-week identifiers indicating which days the job is
    # eligible to run. The exact token set (e.g. `"mon"`/`"tue"`/... vs.
    # `0`..`6`) is determined by the scheduler tooling that writes the row;
    # the Parse Server schema only requires that the column hold an array.
    # @return [Array]
    property :days_of_week, :array

    # @!attribute time_of_day
    # "HH:MM:SS" string indicating the time of day at which the job should
    # run on each eligible day.
    # @return [String]
    property :time_of_day

    # @!attribute last_run
    # Raw `Number` timestamp recording the previous run. The unit is
    # scheduler-defined — most external schedulers write `Date.now()`
    # milliseconds, but the canonical Parse Server schema only declares
    # `Number` and does not pin a unit. Treat values written by one
    # scheduler as opaque to others.
    # @return [Integer]
    property :last_run, :integer

    # @!attribute repeat_minutes
    # Interval in minutes between runs, when the schedule is interval-based
    # rather than time-of-day-based.
    # @return [Integer]
    property :repeat_minutes, :integer

    class << self
      # Query scope for schedules belonging to a specific job by name.
      # @param name [String, Symbol]
      # @return [Parse::Query]
      def for_job(name)
        query(job_name: name.to_s)
      end
    end

    # Decoded form of {#params}, which is stored on the wire as a JSON
    # string per the canonical Parse Server schema. Returns the parsed
    # Hash, or `nil` if `params` is blank, or `nil` if the stored string is
    # not valid JSON (Parse Dashboard occasionally writes a non-JSON
    # description string here for ad-hoc schedules — we swallow the parse
    # error rather than crash the caller).
    # @return [Hash, nil]
    def parsed_params
      return nil if params.blank?
      JSON.parse(params)
    rescue JSON::ParserError
      nil
    end
  end
end
