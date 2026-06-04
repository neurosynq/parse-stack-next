// Atlas $vectorSearch index for vector_prototype.WikiArticle.
//
// Idempotent: drops any existing search indexes on the collection before
// creating the canonical one. Naming follows vector_rag_plan.md §3:
//
//   <table>_<field>_<provider>_<dimensions>_idx
//
// Reused by both Parse::VectorSearch tests (v4.3) and Parse::Retrieval
// tests (v4.4). The collection's data is loaded separately by
// fetch_embeddings.py.
//
// Run:
//   mongosh "mongodb://localhost:29020/vector_prototype?directConnection=true" \
//     scripts/vector_prototype/create_vector_index.js
//
// To switch to 1024-dim (voyage-multimodal-3 compat), set DIMS=1024
// before running. Mongosh exposes shell args via passthroughs only,
// so the value is read from an env shim or edit the constant below.

// Read the manifest written by fetch_embeddings.py so dims/provider/name
// can't drift from the loaded data. mongosh runs on Node, so use fs.
const fs = require("fs");
const path = require("path");
const _scriptDir = path.dirname(typeof __filename !== "undefined" ? __filename : process.argv[1] || ".");
const _manifestPath = path.join(_scriptDir, "fixture_manifest.json");
const MANIFEST = JSON.parse(fs.readFileSync(_manifestPath, "utf8"));

const COLL = MANIFEST.collection;
const DIMS = MANIFEST.dims;
const PROVIDER = MANIFEST.provider;
const INDEX_NAME = MANIFEST.index_name;

print(`[idx] target: ${db.getName()}.${COLL} → ${INDEX_NAME}`);

// Drop any stale search indexes so re-runs converge to a known state.
try {
  const existing = db[COLL].getSearchIndexes();
  existing.forEach(function (i) {
    print(`  drop existing index: ${i.name}`);
    db[COLL].dropSearchIndex(i.name);
  });
} catch (e) {
  print(`  (no existing indexes / error listing: ${e.message})`);
}
sleep(1000);

print(`[idx] creating ${INDEX_NAME} (vectorSearch, ${DIMS} dims, cosine)`);
db[COLL].createSearchIndex(INDEX_NAME, "vectorSearch", {
  fields: [
    {
      type: "vector",
      path: "embedding",
      numDimensions: DIMS,
      similarity: "cosine",
    },
    // Filter fields — declare here anything you want to use as a
    // $vectorSearch filter constraint. Atlas only accepts filter
    // predicates on fields declared as type:"filter" in the index.
    { type: "filter", path: "wiki_id" },
  ],
});

print("[idx] waiting for queryable...");
let attempts = 0;
const maxAttempts = 60;
while (attempts < maxAttempts) {
  const found = db[COLL].getSearchIndexes().find(function (i) {
    return i.name === INDEX_NAME;
  });
  if (found && found.queryable === true) {
    print(`[idx] ready after ${attempts * 2}s`);
    break;
  }
  sleep(2000);
  attempts++;
}
if (attempts >= maxAttempts) {
  print("[idx] WARNING: index not queryable yet; later queries may fail");
}

// Smoke-test: pick an arbitrary doc and find its top-5 neighbours.
print("\n[smoke] $vectorSearch self-similarity check");
const seed = db[COLL].findOne({});
if (!seed) {
  print("[smoke] no docs loaded — run fetch_embeddings.py first");
} else {
  const out = db[COLL].aggregate([
    {
      $vectorSearch: {
        index: INDEX_NAME,
        path: "embedding",
        queryVector: seed.embedding,
        numCandidates: 100,
        limit: 5,
      },
    },
    { $project: { _id: 1, title: 1, _vscore: { $meta: "vectorSearchScore" } } },
  ]).toArray();
  print(`  seed: ${seed.title}`);
  out.forEach(function (r, i) {
    print(`  ${i + 1}. score=${r._vscore.toFixed(4)}  ${r.title}`);
  });
}

print("\n[done]");
