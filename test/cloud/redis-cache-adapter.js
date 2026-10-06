// Redis cache adapter for the integration test stack ONLY.
//
// Parse Server's default cache adapter is InMemoryCacheAdapter, which keeps
// the session/user/role caches inside the Node process where nothing outside
// the container can observe them. The SDK's Parse::Cache::UpstreamRoles is a
// read-only consumer of Parse Server's own `<appId>:role:<userId>` entries, so
// without a Redis-backed cache adapter there is nothing for it to read and the
// feature has unit coverage only.
//
// parse-server ships RedisCacheAdapter in core (lib/Adapters/Cache/
// RedisCacheAdapter.js) and bundles the `redis` npm package, so no extra
// dependency is required. It cannot be configured from a plain env var,
// though: `PARSE_SERVER_CACHE_ADAPTER` is parsed with `moduleOrObjectParser`
// and then handed to `loadAdapter`, which either requires a module path or
// takes an already-built object. This file is that module path. It is wired up
// by scripts/start-parse.sh, which exports
// PARSE_SERVER_CACHE_ADAPTER=/parse-server/cloud/redis-cache-adapter.js when
// PARSE_CACHE_REDIS_URL is present.
//
// CRITICAL: PARSE_CACHE_REDIS_URL must point at a DIFFERENT Redis database
// than the one the Ruby SDK caches into. RedisCacheAdapter#clear() issues a
// raw FLUSHDB, and Parse Server calls it on every _Role write. Sharing a
// database would let a single role write delete the SDK's cached responses and
// its `parse-stack:foc:v1:*` create-locks, silently removing first_or_create!
// mutual exclusion. See parse-community/parse-server#10617. The test stack
// puts the SDK on db 0 and Parse Server's cache on db 1 of the same Redis
// server, which is enough: FLUSHDB only clears the currently selected db.
//
// DO NOT copy this file into a deployed environment as-is. It logs its
// configuration to stdout and performs no authentication.

const CANDIDATE_PATHS = [
  "/parse-server/lib/Adapters/Cache/RedisCacheAdapter",
  "/usr/src/app/lib/Adapters/Cache/RedisCacheAdapter",
  "parse-server/lib/Adapters/Cache/RedisCacheAdapter",
];

function resolveRedisCacheAdapter() {
  const failures = [];
  for (const candidate of CANDIDATE_PATHS) {
    try {
      const mod = require(candidate);
      const Adapter = mod.RedisCacheAdapter || mod.default || mod;
      if (typeof Adapter === "function") {
        return Adapter;
      }
      failures.push(candidate + " (no constructor export)");
    } catch (err) {
      failures.push(candidate + " (" + err.message + ")");
    }
  }
  throw new Error(
    "[test-redis-cache-adapter] could not locate parse-server's RedisCacheAdapter. Tried: " +
      failures.join("; ")
  );
}

// Reject db 0. The SDK's own cache lives there in this stack, and the FLUSHDB
// described above would take it with it. Failing loudly at boot is far better
// than a test suite that intermittently loses its cache and its create-locks.
function assertDedicatedDatabase(url) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch (err) {
    throw new Error(
      "[test-redis-cache-adapter] PARSE_CACHE_REDIS_URL is not a valid URL: " + url
    );
  }
  const path = (parsed.pathname || "").replace(/^\//, "");
  const db = path === "" ? 0 : Number(path);
  if (!Number.isInteger(db) || db < 1) {
    throw new Error(
      "[test-redis-cache-adapter] refusing to start: PARSE_CACHE_REDIS_URL must select a " +
        "dedicated Redis database (db index >= 1), got " +
        JSON.stringify(url) +
        ". Parse Server FLUSHDBs its cache database on every _Role write, which would " +
        "destroy the SDK's response cache and its parse-stack:foc:v1:* create-locks on db 0."
    );
  }
  return db;
}

