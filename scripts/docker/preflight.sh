#!/bin/sh
# Preflight guard for the integration stack — TEST STACK ONLY.
#
# The Compose defaults bind every service to loopback (127.0.0.1) and fall
# back to KNOWN, COMMITTED test credentials (master key psnextItMasterKey,
# Mongo root admin:password, Dashboard admin:admin). That combination is
# safe on loopback — nothing on the LAN can reach it.
#
# It is NOT safe the moment a developer overrides a `*_BIND` to a
# non-loopback address (e.g. MONGO_BIND=0.0.0.0 to attach a remote client):
# the stack is then reachable from the LAN while protected only by
# credentials that are published in this very repository. An admin-
# credentialed Mongo / Parse master key exposed to a shared network is a
# real footgun, and the failure is silent — `docker compose up` just works
# and the developer never sees it.
#
# This guard runs first (every other service gates on it via
# `service_completed_successfully`) and FAILS THE STACK CLOSED whenever a
# non-loopback bind is combined with still-default privileged credentials.
# It is invisible to the normal loopback run.
#
# Escape hatches (pick one):
#   1. Keep it loopback     — unset the *_BIND override (the default).
#   2. Use real secrets     — set PARSE_MASTER_KEY and MONGO_ROOT_PASSWORD
#                             (inject them with `op run` / `doppler run` —
#                             see the README "Secret injection" recipe).
#   3. Acknowledge the risk — ALLOW_INSECURE_BIND=1 on a trusted/isolated
#                             network where exposure is intentional.

set -eu

# Treat an empty value as loopback: the compose interpolation passes the
# resolved bind, and an unset override resolves to the 127.0.0.1 default.
is_loopback() {
  case "$1" in
    "" | 127.0.0.1 | ::1 | localhost) return 0 ;;
    *) return 1 ;;
  esac
}

exposed=""
for pair in "PARSE_BIND=${PARSE_BIND:-}" "MONGO_BIND=${MONGO_BIND:-}" \
            "REDIS_BIND=${REDIS_BIND:-}" "DASHBOARD_BIND=${DASHBOARD_BIND:-}"; do
  val=${pair#*=}
  is_loopback "$val" || exposed="$exposed ${pair%%=*}=$val"
done

# Privileged credentials are "default" unless BOTH have been overridden.
# *_SET is "1" only when Compose interpolated a non-empty override
# (`${VAR:+1}`); empty means the committed default is in force.
if [ -n "${PARSE_MASTER_KEY_SET:-}" ] && [ -n "${MONGO_ROOT_PASSWORD_SET:-}" ]; then
  default_creds=0
else
  default_creds=1
fi

if [ -n "$exposed" ] && [ "$default_creds" = "1" ] && [ "${ALLOW_INSECURE_BIND:-}" != "1" ]; then
  echo "[preflight] REFUSING TO START — non-loopback bind with default credentials." >&2
  echo "[preflight]" >&2
  echo "[preflight] Exposed (non-loopback) bind(s):$exposed" >&2
  echo "[preflight] ...while still using the committed test credentials" >&2
  echo "[preflight] (master key psnextItMasterKey / Mongo admin:password)." >&2
  echo "[preflight] This publishes an admin-credentialed stack onto your LAN." >&2
  echo "[preflight]" >&2
  echo "[preflight] Resolve ONE of:" >&2
  echo "[preflight]   1. Keep it loopback   — unset the *_BIND override." >&2
  echo "[preflight]   2. Set real secrets   — PARSE_MASTER_KEY=... MONGO_ROOT_PASSWORD=..." >&2
  echo "[preflight]   3. Acknowledge intent — ALLOW_INSECURE_BIND=1 (trusted network only)." >&2
  exit 1
fi

if [ -n "$exposed" ]; then
  echo "[preflight] OK — non-loopback bind(s)$exposed permitted (credentials overridden or ALLOW_INSECURE_BIND=1)."
else
  echo "[preflight] OK — all services bound to loopback."
fi
