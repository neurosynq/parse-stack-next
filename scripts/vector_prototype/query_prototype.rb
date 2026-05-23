#!/usr/bin/env ruby
# Exercise Atlas $vectorSearch end-to-end via the Ruby mongo driver — the
# same driver Parse::MongoDB.aggregate uses. This is the literal pipeline
# shape Parse::VectorSearch will produce (vector_rag_plan.md §3).
#
# Run:
#   bundle exec ruby scripts/vector_prototype/query_prototype.rb
#
# Prereq: fetch_embeddings.py + create_vector_index.js have been run, so
# vector_prototype.WikiArticle is populated and the search index is
# queryable.
#
# This script intentionally avoids any Parse::* SDK code — it's the raw
# Atlas surface, used as the ground-truth comparison once Parse::VectorSearch
# lands. The same pipeline shape will be emitted by Parse::VectorSearch::SearchBuilder.

require "mongo"

require "json"

MANIFEST_PATH = File.expand_path("fixture_manifest.json", __dir__)
unless File.exist?(MANIFEST_PATH)
  abort "no fixture_manifest.json — run fetch_embeddings.py first"
end
MANIFEST = JSON.parse(File.read(MANIFEST_PATH))

MONGO_URI = ENV.fetch("ATLAS_URI", "mongodb://localhost:27020/#{MANIFEST['db']}?directConnection=true")
INDEX_NAME = ENV.fetch("VECTOR_INDEX", MANIFEST["index_name"])
COLL_NAME = MANIFEST["collection"].to_sym

puts "[manifest] preset=#{MANIFEST['preset']}  provider=#{MANIFEST['provider']}  dims=#{MANIFEST['dims']}  index=#{INDEX_NAME}"

client = Mongo::Client.new(MONGO_URI)
coll = client[COLL_NAME]

count = coll.count_documents({})
abort "no docs loaded — run fetch_embeddings.py first" if count.zero?
puts "[setup] #{count} docs in #{client.database.name}.#{COLL_NAME}"

# Use an existing doc's vector as the query — exercises the index without
# requiring an embedding API. When Voyage lands, swap this for a freshly
# computed query vector against the same index.
seed = coll.find.limit(1).first
puts "[seed] #{seed["title"]}  (#{seed["embedding"].size}-dim)"

pipeline = [
  {
    "$vectorSearch" => {
      "index"         => INDEX_NAME,
      "path"          => "embedding",
      "queryVector"   => seed["embedding"],
      "numCandidates" => 200,
      "limit"         => 10,
    },
  },
  {
    "$project" => {
      "_id"     => 1,
      "title"   => 1,
      # Project the score under _vscore (not _score) so hybrid search with
      # Atlas Search lexical scores doesn't collide. Matches the convention
      # the SDK will adopt — vector_rag_plan.md §3.
      "_vscore" => { "$meta" => "vectorSearchScore" },
    },
  },
]

puts "[query] $vectorSearch  limit=10  numCandidates=200"
t0 = Time.now
results = coll.aggregate(pipeline).to_a
elapsed_ms = ((Time.now - t0) * 1000).round(1)

puts "[result] #{results.size} hits in #{elapsed_ms}ms"
results.each_with_index do |r, i|
  printf("  %2d. score=%.4f  %s\n", i + 1, r["_vscore"], r["title"])
end

# Sanity: top hit should be the seed itself (cosine = 1.0)
top = results.first
if top && top["_id"] == seed["_id"]
  puts "[ok] top hit == seed (self-similarity verified)"
else
  puts "[warn] top hit was not the seed — index may still be building"
end