module.exports = function buildTestRedisCacheAdapter() {
  const url = process.env.PARSE_CACHE_REDIS_URL;
  if (!url) {
    throw new Error(
      "[test-redis-cache-adapter] PARSE_CACHE_REDIS_URL is not set. Either set it or " +
        "unset PARSE_SERVER_CACHE_ADAPTER so parse-server falls back to its in-memory cache."
    );
  }

  const db = assertDedicatedDatabase(url);
  const RedisCacheAdapter = resolveRedisCacheAdapter();

  // TTL in milliseconds. parse-server's own default is 30000; the SDK's
  // Parse::Cache::UpstreamRoles derives an entry's write time from what remains
  // of this TTL and rejects anything above DEFAULT_MAX_TTL_MS (60000), so keep
  // the two in agreement.
  const ttl = Number(process.env.PARSE_CACHE_REDIS_TTL_MS || 30000);

  console.log(
    "[test-redis-cache-adapter] Parse Server cache -> " +
      url.replace(/\/\/[^@]*@/, "//<redacted>@") +
      " (db " +
      db +
      ", ttl " +
      ttl +
      "ms)"
  );

  const ResilientAdapter = makeResilient(RedisCacheAdapter);
  return new ResilientAdapter({ url: url }, ttl);
};

// parse-server's RedisCacheAdapter catches errors in get() only. put(), del()
// and clear() return the redis client's promise directly, and its callers
// often do not await them. When the client is not open, which happens when an
// adapter instance is used before connect() (the LiveQuery server builds its
// own cache controller) or after the connection drops, those promises reject
// with "The client is closed". An unawaited rejection is an uncaught exception
// in Node, and it took the whole Parse Server down mid-suite during the 5.7.5
// integration run.
//
// The cache is an optimization, so a cache failure must never be fatal. This
// subclass (1) opens the client lazily before any command, sharing one
// in-flight connect() between concurrent callers, and (2) catches and logs
// every command failure, returning what a cache miss would. The db-1 guard
// above is unaffected: the URL is still validated before construction.
const CONNECT_TIMEOUT_MS = Number(process.env.PARSE_CACHE_REDIS_CONNECT_TIMEOUT_MS || 2000);

function makeResilient(RedisCacheAdapter) {
  return class ResilientRedisCacheAdapter extends RedisCacheAdapter {
    // Resolve once the client can serve commands. `isReady`, not `isOpen`:
    // while node-redis is reconnecting the client is already "open", and a
    // command sent then waits in the offline queue until the connection
    // returns, which against a dead Redis is forever.
    async ensureOpen() {
      if (this.client.isReady) {
        return;
      }
      if (!this.client.isOpen && !this.connecting) {
        this.connecting = Promise.resolve()
          .then(() => (this.client.isOpen ? undefined : this.client.connect()))
          .catch(() => undefined) // surfaced through the ready wait below
          .finally(() => {
            this.connecting = null;
          });
      }
      // Bound the wait and fall back to a cache miss. The connect keeps
      // retrying in the background, and later calls succeed once Redis is
      // back.
      let timer;
      let onReady;
      const ready = new Promise((resolve) => {
        onReady = resolve;
        this.client.once("ready", onReady);
      });
      const timeout = new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error("redis not ready after " + CONNECT_TIMEOUT_MS + "ms")),
          CONNECT_TIMEOUT_MS
        );
      });
      try {
        if (this.client.isReady) {
          return;
        }
        await Promise.race([ready, timeout]);
      } finally {
        clearTimeout(timer);
        this.client.removeListener("ready", onReady);
      }
    }

    async guarded(op, fallback, fn) {
      try {
        await this.ensureOpen();
        return await fn();
      } catch (err) {
        console.error(
          "[test-redis-cache-adapter] " + op + " failed; treating as a cache miss: " +
            (err && err.message ? err.message : String(err))
        );
        return fallback;
      }
    }

    async get(key) {
      return this.guarded("get", null, () => super.get(key));
    }

    async put(key, value, ttl) {
      return this.guarded("put", undefined, () =>
        ttl === undefined ? super.put(key, value) : super.put(key, value, ttl)
      );
    }

    async del(key) {
      return this.guarded("del", undefined, () => super.del(key));
    }

    async clear() {
      return this.guarded("clear", undefined, () => super.clear());
    }
  };
}
