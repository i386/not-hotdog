#!/usr/bin/env bash
# Build the Foundation-only wire client with swiftc and run it against the
# contract stubs. Kills only the PIDs it started. Run from the repo root:
#   backend/run_smoke.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT=".scratch/smoke"
mkdir -p "$OUT"

echo "== swiftc compile (wire client + smoke driver) =="
swiftc -O \
  SeeFood/SeeFood/WireModels.swift \
  SeeFood/SeeFood/OpenJEVClient.swift \
  backend/main.swift \
  -o "$OUT/smoke"
echo "compile OK"

echo "== start stubs =="
SEEFOOD_STUB_PROFILE=upstream SEEFOOD_STUB_PORT=8091 python3 backend/stub_server.py >"$OUT/stub-upstream.log" 2>&1 &
UP_PID=$!
SEEFOOD_STUB_PROFILE=mesh SEEFOOD_STUB_PORT=8092 python3 backend/stub_server.py >"$OUT/stub-mesh.log" 2>&1 &
MESH_PID=$!
cleanup() {
  for pid in "$UP_PID" "$MESH_PID"; do
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  done
}
trap cleanup EXIT

for i in $(seq 1 20); do
  if curl -s -o /dev/null "http://127.0.0.1:8091" && curl -s -o /dev/null "http://127.0.0.1:8092"; then break; fi
  sleep 0.25
done

echo "== scenario 1: auto vs upstream (direct image read) =="
"$OUT/smoke" http://127.0.0.1:8091 direct upstream-auto
echo "== scenario 2: auto vs mesh PoC (501 images -> caption fallback) =="
"$OUT/smoke" http://127.0.0.1:8092 mesh mesh-poc-fallback
echo "== scenario 3: mesh path, salad caption -> NOT HOTDOG =="
"$OUT/smoke" http://127.0.0.1:8092 mesh-salad mesh-salad
echo "== scenario 4: direct pinned vs mesh PoC -> clean imagesUnsupported =="
"$OUT/smoke" http://127.0.0.1:8092 error-images direct-rejection

echo "== request logs (evidence) =="
cat "$OUT/stub-upstream.log" "$OUT/stub-mesh.log"
echo "ALL SCENARIOS DONE"
