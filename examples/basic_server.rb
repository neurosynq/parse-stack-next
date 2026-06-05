#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic Server-Side Setup for parse-stack-next
#
# The privileged way an app/server boots the SDK: configure a client WITH the
# master key, define a model, push its schema, and do CRUD + queries. Because
# the master key is present, Parse Server treats every request as an admin
# operation (ACL / CLP / protectedFields are bypassed) — which is exactly what
# you want for a trusted backend, and exactly what you must NOT do in an
# untrusted client (see basic_client.rb for that side).
#
# Run it:
#   export PARSE_SERVER_URL=http://localhost:1337/parse
#   export PARSE_APP_ID=... PARSE_REST_KEY=... PARSE_MASTER_KEY=...
#   ruby examples/basic_server.rb

require "parse-stack-next"

# ---------------------------------------------------------------------------
# 1. Configure the (master-key) client
# ---------------------------------------------------------------------------
Parse.setup(
  server_url: ENV.fetch("PARSE_SERVER_URL", "http://localhost:1337/parse"),
  app_id:     ENV.fetch("PARSE_APP_ID"),
  api_key:    ENV.fetch("PARSE_REST_KEY"),
  master_key: ENV.fetch("PARSE_MASTER_KEY"),
)

# ---------------------------------------------------------------------------
# 2. Define models
# ---------------------------------------------------------------------------
class Artist < Parse::Object
  property :name, :string, required: true
  property :country, :string
end

class Song < Parse::Object
  property :title, :string, required: true
  property :plays, :integer, default: 0
  property :released_on, :date

  belongs_to :artist          # stored as a Pointer<Artist>
end

# Provisioned here for the companion basic_client.rb. A no-master client can't
# create a class when Parse Server's allowClientClassCreation is false (the
# default since Parse Server 5.0), so the trusted side defines it up front.
class Post < Parse::Object
  property :title, :string
  property :body, :string
end

# ---------------------------------------------------------------------------
# 3. Push the schema (server-side only — needs the master key)
# ---------------------------------------------------------------------------
# auto_upgrade! creates the class and any missing columns on Parse Server to
# match the model definition. Run it at boot / deploy, not on every request.
Artist.auto_upgrade!
Song.auto_upgrade!
Post.auto_upgrade!

# ---------------------------------------------------------------------------
# 4. Create
# ---------------------------------------------------------------------------
artist = Artist.create!(name: "Daft Punk", country: "FR")

song = Song.new(title: "One More Time", plays: 1_000, artist: artist)
song.save                              # => true (returns false + sets .errors on failure)
puts "Created Song #{song.id}: #{song.title}"

# create! is `new(attrs).save!` in one call (raises on failure):
Song.create!(title: "Harder, Better, Faster, Stronger", plays: 2_500, artist: artist)

# ---------------------------------------------------------------------------
# 5. Read
# ---------------------------------------------------------------------------
found = Song.query(:objectId => song.id).include(:artist).first   # eager-load the pointer
puts "Fetched: #{found.title} by #{found.artist.name}"

first_hit = Song.first(title: "One More Time")
puts "First match plays: #{first_hit.plays}"

# ---------------------------------------------------------------------------
# 6. Update
# ---------------------------------------------------------------------------
song.plays += 1
song.save
puts "Updated plays: #{song.plays}"

# ---------------------------------------------------------------------------
# 7. Query
# ---------------------------------------------------------------------------
# DataMapper-style constraints. Symbol operators (:plays.gt) build comparisons;
# order / limit chain on.
popular = Song.query(:plays.gt => 1_500)
              .where(artist: artist)
              .order(:plays.desc)
              .limit(10)
              .results
puts "Popular songs: #{popular.map(&:title).join(', ')}"

puts "Total songs by #{artist.name}: #{Song.count(artist: artist)}"

# ---------------------------------------------------------------------------
# 8. Delete
# ---------------------------------------------------------------------------
song.destroy
puts "Destroyed #{song.id}"
