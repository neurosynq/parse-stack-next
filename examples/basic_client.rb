#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic Client Setup for parse-stack-next
#
# The UNPRIVILEGED side: configure the SDK WITHOUT a master key — the way a
# mobile app, browser, or untrusted worker uses it. There is no admin escape
# hatch, so authorization is carried per-call by the user's sessionToken and
# Parse Server is the enforcement boundary (CLP rejects, ACL filters rows,
# protectedFields strips columns).
#
# This example logs a user in and shows that a row-level ACL actually blocks
# reads: the owning user can read their object; an anonymous client cannot.
#
# See basic_server.rb for the privileged (master-key) counterpart.
#
# Prerequisite: the `Post` class must already exist on the server. A no-master
# client cannot create a class when Parse Server's allowClientClassCreation is
# false (the default since 5.0), so run examples/basic_server.rb first (it
# provisions Post with the master key) — or create the class yourself.
#
# Run it (REST key only — no master key in this process):
#   export PARSE_SERVER_URL=http://localhost:1337/parse
#   export PARSE_APP_ID=... PARSE_REST_KEY=...
#   ruby examples/basic_client.rb

require "parse-stack-next"

# ---------------------------------------------------------------------------
# 1. Configure a no-master-key client
# ---------------------------------------------------------------------------
Parse.setup(
  server_url: ENV.fetch("PARSE_SERVER_URL", "http://localhost:1337/parse"),
  app_id:     ENV.fetch("PARSE_APP_ID"),
  api_key:    ENV.fetch("PARSE_REST_KEY"),
  master_key: nil,           # explicit: never set this from env in client builds
  logging:    false,
)

# Belt-and-suspenders: prove the master key really is absent.
raise "master key leaked into a client process!" unless Parse.client.master_key.nil?

class Post < Parse::Object
  property :title, :string
  property :body, :string
end

# ---------------------------------------------------------------------------
# 2. Authenticate (log in, or sign up on first run)
# ---------------------------------------------------------------------------
USERNAME = "ada"
PASSWORD = "p4ssw0rd!"

# Parse::User.login returns nil on bad/unknown credentials (it does not raise),
# so fall back to signup the first time.
user = Parse::User.login(USERNAME, PASSWORD) ||
       Parse::User.signup(USERNAME, PASSWORD, "ada@example.com")

puts "Logged in as #{user.username} (#{user.id})"
puts "Session token: #{user.session_token[0, 8]}…"

# ---------------------------------------------------------------------------
# 3. Create an owner-only object AS the user
# ---------------------------------------------------------------------------
# `with_session` authorizes every REST-routed op in the block as this user.
post = user.with_session do
  p = Post.new(title: "My private note", body: "Only Ada may read this.")
  # Owner-only ACL: grant read+write to this user, no public access.
  acl = Parse::ACL.new                 # empty == no public, no one
  acl.apply(user.id, true, true)       # this user: read + write
  p.acl = acl
  p.save
  p
end
puts "Created Post #{post.id} with an owner-only ACL"

# ---------------------------------------------------------------------------
# 4. Read it back AS the owner — succeeds
# ---------------------------------------------------------------------------
as_owner = user.with_session { Post.find(post.id) }
puts "As owner  -> #{as_owner ? "READ OK: #{as_owner.title.inspect}" : "BLOCKED"}"

# ---------------------------------------------------------------------------
# 5. Read it back ANONYMOUSLY (no session token) — blocked by the ACL
# ---------------------------------------------------------------------------
# No master key + no session => a plain REST request the ACL filters out.
# `first` returns nil rather than raising when the row is not visible.
anon = Post.first(objectId: post.id)
puts "Anonymous -> #{anon ? "READ OK (unexpected!): #{anon.title.inspect}" : "BLOCKED (nil) — ACL enforced"}"

# Takeaway: identical SDK calls return the row for the owner and nil for an
# unauthorized caller. That difference is Parse Server enforcing the ACL —
# the client SDK simply threads the auth context and reports the verdict.
