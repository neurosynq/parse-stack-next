# encoding: UTF-8
# frozen_string_literal: true

# Console-friendly helpers for interactive Parse sessions.
#
# `watch` and `wait_for` wrap the LiveQuery subscription machinery in a
# blocking-by-default shape suited for `bin/rails console`, `bin/console`,
# or one-off Rake tasks where the caller wants to:
#
#   - Tail a class as rows arrive ("watch new posts"), Ctrl-C to stop.
#   - Block until a specific row appears or a condition matches
#     ("wait until job N flips to :done"), with an optional timeout.
#
# Auth resolution is automatic:
#   - If `Parse.current_session_token` is set (via `Parse.login`,
#     `Parse.with_session`, or `Parse.session_token=`), the subscription
#     is ACL-aware as that user.
#   - Otherwise it falls through with no token — the LiveQuery server
#     then applies whatever default the master-key / unauthenticated
#     subscription model dictates for the class.
#
# Both helpers also accept an explicit `session_token:` kwarg for
# tests / fixtures.

require "timeout"

module Parse
  module Console
    DEFAULT_WATCH_EVENTS  = [:create, :update, :delete, :enter, :leave].freeze
    DEFAULT_WAIT_FOR_EVENTS = [:create, :enter].freeze

    module_function

    # Open a LiveQuery subscription on `klass` and block until SIGINT
    # (Ctrl-C). Intended for REPL / console use — emits arriving events
    # to `$stdout` by default, or yields each one to a caller-supplied
    # block.
    #
    # @example Tail every event for a class
    #   Parse.watch(Post)
    #   # ^C to stop
    #
    # @example Tail with a query and a custom handler
    #   Parse.watch(Post, where: { category: "alerts" }) do |event, obj|
    #     puts "[#{event}] #{obj.title} (#{obj.id})"
    #   end
    #
    # @example Admin-style with master key (no ambient session)
    #   Parse.with_session(nil) { Parse.watch(JobRun) }
    #
    # @param klass [Class] a Parse::Object subclass.
    # @param where [Hash] optional query constraints.
    # @param on [Symbol, Array<Symbol>, nil] which event types to
    #   subscribe to (default: all of :create/:update/:delete/:enter/:leave).
    # @param fields [Array<String>, nil] only fire updates when these
    #   fields change.
    # @param session_token [String, nil] explicit override; defaults to
    #   `Parse.current_session_token`.
    # @yield [event, object] called for each emitted event when a block
    #   is supplied. `event` is one of the watched symbols; `object` is
    #   the row.
    # @return [Integer] the count of events delivered before the caller
    #   interrupted (Ctrl-C) or the subscription was torn down.
    def watch(klass, where: {}, on: nil, fields: nil, session_token: nil, &block)
      events = Array(on || DEFAULT_WATCH_EVENTS).map(&:to_sym)
      printer = block_given? ? block : ->(ev, obj) {
        title = obj.respond_to?(:id) ? obj.id : obj.inspect
        puts "[#{Time.now.iso8601}] #{klass.parse_class}.#{ev} #{title}"
      }

      delivered = 0
      counter_lock = Monitor.new
      sub = _open_subscription(klass, where: where, fields: fields, session_token: session_token)

      events.each do |ev|
        sub.on(ev) do |obj, _original = nil|
          counter_lock.synchronize { delivered += 1 }
          begin
            printer.call(ev, obj)
          rescue StandardError => e
            warn "[Parse.watch] handler raised #{e.class}: #{e.message}"
          end
        end
      end
      sub.on(:error) { |err| warn "[Parse.watch] error: #{err}" }

      _block_until_interrupt
      delivered
    ensure
      sub.unsubscribe if sub && sub.respond_to?(:unsubscribe)
    end

    # Block until a row matching the predicate arrives via LiveQuery,
    # then return that row. Useful for `wait until the job flips`,
    # `wait until the inbox row lands`, integration tests, etc.
    #
    # By default the first `:create`/`:enter` event resolves the wait.
    # Pass a block to require the event also satisfy a predicate —
    # `wait_for(Job, where: { kind: "import" }) { |j| j.status == "done" }`
    # will keep waiting until both the query matches AND the block
    # returns truthy.
    #
    # @example Wait for the first row of a class
    #   first = Parse.wait_for(Notification)
    #
    # @example Wait with a query and a predicate
    #   done = Parse.wait_for(Job, where: { kind: "import" },
    #                          timeout: 60) { |j| j.status == "done" }
    #
    # @param klass [Class] a Parse::Object subclass.
    # @param where [Hash] optional query constraints applied server-side.
    # @param on [Symbol, Array<Symbol>] which event types to count
    #   (default: [:create, :enter]; pass :update for status-flip
    #   watching).
    # @param timeout [Numeric, nil] seconds to wait. nil = forever.
    # @param fields [Array<String>, nil] field filter for update events.
    # @param session_token [String, nil] explicit override; defaults to
    #   `Parse.current_session_token`.
    # @yield [object] optional predicate; must return truthy to resolve.
    # @return [Parse::Object] the matched row.
    # @raise [Timeout::Error] when `timeout:` elapses with no match.
    def wait_for(klass, where: {}, on: nil, timeout: nil, fields: nil,
                 session_token: nil, &predicate)
      events = Array(on || DEFAULT_WAIT_FOR_EVENTS).map(&:to_sym)
      queue  = Queue.new
      sub = _open_subscription(klass, where: where, fields: fields, session_token: session_token)

      events.each do |ev|
        sub.on(ev) do |obj, _original = nil|
          begin
            next if predicate && !predicate.call(obj)
            queue << obj
          rescue StandardError => e
            queue << e
          end
        end
      end
      sub.on(:error) { |err| queue << err }

      result = if timeout
          Timeout.timeout(timeout) { queue.pop }
        else
          queue.pop
        end

      raise result if result.is_a?(Exception)
      result
    ensure
      sub.unsubscribe if sub && sub.respond_to?(:unsubscribe)
    end

    # @!visibility private
    def _open_subscription(klass, where:, fields:, session_token:)
      unless klass.respond_to?(:subscribe)
        raise ArgumentError, "#{klass.inspect} does not implement .subscribe — pass a Parse::Object subclass"
      end
      klass.subscribe(where: where, fields: fields, session_token: session_token)
    end

    # @!visibility private
    #
    # Block the current thread until SIGINT (Ctrl-C) is received.
    # We install a one-shot handler that releases a sleeping queue.pop
    # and restore the prior handler on exit so library users can wrap
    # `watch` inside their own signal-handling code without losing it.
    def _block_until_interrupt
      gate = Queue.new
      prior = Signal.trap("INT") { gate << :interrupted }
      gate.pop
    ensure
      Signal.trap("INT", prior || "DEFAULT") if defined?(prior)
    end
  end

  class << self
    # @see Parse::Console.watch
    def watch(klass, **kwargs, &block)
      Console.watch(klass, **kwargs, &block)
    end

    # @see Parse::Console.wait_for
    def wait_for(klass, **kwargs, &block)
      Console.wait_for(klass, **kwargs, &block)
    end
  end

  class Object < Pointer
    class << self
      # Tail this class as LiveQuery events arrive — blocking, Ctrl-C
      # to stop. See {Parse::Console.watch}.
      def watch(**kwargs, &block)
        Parse::Console.watch(self, **kwargs, &block)
      end

      # Block until the first row matching {where} (and an optional
      # predicate block) arrives via LiveQuery. See
      # {Parse::Console.wait_for}.
      def wait_for(**kwargs, &block)
        Parse::Console.wait_for(self, **kwargs, &block)
      end
    end
  end
end
