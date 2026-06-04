#!/usr/bin/env bash
# Orchestrate the vector-search / RAG test fixture setup.
# Assumes the Atlas Local container from docker-compose.atlas.yml is up
# (i.e. localhost:29020 is reachable).
#
# Usage:  ./scripts/vector_prototype/run.sh
#
# Once this stabilises, the fetch + index-create steps will be folded
# into scripts/docker/docker-compose.atlas.yml as additional init
# containers, alongside the existing atlas-init service.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "[1/3] verifying Atlas Local on localhost:29020"
if ! mongosh --quiet --eval "db.runCommand({ ping: 1 })" \
     "mongodb://localhost:29020/?directConnection=true" >/dev/null; then
  echo "  ERROR: Atlas Local not reachable. Start it with:"
  echo "    docker-compose -f scripts/docker/docker-compose.atlas.yml up -d"
  exit 1
fi
echo "  ok"

echo "[2/3] downloading + loading embeddings"
python3 "$HERE/fetch_embeddings.py"

echo "[3/3] creating vectorSearch index"
mongosh --quiet "mongodb://localhost:29020/vector_prototype?directConnection=true" \
  "$HERE/create_vector_index.js"

echo
echo "Done. Run the Ruby query exercise with:"
echo "  bundle exec ruby scripts/vector_prototype/query_prototype.rb"
