# frozen_string_literal: true

# Snapshots and restores every piece of process-wide webhook configuration a
# test can change: the webhook key and its ENV fallbacks, the unauthenticated
# and private-URL switches, logging, the after-callback error policy, the
# registered routes, and the replay-protection settings and cache.
#
# Include it in a webhook test class. It wraps every test (Minitest's
# before_setup / after_teardown), so a test's own setup and teardown run
# inside the snapshot and nothing a test sets leaks into the next file when
# several webhook test files are loaded into one process.
module WebhookGlobalState
  ENV_KEYS = %w[
    PARSE_SERVER_WEBHOOK_KEY
    PARSE_WEBHOOK_KEY
    PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED
    PARSE_WEBHOOK_SIGNING_SECRET
  ].freeze

  WEBHOOK_IVARS = %i[
    @key
    @allow_unauthenticated
    @allow_private_webhook_urls
    @missing_key_warned
    @abort_after_callbacks_on_error
    @logging
    @routes
  ].freeze

  REPLAY_IVARS = %i[
    @signing_secret
    @signing_max_skew_seconds
    @replay_window_seconds
    @replay_cache_size
  ].freeze

  def self.capture
    {
      env: ENV_KEYS.to_h { |name| [name, ENV[name]] },
      webhooks: ivars_of(Parse::Webhooks, WEBHOOK_IVARS),
      replay: ivars_of(Parse::Webhooks::ReplayProtection, REPLAY_IVARS),
    }
  end

  def self.restore(snapshot)
    snapshot[:env].each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    set_ivars(Parse::Webhooks, snapshot[:webhooks])
    Parse::Webhooks::ReplayProtection.reset!
    set_ivars(Parse::Webhooks::ReplayProtection, snapshot[:replay])
  end

  def self.ivars_of(target, names)
    names.to_h do |name|
      [name, target.instance_variable_defined?(name) ? [target.instance_variable_get(name)] : nil]
    end
  end

  def self.set_ivars(target, saved)
    saved.each do |name, boxed|
      if boxed
        target.instance_variable_set(name, boxed.first)
      elsif target.instance_variable_defined?(name)
        target.remove_instance_variable(name)
      end
    end
  end

  def before_setup
    @__webhook_global_state = WebhookGlobalState.capture
    super
  end

  def after_teardown
    super
  ensure
    WebhookGlobalState.restore(@__webhook_global_state) if @__webhook_global_state
  end
end
