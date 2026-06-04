#!/usr/bin/env python3
"""
Vector-search & RAG test fixture loader.

Pulls a subset of a pre-computed embeddings dataset from HuggingFace and
loads it into Atlas Local at localhost:29020 (the same container managed
by scripts/docker/docker-compose.atlas.yml). Designed to be reused by both:

  1. Vector search integration tests (Parse::VectorSearch — v4.3 plan)
  2. RAG retrieval tests (Parse::Retrieval — v4.4 plan)

The Wikipedia article shape (title + full text + url + embedding) covers
both surfaces: vector tests need (title, embedding), RAG/chunking tests
need the full text body.

The runtime target is voyage-multimodal-3 (1024-dim) — the production
preference. The fixture data is provider-agnostic: any pre-computed
embeddings exercise the same Atlas $vectorSearch surface, since the
index contract is (path, dims, similarity) — provider is metadata.

Two presets:

  PRESET=fast (default) — Cohere/wikipedia-22-12-simple-embeddings
    768-dim, ~13MB shards, ~485k rows total. Quick to download.
    Use when iterating on pipeline mechanics, not Voyage-shape parity.

  PRESET=voyage_compat — Cohere/wikipedia-2023-11-embed-multilingual-v3
    1024-dim (matches voyage-multimodal-3), ~1.5GB shards.
    Use when the index/query surface needs to be Voyage-dimension-shaped
    even though vectors come from Cohere. Vectors are NOT interchangeable
    with Voyage outputs — same dim, different latent space — but the
    SDK pipeline mechanics are validated correctly.

For actual Voyage-vector parity at test time, compute query vectors via
the Voyage API into the same 1024-dim index (no local-inference path
exists — Voyage models are closed-weights, API-only).

Prereqs:  pip install pyarrow pymongo requests

Run:      python3 scripts/vector_prototype/fetch_embeddings.py
"""

import os
import sys
import datetime
import requests
import pyarrow.parquet as pq
from pymongo import MongoClient

PRESETS = {
    "fast": {
        # MongoDB's reference dataset for Atlas Vector Search demos.
        # ~3500 movies × 1536-dim OpenAI ada-002 plot embeddings.
        # Public, ~42MB, single JSON file. Format: array of objects with
        # plot_embedding field.
        "url": "https://huggingface.co/datasets/MongoDB/embedded_movies/resolve/main/sample_mflix.embedded_movies.json",
        "dims": 1536,
        "provider": "openai-text-embedding-ada-002",
        "format": "json",
        "embedding_field": "plot_embedding",
        "id_field": None,  # MongoDB will auto-assign or we synthesize
    },
    "voyage_compat": {
        # 1024-dim matches voyage-multimodal-3 — same index shape, different
        # latent space. Vectors NOT mixable with Voyage outputs at query time.
        # NOTE: requires an authenticated HuggingFace download
        # (HF_TOKEN env var or `huggingface-cli login`). The Cohere wikipedia
        # v3 dataset is gated since late 2024.
        "url": "https://huggingface.co/datasets/Cohere/wikipedia-2023-11-embed-multilingual-v3/resolve/main/en/0000.parquet",
        "dims": 1024,
        "provider": "cohere-embed-multilingual-v3",
        "format": "parquet",
        "embedding_field": "emb",
        "id_field": "id",
    },
}

PRESET = os.environ.get("PRESET", "fast")
if PRESET not in PRESETS:
    print(f"[err] unknown PRESET={PRESET}; choose one of: {list(PRESETS)}", file=sys.stderr)
    sys.exit(2)

_p = PRESETS[PRESET]
DATASET_URL = os.environ.get("DATASET_URL", _p["url"])
DIMS_EXPECTED = int(os.environ.get("DIMS_EXPECTED", _p["dims"]))
PROVIDER_LABEL = os.environ.get("PROVIDER_LABEL", _p["provider"])
DATA_FORMAT = _p["format"]
EMBEDDING_FIELD = _p["embedding_field"]
ID_FIELD = _p["id_field"]

_ext = "parquet" if DATA_FORMAT == "parquet" else "json"
LOCAL_FILE = os.environ.get("LOCAL_FILE", f"/tmp/parse-stack-fixture-{PRESET}.{_ext}")
MONGO_URI = os.environ.get("ATLAS_URI", "mongodb://localhost:29020/?directConnection=true")
DB_NAME = os.environ.get("DB_NAME", "vector_prototype")
# Collection name mirrors the dataset shape so RAG tests can pivot
# without coupling test assertions to a hard-coded class name.
DEFAULT_COLL = "Movie" if PRESET == "fast" else "WikiArticle"
COLL_NAME = os.environ.get("COLL_NAME", DEFAULT_COLL)
LIMIT = int(os.environ.get("LIMIT", "10000"))

print(f"[preset] {PRESET}  provider={PROVIDER_LABEL}  dims={DIMS_EXPECTED}")


