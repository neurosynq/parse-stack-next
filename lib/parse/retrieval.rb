# encoding: UTF-8
# frozen_string_literal: true

# Parse::Retrieval — retrieval-augmented-generation (RAG) helpers.
#
# Entry point that loads the chunker, the {Parse::Retrieval::Chunk}
# value object, and the {Parse::Retrieval.retrieve} core. The
# `semantic_search` agent tool (which depends on the agent layer) is
# loaded separately from `lib/parse/agent.rb`.
require_relative "retrieval/retriever"
