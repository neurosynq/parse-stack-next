#!/usr/bin/env ruby
# frozen_string_literal: true

# RAG Chatbot Example for parse-stack-next
#
# A retrieval-augmented-generation (RAG) chatbot in a single file:
#
#   1. Store documents in Parse; the SDK manages their embeddings on save.
#   2. Retrieve the most relevant passages for a question with the
#      `semantic_search` agent tool.
#   3. Hand those passages to an LLM to write the answer.
#
# The SDK owns the **R** (retrieval) and the embedding lifecycle. The **G**
# (generation) is a thin add-in over the OpenAI or Anthropic HTTP API, shown
# here with zero extra gems (`net/http` only).
#
# Retrieval (`Parse::Retrieval` / `semantic_search`) shipped in v5.2; managed
# `embed` and the embeddings provider registry shipped in v5.1. Vector search
# runs against MongoDB Atlas (`$vectorSearch`), so point the SDK at an
# Atlas-backed Parse Server / Mongo URI.
#
# Run it:
#   export OPENAI_API_KEY=sk-...          # embeddings + (optionally) generation
#   export ANTHROPIC_API_KEY=sk-ant-...   # if using the Anthropic backend
#   export PARSE_SERVER_URL=http://localhost:1337/parse
#   export PARSE_APP_ID=... PARSE_REST_KEY=... PARSE_MASTER_KEY=...
#   ruby examples/rag_chatbot.rb

require "parse-stack-next"
require "net/http"
require "json"

# ---------------------------------------------------------------------------
# 1. Embedding provider + Parse connection
# ---------------------------------------------------------------------------

# text-embedding-3-small is 1536-dim. Register it under :openai so the model's
# :vector property can resolve it by name at save / query time.
Parse::Embeddings.register(
  :openai,
  Parse::Embeddings::OpenAI.new(api_key: ENV.fetch("OPENAI_API_KEY")),
)

Parse.setup(
  server_url: ENV.fetch("PARSE_SERVER_URL", "http://localhost:1337/parse"),
  app_id:     ENV.fetch("PARSE_APP_ID"),
  api_key:    ENV.fetch("PARSE_REST_KEY"),
  master_key: ENV.fetch("PARSE_MASTER_KEY"),
)

# ---------------------------------------------------------------------------
# 2. The model
# ---------------------------------------------------------------------------
#
# `embed` declares a MANAGED embedding: list the source fields, name the
# :vector property they feed, and the SDK recomputes the vector on `save`
# whenever those fields change (digest-tracked, so a no-op save makes zero
# provider calls). You never assign `embedding` yourself — it is
# write-protected. Set title/body and save.
#
# `agent_searchable` opts the class into the `semantic_search` agent tool and
# declares which fields an agent may filter on.
class KnowledgeArticle < Parse::Object
  property :title, :string
  property :body, :string
  property :category, :string

  property :embedding, :vector, dimensions: 1536, provider: :openai

  # title + body feed :embedding, recomputed on save.
  embed :title, :body, into: :embedding

  # Opt into semantic_search; allow filtering on :category.
  agent_searchable field: :embedding, filter_fields: %i[category]

  # Declare the Atlas $vectorSearch index that retrieval needs.
  mongo_search_index "knowledge_embedding",
                     { fields: [{ type: "vector", path: "embedding",
                                  numDimensions: 1536, similarity: "cosine" }] },
                     type: "vectorSearch"
end

# ---------------------------------------------------------------------------
# 3. The LLM generation add-in (NOT part of the SDK)
# ---------------------------------------------------------------------------
#
# ~15 lines of HTTP per backend. Both take the retrieved chunks as context and
# return an answer grounded in them.
module ChatAnswerer
  PROMPT = <<~SYS
    You are a support assistant. Answer ONLY from the context below.
    If the context does not contain the answer, say you don't know.
  SYS

  module_function

  def context(chunks)
    chunks.map { |c| "- #{c[:content]}" }.join("\n")
  end

  # --- OpenAI backend ---
  def openai(question, chunks, model: "gpt-4o-mini")
    post("https://api.openai.com/v1/chat/completions",
         { "Authorization" => "Bearer #{ENV.fetch('OPENAI_API_KEY')}" },
         { model: model,
           messages: [
             { role: "system", content: PROMPT },
             { role: "user",
               content: "Context:\n#{context(chunks)}\n\nQuestion: #{question}" },
           ] })
      .dig("choices", 0, "message", "content")
  end

  # --- Anthropic backend ---
  def anthropic(question, chunks, model: "claude-opus-4-8")
    post("https://api.anthropic.com/v1/messages",
         { "x-api-key"         => ENV.fetch("ANTHROPIC_API_KEY"),
           "anthropic-version" => "2023-06-01" },
         { model: model, max_tokens: 1024, system: PROMPT,
           messages: [
             { role: "user",
               content: "Context:\n#{context(chunks)}\n\nQuestion: #{question}" },
           ] })
      .dig("content", 0, "text")
  end

  def post(url, headers, body)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" }.merge(headers))
    req.body = JSON.generate(body)
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
    JSON.parse(res.body)
  end
