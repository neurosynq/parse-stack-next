#!/bin/sh
set -e

# Parse Server startup script — TEST STACK ONLY.
#
# This script is bind-mounted into the parse-server container started by
# scripts/docker/docker-compose.test.yml for `rake test:integration`. It
# is NOT a template for production deployment.
#
# Required environment variables (provided by the test docker-compose
# via `${PARSE_APP_ID}`, `${PARSE_MASTER_KEY}`, … which themselves fall
# through to the compose's own defaults). The script aborts immediately
# if any required variable is missing — preventing a silent boot with
# placeholder credentials when an env-var name has drifted or a secret-
# manager binding fails.

echo "=== Parse Server Startup Script (test stack) ==="

# Hard-fail on any required env var being missing. The compose file
# is expected to supply each one via env interpolation; if it's not,
# we want a loud failure here rather than a silent boot with whatever
# default Parse Server itself would have applied.
require_env() {
  eval "value=\${$1:-}"
  if [ -z "$value" ]; then
    echo "[start-parse] Refusing to start: required environment variable $1 is not set." >&2
    exit 1
  fi
}

require_env PARSE_SERVER_APPLICATION_ID
require_env PARSE_SERVER_MASTER_KEY
require_env PARSE_SERVER_DATABASE_URI

# masterKeyIps restricts which client IPs are allowed to present the
# master key. Default to loopback only. To allow other ranges (e.g. a
# private VPC subnet hosting the Ruby app dynos), override before
# invoking this script:
#
#   PARSE_SERVER_MASTER_KEY_IPS="10.0.0.0/8,::1/128" ./start-parse.sh
#
# DO NOT set this to "0.0.0.0/0,::/0" in any environment reachable from
# the public internet. Doing so lets any caller that knows the master
# key bypass every ACL and CLP from any source IP.
export PARSE_SERVER_MASTER_KEY_IPS="${PARSE_SERVER_MASTER_KEY_IPS:-127.0.0.1/32,::1/128}"

# Optional REST API key — accept a default of empty when not provided
# by the compose file. Parse Server tolerates an unset REST key.
export PARSE_SERVER_REST_API_KEY="${PARSE_SERVER_REST_API_KEY:-}"
export PARSE_SERVER_MOUNT_PATH="${PARSE_SERVER_MOUNT_PATH:-/parse}"
export PARSE_SERVER_CLOUD="${PARSE_SERVER_CLOUD:-/parse-server/cloud/main.js}"
export PARSE_SERVER_LOG_LEVEL="${PARSE_SERVER_LOG_LEVEL:-info}"
export PARSE_SERVER_ALLOW_CLIENT_CLASS_CREATION="${PARSE_SERVER_ALLOW_CLIENT_CLASS_CREATION:-true}"
# Accept client-supplied objectId on create. Required by the
# `parse_reference precompute: true` DSL, which client-generates an
# objectId in a before_create callback and embeds it in the initial
# POST body. The SDK only forwards the client objectId when the save
# runs with master-key authority; the server flag is global, so any
# additional non-master client-objectId enforcement must be applied
# in cloud code (see lib/parse/model/core/parse_reference.rb).
export PARSE_SERVER_ALLOW_CUSTOM_OBJECT_ID="${PARSE_SERVER_ALLOW_CUSTOM_OBJECT_ID:-true}"

# LiveQuery configuration via environment variables
export PARSE_SERVER_LIVE_QUERY="${PARSE_SERVER_LIVE_QUERY:-{\"classNames\":[\"Song\",\"Album\",\"User\",\"_User\",\"TestLiveQuery\"]}}"
export PARSE_SERVER_START_LIVE_QUERY_SERVER="${PARSE_SERVER_START_LIVE_QUERY_SERVER:-true}"

# File upload — test-stack only. Authenticated session-token uploads are
# permitted; public/anonymous uploads are NOT (mirrors a typical hardened
# Parse Server config). The client_rest_files integration tests assert
# both pathways: authed upload succeeds, anon upload is rejected.
export PARSE_SERVER_FILE_UPLOAD="${PARSE_SERVER_FILE_UPLOAD:-{\"enableForPublic\":false,\"enableForAnonymousUser\":false,\"enableForAuthenticatedUser\":true}}"

# Request-id idempotency — test-stack only, scoped to a single probe class so
# it deduplicates ONLY writes the request-id integration test targets and has
# zero effect on every other suite. Parse Server dedups POST/PUT carrying the
# same X-Parse-Request-Id within the TTL for paths matching `paths` (regex).
# The SDK's idempotent-retry feature relies on exactly this server-side dedup
# when `Parse::Request.assume_server_idempotency = true`. NOTE: Parse Server
# names this env var with an `EXPERIMENTAL_` infix and treats the value as a
# JSON object (objectParser). Override the whole JSON to widen coverage.
export PARSE_SERVER_EXPERIMENTAL_IDEMPOTENCY_OPTIONS="${PARSE_SERVER_EXPERIMENTAL_IDEMPOTENCY_OPTIONS:-{\"paths\":[\"classes/IdempotencyProbe\"],\"ttl\":120}}"

echo "Environment configured:"
echo "  PARSE_SERVER_APPLICATION_ID: $PARSE_SERVER_APPLICATION_ID"
echo "  PARSE_SERVER_LIVE_QUERY: $PARSE_SERVER_LIVE_QUERY"
echo "  PARSE_SERVER_START_LIVE_QUERY_SERVER: $PARSE_SERVER_START_LIVE_QUERY_SERVER"

# Start Parse Server
echo "Starting Parse Server..."
echo "PATH: $PATH"
echo "Looking for parse-server..."
which node
ls -la /parse-server/

# Try different ways to start parse-server
if [ -f "/parse-server/bin/parse-server" ]; then
  echo "Using /parse-server/bin/parse-server"
  exec /parse-server/bin/parse-server
elif [ -f "/usr/src/app/bin/parse-server" ]; then
  echo "Using /usr/src/app/bin/parse-server"
  exec /usr/src/app/bin/parse-server
else
  echo "Trying with node and index.js"
  cd /parse-server
  exec node ./bin/parse-server
fi
