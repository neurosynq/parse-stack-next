#!/usr/bin/env ruby
# frozen_string_literal: true

# Live Query Listener for parse-stack-next
#
# An interactive console listener — like a tail / `rails console` that just
# prints: it logs in as a user, opens a LiveQuery subscription scoped to that
# user's session token, and prints every event (create / update / delete /
# enter / leave) until you press Ctrl-C.
#
# Because the subscription carries the user's `sessionToken`, Parse Server
# enforces ACLs on the live stream too: you only receive events for objects
# that user is allowed to read — "whatever the user can hear." Swap in a
# master-key subscription (use_master_key: true) to hear everything.
#
# Prerequisite: the `Post` class must exist on the server (run
# examples/basic_server.rb first, which provisions it). You also need a Parse
# Server with the LiveQuery websocket server enabled for the Post class.
#
# Run it, then in another terminal create/update/destroy Posts (e.g. via
# examples/basic_client.rb or the dashboard) and watch them stream in:
#   export PARSE_SERVER_URL=http://localhost:1337/parse
#   export PARSE_APP_ID=... PARSE_REST_KEY=...
#   export PARSE_LIVE_QUERY_URL=ws://localhost:1337/parse   # ws:// or wss://
#   ruby examples/live_query_listener.rb

require "parse-stack-next"
require "parse/live_query"

# ---------------------------------------------------------------------------
# 1. Configure the REST client + the LiveQuery websocket client
# ---------------------------------------------------------------------------
Parse.setup(
  server_url: ENV.fetch("PARSE_SERVER_URL", "http://localhost:1337/parse"),
  app_id:     ENV.fetch("PARSE_APP_ID"),
  api_key:    ENV.fetch("PARSE_REST_KEY"),
  master_key: nil,            # a plain client — the session token does the scoping
  logging:    false,
)

Parse.live_query_enabled = true
Parse::LiveQuery.configure do |config|
  config.url            = ENV.fetch("PARSE_LIVE_QUERY_URL", "ws://localhost:1337/parse")
  config.application_id = ENV.fetch("PARSE_APP_ID")
  config.client_key     = ENV.fetch("PARSE_REST_KEY")
end

class Post < Parse::Object
  property :title, :string
  property :body, :string
end

# ---------------------------------------------------------------------------
# 2. Authenticate (so the subscription is ACL-scoped to this user)
# ---------------------------------------------------------------------------
USERNAME = ENV.fetch("PARSE_USERNAME", "ada")
PASSWORD = ENV.fetch("PARSE_PASSWORD", "p4ssw0rd!")

user = Parse::User.login(USERNAME, PASSWORD) ||
       Parse::User.signup(USERNAME, PASSWORD, "ada@example.com")
puts "Listening as #{user.username} (#{user.id}) — only Posts this user can read.\n\n"

# ---------------------------------------------------------------------------
# 3. Open the subscription + register handlers
# ---------------------------------------------------------------------------
def stamp = Time.now.strftime("%H:%M:%S")

# `where:` narrows the live query (omit it to hear every readable Post);
# `session_token:` is what makes Parse Server apply this user's ACL to the
# stream. Use `use_master_key: true` instead to listen to everything.
subscription = Post.subscribe(
  where: {},                          # e.g. { :title.exists => true }
  session_token: user.session_token,
)

subscription.on(:subscribe)   { puts "[#{stamp}] subscribed — waiting for events…" }
subscription.on(:create)      { |post|        puts "[#{stamp}] CREATE  #{post.id}  #{post.title.inspect}" }
subscription.on(:update)      { |post, _orig| puts "[#{stamp}] UPDATE  #{post.id}  #{post.title.inspect}" }
subscription.on(:delete)      { |post|        puts "[#{stamp}] DELETE  #{post.id}" }
subscription.on(:enter)       { |post, _orig| puts "[#{stamp}] ENTER   #{post.id}  (now matches query)" }
subscription.on(:leave)       { |post, _orig| puts "[#{stamp}] LEAVE   #{post.id}  (no longer matches)" }
subscription.on(:error)       { |err|         warn "[#{stamp}] ERROR   #{err}" }

# ---------------------------------------------------------------------------
# 4. Block and print until Ctrl-C
# ---------------------------------------------------------------------------
running = true
trap("INT") do
  running = false               # keep the handler tiny — just flip the flag
end

puts "Press Ctrl-C to stop.\n\n"
sleep 0.2 while running         # events arrive on the websocket thread

puts "\nStopping…"
subscription.unsubscribe
Parse::LiveQuery.reset!         # closes the websocket connection
puts "Done."
