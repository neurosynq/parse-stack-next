# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # RFC 5424 severities used by MCP logging, least to most severe. Shared
    # by {Parse::Agent#log} and {Parse::Agent::MCPDispatcher} so a level is
    # validated the same way whether or not a transport is attached.
    LOG_LEVELS = %w[debug info notice warning error critical alert emergency].freeze
  end
end
