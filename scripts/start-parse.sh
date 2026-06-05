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

# Push configuration — test-stack only. Points at a no-op adapter bind-mounted
# from test/cloud (see test/cloud/dummy-push-adapter.js). It does NOT deliver to
# any real device gateway; it lets Parse Server accept `POST /parse/push` and
# create/complete a real `_PushStatus` so the push send+status lifecycle is
# integration-testable offline. Without this, `POST /push` returns code 115
# "Missing push configuration". DO NOT use a no-op adapter in a deployed
# environment — it silently drops every notification.
export PARSE_SERVER_PUSH="${PARSE_SERVER_PUSH:-{\"adapter\":\"/parse-server/cloud/dummy-push-adapter.js\"}}"

# MFA / 2FA configuration — test-stack only. Enables Parse Server's built-in
# TOTP MFA adapter so the Parse::MFA / two_factor_auth integration tests can
# enroll a user (authData.mfa.{secret,token}) and log in with a time-based code.
# Params match rotp's defaults (SHA1 / 6 digits / 30s period) so codes generated
# client-side validate server-side.
#
# NOTE: the `auth` option is the one Parse Server option that CANNOT be passed
# as a JSON env var — its Definitions entry has no objectParser, so
# PARSE_SERVER_AUTH_PROVIDERS is taken as a raw string and never JSON-parsed
# (the MFA adapter then receives `undefined` options and 500s). It must come
# from a config file, which parse-server JSON-parses natively. We write a
# minimal config file holding only the `auth` block and pass it to parse-server
# below; env vars still provide — and take precedence for — everything else
# (parse-server applies env first, then fills gaps from the file).
PARSE_AUTH_CONFIG_FILE="${PARSE_AUTH_CONFIG_FILE:-/tmp/psnext-parse-auth-config.json}"
cat > "$PARSE_AUTH_CONFIG_FILE" <<'AUTHCFG'
{ "auth": { "mfa": { "options": ["TOTP"], "digits": 6, "period": 30, "algorithm": "SHA1" } } }
AUTHCFG

# Email — test-stack only. Captures outgoing mail into an `EmailCapture` class
# (see test/cloud/capturing-email-adapter.js) instead of sending it, so the
# client-side password-reset / verification integration tests can assert
# delivery and read back the reset link. `PARSE_PUBLIC_SERVER_URL` is required
# for Parse Server to build those links. Email verification is NOT enabled, so
# ordinary signups still work without a verification round-trip. DO NOT use a
# capturing adapter in a deployed environment — it drops every email.
export PARSE_SERVER_EMAIL_ADAPTER="${PARSE_SERVER_EMAIL_ADAPTER:-/parse-server/cloud/capturing-email-adapter.js}"
export PARSE_PUBLIC_SERVER_URL="${PARSE_PUBLIC_SERVER_URL:-http://localhost:${PARSE_HOST_PORT:-29337}/parse}"
export PARSE_SERVER_APP_NAME="${PARSE_SERVER_APP_NAME:-parse-stack-next-it}"
# Keep email verification OFF. Configuring an email adapter otherwise flips
# Parse Server into requiring verification, which makes signup return a user
# with NO session token until the address is verified — breaking the
# signup-on-save suite. Password reset does not need verification, only the
# adapter + public URL above.
export PARSE_SERVER_VERIFY_USER_EMAILS="${PARSE_SERVER_VERIFY_USER_EMAILS:-false}"
export PARSE_SERVER_PREVENT_LOGIN_WITH_UNVERIFIED_EMAIL="${PARSE_SERVER_PREVENT_LOGIN_WITH_UNVERIFIED_EMAIL:-false}"

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

# Try different ways to start parse-server. The config file argument supplies
# the `auth` (MFA) block; every other option still comes from the environment.
echo "  Auth config file: $PARSE_AUTH_CONFIG_FILE"
if [ -f "/parse-server/bin/parse-server" ]; then
  echo "Using /parse-server/bin/parse-server"
  exec /parse-server/bin/parse-server "$PARSE_AUTH_CONFIG_FILE"
elif [ -f "/usr/src/app/bin/parse-server" ]; then
  echo "Using /usr/src/app/bin/parse-server"
  exec /usr/src/app/bin/parse-server "$PARSE_AUTH_CONFIG_FILE"
else
  echo "Trying with node and index.js"
  cd /parse-server
  exec node ./bin/parse-server "$PARSE_AUTH_CONFIG_FILE"
fi
