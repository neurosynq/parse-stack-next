# Parse Stack Test Server Setup

This document explains how to run the local, isolated Parse Server stack used
to exercise the parse-stack-next Ruby SDK's integration suite.

The stack is namespaced so it never collides with another Parse test system on
the same machine: a dedicated Compose project, a private `29xxx` host-port
block, dedicated container/volume names (`psnext-it-*`), loopback-only port
binds by default, and a dedicated database.

## Quick Start

### Option 1: Using Make

```bash
make test-server-start   # bring up the stack
make test-connection     # verify connectivity
make test-integration    # run the integration suite
make test-server-stop    # tear the stack down
```

### Option 2: Docker Compose directly

```bash
# Start
docker-compose -f scripts/docker/docker-compose.test.yml up -d

# Verify Parse Server is healthy
curl http://localhost:29337/parse/health   # => {"status":"ok"}

# Run integration tests
PARSE_TEST_USE_DOCKER=true bundle exec rake test:integration

# Stop
docker-compose -f scripts/docker/docker-compose.test.yml down
```

### Option 3: Use your own Parse Server

Point the suite at any Parse Server by exporting the client-side variables:

```bash
export PARSE_TEST_SERVER_URL="http://your-server:1337/parse"
export PARSE_TEST_APP_ID="your-app-id"
export PARSE_TEST_API_KEY="your-rest-key"
export PARSE_TEST_MASTER_KEY="your-master-key"
```

## Services and ports

Every value has a baked-in default, so the stack is isolated even with no env
file present. Host ports live in the `29xxx` block and bind to `127.0.0.1` by
default.

| Service         | Host port | Override            | Container             |
|-----------------|-----------|---------------------|-----------------------|
| Parse Server    | 29337     | `PARSE_HOST_PORT`   | `psnext-it-server`    |
| MongoDB         | 29017     | `MONGO_HOST_PORT`   | `psnext-it-mongo`     |
| Redis           | 29379     | `REDIS_HOST_PORT`   | `psnext-it-redis`     |
| Parse Dashboard | 29040     | `DASHBOARD_HOST_PORT` | `psnext-it-dashboard` |

- **`PSNEXT_PREFIX`** (default `psnext-it`) names the Compose project and every
  container. Set it (e.g. `PSNEXT_PREFIX=psnext-ci`) to run a second, fully
  separate copy.
- **Versions**: Parse Server is pinned to `parseplatform/parse-server:9.9.0`
  (see `scripts/docker/Dockerfile.parse`), MongoDB `mongo:8`, Redis
  `redis:7-alpine`, Dashboard `parseplatform/parse-dashboard:9`.
- **Database**: Parse uses `parse_stack_next_it`.

## Credentials (compose defaults)

| Setting     | Default             | Compose env             |
|-------------|---------------------|-------------------------|
| App ID      | `psnextItAppId`     | `PARSE_APP_ID`          |
| Master key  | `psnextItMasterKey` | `PARSE_MASTER_KEY`      |
| REST key    | `psnext-it-rest-key`| `PARSE_API_KEY`         |

These defaults are intentionally non-secret — they only ever bind to loopback.
Supply real values (and non-loopback binds) via your shell or a secret manager
if you point the stack at anything shared.

## Security posture (not an anti-pattern)

The stack is hardened by construction, not opened up:

- **Loopback binds by default** — `PARSE_BIND` / `MONGO_BIND` / `REDIS_BIND` /
  `DASHBOARD_BIND` all default to `127.0.0.1`, so nothing is published on the
  LAN unless you explicitly override a bind.
- **Scoped master-key IPs** — Parse Server's `masterKeyIps` is set to loopback
  plus the private Docker ranges
  (`127.0.0.1/32,::1/128,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8`) so the
  Ruby suite and the Dashboard container can use the master key, but it is
  **not** opened to `0.0.0.0/0`.
- **Preflight guard** — a `preflight` service (`scripts/docker/preflight.sh`)
  gates startup and refuses to bring the stack up on a non-loopback bind while
  still using the default credentials, unless `ALLOW_INSECURE_BIND=1` or real
  `PARSE_MASTER_KEY` / `MONGO_ROOT_PASSWORD` values are supplied.

## Client-side test variables

The Ruby suite reads these (all have `29xxx` / `psnext-it` defaults):

| Variable                 | Purpose                              |
|--------------------------|--------------------------------------|
| `PARSE_TEST_SERVER_URL`  | Parse Server URL (`http://localhost:29337/parse`) |
| `PARSE_TEST_APP_ID`      | Application ID                       |
| `PARSE_TEST_API_KEY`     | REST API key                         |
| `PARSE_TEST_MASTER_KEY`  | Master key                           |
| `PARSE_TEST_MONGO_URI`   | Mongo URI for mongo-direct tests     |
| `PARSE_TEST_REDIS_URL`   | Redis URL                            |
| `PARSE_TEST_LIVE_QUERY_URL` | LiveQuery WebSocket URL           |
| `PARSE_TEST_USE_DOCKER`  | Auto-manage the Docker stack         |

`.env.test` is a committed reference listing the whole set;
`set -a; source .env.test; set +a` loads them all at once. Nothing auto-loads
it — the baked-in defaults apply otherwise.

## Dashboard

With the stack up, the Parse Dashboard is at <http://localhost:29040>.

## Troubleshooting

```bash
# Container status
docker-compose -f scripts/docker/docker-compose.test.yml ps

# Parse Server logs
docker logs psnext-it-server

# Full reset (clears volumes)
docker-compose -f scripts/docker/docker-compose.test.yml down -v
docker-compose -f scripts/docker/docker-compose.test.yml up -d
```

### Master-key IP rejection

If you see `Request using master key rejected as the request IP address ... is
not set in Parse Server option 'masterKeyIps'`, your client is reaching the
server from an address outside the scoped `masterKeyIps` list above. Run the
suite from the host (loopback) or from within the Docker network, rather than
widening `masterKeyIps`.

### Port conflicts

Every host port is overridable via the `*_HOST_PORT` variables in the table
above (and the matching `PARSE_TEST_*` client variable). Move both the compose
side and the client side together so the containers and the suite agree.
