#!/usr/bin/env bash
# Tiny smoke test: build the shim, send one hello envelope, read the response.
#
# Requires a Bridge instance reachable at $CCPOCKET_BRIDGE_URL (default
# ws://localhost:8765). The script exits 0 if the shim emits a `result` envelope
# within 30 seconds, non-zero otherwise.

set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

OUT="${OUT:-/tmp/claude-shim}"
echo "building $OUT ..."
go build -o "$OUT" ./cmd/claude-shim

PROJECT_PATH="${PROJECT_PATH:-$PWD}"
INPUT='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello from smoke test"}]}}'

echo "running smoke test against ${CCPOCKET_BRIDGE_URL:-ws://localhost:8765}"
echo "$INPUT" | CCPOCKET_SHIM_LOG=debug timeout 30 "$OUT" \
  --output-format stream-json \
  --verbose \
  --input-format stream-json \
  --permission-mode bypassPermissions \
  --add-dir "$PROJECT_PATH"