end

# ---------------------------------------------------------------------------
# 4. Retrieval helper
# ---------------------------------------------------------------------------
#
# An unscoped Parse::Agent (no session_token: / acl_user: / acl_role:) runs in
# master posture using the master key already on the default client from
# Parse.setup — there is NO `master_key:` constructor argument.
#
# To scope retrieval to a signed-in user (so the bot only ever sees documents
# that user may read), construct it as:
#     Parse::Agent.new(session_token: user.session_token)
#
# `execute(:semantic_search, ...)` returns
#   { success:, data: { chunks:, documents:, count: } }.
def retrieve(agent, question, k: 4)
  result = agent.execute(:semantic_search,
                         class_name: "KnowledgeArticle",
                         query: question,
                         k: k)
  raise result[:error].to_s unless result[:success]

  # Each chunk: { id:, score:, content:, metadata: { object_id:, ... } }.
  # The parent record lives once in data[:documents], keyed by objectId.
  result[:data][:chunks]
end

# ---------------------------------------------------------------------------
# 5. Seed a corpus + chat loop (runs when executed directly)
# ---------------------------------------------------------------------------

CORPUS = [
  { title: "Resetting your password",
    body: "Open Settings, choose Security, then Reset Password. A link is emailed to you.",
    category: "account" },
  { title: "Exporting your data",
    body: "Use Settings > Export to download a ZIP of all your documents as JSON.",
    category: "data" },
  { title: "Billing cycles",
    body: "Plans renew monthly on the date you subscribed. Cancel anytime before renewal.",
    category: "billing" },
].freeze

# Bulk back-fill / precompute outside the managed-save path: call the provider
# directly. `embed_text_batched` splits into the provider's recommended batch
# size (OpenAI: 100) and returns one vector per string, in order. (Not used by
# the demo below — `save` handles embedding — but shown for completeness.)
def precompute_vectors(texts)
  provider = Parse::Embeddings.provider(:openai)
  provider.embed_text_batched(texts, input_type: :search_document)
end

def seed_corpus!
  # $vectorSearch needs an Atlas vector index on `embedding`, or retrieval
  # raises IndexNotResolved. The model declares it; apply it once. This uses
  # the mongo-direct writer (requires Parse::MongoDB configured against Atlas)
  # — or create the same index in the Atlas UI.
  KnowledgeArticle.apply_search_indexes!(wait: true)

  # Managed embedding means ingestion is just `save`: each save that changes a
  # source field makes one embedding call; unchanged re-saves make none.
  CORPUS.each { |attrs| KnowledgeArticle.new(attrs).save }
end

def chat_loop(backend: :anthropic)
  # Master posture (reads everything). Emits a one-time master-key warning to
  # stderr; silence it with Parse::Agent.suppress_master_key_warning = true.
  agent = Parse::Agent.new

  puts "Ask a question (Ctrl-D to quit):"
  while (question = $stdin.gets&.strip)
    next if question.empty?

    chunks = retrieve(agent, question)
    answer = ChatAnswerer.public_send(backend, question, chunks)

    puts "\n#{answer}\n"
    sources = chunks.map { |c| c.dig(:metadata, :object_id) }.uniq.join(", ")
    puts "  (sources: #{sources})\n\n"
  end
end

if __FILE__ == $PROGRAM_NAME
  seed_corpus!
  # Pick :openai or :anthropic for the generation step.
  chat_loop(backend: :anthropic)
end