def download():
    if os.path.exists(LOCAL_FILE) and os.path.getsize(LOCAL_FILE) > 0:
        print(f"[skip] {LOCAL_FILE} already present ({os.path.getsize(LOCAL_FILE)} bytes)")
        return
    headers = {}
    token = os.environ.get("HF_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    print(f"[download] {DATASET_URL}")
    with requests.get(DATASET_URL, stream=True, timeout=120, headers=headers) as r:
        if r.status_code == 401:
            print(
                f"[err] HTTP 401 — dataset requires authentication. "
                f"Set HF_TOKEN env var (huggingface.co token) or pick a different PRESET.",
                file=sys.stderr,
            )
            sys.exit(2)
        r.raise_for_status()
        total = int(r.headers.get("content-length", 0))
        written = 0
        with open(LOCAL_FILE, "wb") as f:
            for chunk in r.iter_content(chunk_size=1024 * 1024):
                f.write(chunk)
                written += len(chunk)
                if total:
                    pct = 100 * written / total
                    print(f"  {written // (1024*1024)}MB / {total // (1024*1024)}MB ({pct:.1f}%)", end="\r")
        print()
    print(f"[download] wrote {LOCAL_FILE}")


def _read_rows():
    if DATA_FORMAT == "parquet":
        print(f"[read] parquet {LOCAL_FILE}")
        table = pq.read_table(LOCAL_FILE)
        print(f"[read] rows={table.num_rows} columns={table.column_names}")
        return table.to_pylist()
    elif DATA_FORMAT == "json":
        print(f"[read] json {LOCAL_FILE}")
        import json as _json
        with open(LOCAL_FILE, "r") as f:
            data = _json.load(f)
        # embedded_movies is a top-level array
        if not isinstance(data, list):
            print(f"[err] expected top-level JSON array, got {type(data).__name__}", file=sys.stderr)
            sys.exit(1)
        print(f"[read] rows={len(data)}")
        if data:
            print(f"[read] sample keys: {list(data[0].keys())[:10]}")
        return data
    else:
        print(f"[err] unknown DATA_FORMAT={DATA_FORMAT}", file=sys.stderr)
        sys.exit(1)


def load():
    rows = _read_rows()
    if LIMIT > 0:
        rows = rows[:LIMIT]
    if not rows:
        print("[err] no rows", file=sys.stderr)
        sys.exit(1)

    # Find the first row that actually has an embedding (some datasets,
    # including embedded_movies, have null embeddings for entries with
    # missing plot text).
    sample = next((r for r in rows if r.get(EMBEDDING_FIELD)), None)
    if sample is None:
        print(f"[err] no rows have field '{EMBEDDING_FIELD}'; sample keys: {list(rows[0].keys())}", file=sys.stderr)
        sys.exit(1)
    dims = len(sample[EMBEDDING_FIELD])
    print(f"[verify] embedding field='{EMBEDDING_FIELD}'  dims={dims}")
    if dims != DIMS_EXPECTED:
        print(
            f"[warn] dims={dims} differs from preset DIMS_EXPECTED={DIMS_EXPECTED}; "
            f"manifest will record the actual dims",
            file=sys.stderr,
        )

    now = datetime.datetime.utcnow()
    docs = []
    skipped = 0
    for idx, r in enumerate(rows):
        emb = r.get(EMBEDDING_FIELD)
        if not emb or len(emb) != dims:
            skipped += 1
            continue
        # Carry through dataset fields (text/title/etc.) so RAG/chunker
        # tests have real content. Source fields go first; our canonical
        # fields win.
        doc = {k: v for k, v in r.items() if k != EMBEDDING_FIELD}
        doc["embedding"] = list(emb)
        doc["_created_at"] = now
        doc["_updated_at"] = now
        if ID_FIELD and r.get(ID_FIELD) is not None:
            doc["_id"] = f"{COLL_NAME.lower()}_{r[ID_FIELD]}"
        else:
            doc["_id"] = f"{COLL_NAME.lower()}_{idx:06d}"
        docs.append(doc)

    if skipped:
        print(f"[load] skipped {skipped} rows missing/short embeddings")

    client = MongoClient(MONGO_URI)
    coll = client[DB_NAME][COLL_NAME]
    print(f"[mongo] dropping {DB_NAME}.{COLL_NAME}")
    coll.drop()

    # Bulk insert in chunks — pymongo's default is fine but explicit is clearer
    BATCH = 1000
    for i in range(0, len(docs), BATCH):
        coll.insert_many(docs[i:i + BATCH], ordered=False)
        print(f"  inserted {min(i + BATCH, len(docs))}/{len(docs)}")

    count = coll.count_documents({})
    print(f"[mongo] {DB_NAME}.{COLL_NAME} now has {count} docs (embedding dims={dims})")

    # Manifest — single source of truth shared with create_vector_index.js
    # so the index name + dimensions can never drift from the loaded data.
    import json
    manifest = {
        "preset": PRESET,
        "provider": PROVIDER_LABEL,
        "dims": dims,
        "db": DB_NAME,
        "collection": COLL_NAME,
        "count": count,
        "index_name": f"{COLL_NAME}_embedding_{PROVIDER_LABEL.replace('-', '_')}_{dims}_idx",
    }
    manifest_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixture_manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"[manifest] wrote {manifest_path}: {manifest['index_name']}")


if __name__ == "__main__":
    download()
    load()
