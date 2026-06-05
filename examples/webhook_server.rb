#!/usr/bin/env ruby
# frozen_string_literal: true

# Cloud Code Webhooks for parse-stack-next
#
# Webhooks are how a Ruby backend runs SERVER-SIDE trigger logic. Without them,
# a Parse::Object's ActiveModel callbacks (before_save, after_create, …) run
# ONLY in the Ruby process that initiated the save. A write that comes from a
# JS/Swift/REST client — or the Parse Dashboard — never touches your Ruby code,
# so that logic is silently skipped server-side.
#
# Registering a webhook flips that: Parse Server calls back into this Ruby app
# on the matching trigger, and your ActiveModel callbacks + webhook blocks run
# for EVERY client, not just Ruby ones.
#
# This file is a Rack app. Mount it (config.ru):
#
#   require_relative "examples/webhook_server"
#   run Parse::Webhooks
#
# and point Parse Server's `webhookKey` at the same value as Parse::Webhooks.key.
#
# See docs/webhooks_guide.md for the full picture (trigger types, the
# ActiveModel↔Parse hook relationship, latency, and replay protection).

require "parse-stack-next"

# ---------------------------------------------------------------------------
# 1. Configure the (master-key) client + the webhook key
# ---------------------------------------------------------------------------
Parse.setup(
  server_url: ENV.fetch("PARSE_SERVER_URL", "http://localhost:1337/parse"),
  app_id:     ENV.fetch("PARSE_APP_ID"),
  api_key:    ENV.fetch("PARSE_REST_KEY"),
  master_key: ENV.fetch("PARSE_MASTER_KEY"),
)

# Shared secret Parse Server sends as `X-Parse-Webhook-Key`. Set the same value
# in Parse Server's `webhookKey` option. Requests without it are rejected.
Parse::Webhooks.key = ENV.fetch("PARSE_WEBHOOK_KEY")

# Optional: server-initiated replay/freshness protection (see the guide). The
# body+request-id dedup is always on; an HMAC signing secret adds freshness
# verification of X-Parse-Webhook-Timestamp / X-Parse-Webhook-Signature.
Parse::Webhooks::ReplayProtection.signing_secret = ENV["PARSE_WEBHOOK_SIGNING_SECRET"]

# ---------------------------------------------------------------------------
# 2. A model with both ActiveModel callbacks AND webhook blocks
# ---------------------------------------------------------------------------
class Post < Parse::Object
  property :title, :string, required: true
  property :slug, :string
  property :published, :boolean, default: false

  # ActiveModel callbacks. For a Ruby-initiated save these run locally; for a
  # NON-Ruby client they run here only if a beforeSave/afterSave webhook is
  # registered for Post. Registering beforeSave enables BOTH before_save and
  # before_create; afterSave enables both after_save and after_create.
  before_save  :normalize_slug
  before_create { self.published = false } # created drafts start unpublished
  after_create :enqueue_welcome           # see note on afterSave below

  def normalize_slug
    self.slug = title.to_s.downcase.strip.gsub(/[^a-z0-9]+/, "-") if title_changed?
  end

  def enqueue_welcome
    # AFTER-SAVE BEST PRACTICE: enqueue, don't execute. Parse Server blocks the
    # client's write until this webhook returns — even though afterSave's return
    # is a no-op — so long work here adds latency to every save. And do NOT save
    # another object here if you can avoid it: each cascading save fires more
    # webhooks (a latency cascade). Hand off to a background job instead.
    # BackgroundJobs.enqueue(:index_post, id)
  end
end

Post.auto_upgrade!

# ---------------------------------------------------------------------------
# 3. Webhook blocks (optional) — server-side logic without a Ruby model callback
# ---------------------------------------------------------------------------
# A block runs in the scope of a Parse::Webhooks::Payload. A beforeSave block
# returns `parse_object` (the SDK turns it into the changes Parse Server wants);
# returning `false` halts the save.
class Post
  webhook :before_save do
    # `parse_object` is the incoming object; mutate it, then return it.
    parse_object
  end

  # afterSave/afterDelete blocks may register more than one handler.
  webhook :after_save do
    # keep this short or enqueue — see enqueue_welcome above.
    true
  end
end

# NOTE: there is no `webhook :before_create` / `:after_create`. Parse Server has
# no such trigger — register beforeSave/afterSave and your create callbacks fire
# within them for new objects. Asking for a create webhook raises with guidance.

# ---------------------------------------------------------------------------
# 4. Register the webhooks with Parse Server (run once at deploy, needs master key)
# ---------------------------------------------------------------------------
# `endpoint` is the public HTTPS URL where THIS Rack app is reachable.
if ENV["PARSE_WEBHOOK_ENDPOINT"]
  endpoint = ENV.fetch("PARSE_WEBHOOK_ENDPOINT") # e.g. https://hooks.example.com/webhooks
  Parse::Webhooks.register_functions!(endpoint)
  Parse::Webhooks.register_triggers!(endpoint)
  puts "Registered webhooks at #{endpoint}"
end
