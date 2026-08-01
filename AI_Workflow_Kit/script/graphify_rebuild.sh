#!/usr/bin/env bash
# graphify_rebuild.sh — rebuild DialGent knowledge graph for agent token savings
#
# Role: Dev-workflow tool (not product DialGent M2). Agents prefer
#   graphify query / explain / path  over dumping whole trees.
#
# Usage (from DialGent product root):
#   ./AI_Workflow_Kit/script/graphify_rebuild.sh
#   ./AI_Workflow_Kit/script/graphify_rebuild.sh --force
#
# Requires: `graphify` on PATH (https://github.com/safishamsi/graphify)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_DIR="$PRODUCT_ROOT/graphify-out"

cd "$PRODUCT_ROOT"

if ! command -v graphify &>/dev/null; then
  echo "ERROR: graphify not on PATH." >&2
  echo "Install: uv tool install graphifyy   # package name may vary" >&2
  echo "Or: pipx install graphify / follow upstream docs." >&2
  exit 1
fi

EXTRA_ARGS=(--no-cluster)
if [[ "${1:-}" == "--force" ]] || [[ "${GRAPHIFY_FORCE:-}" == "1" ]]; then
  EXTRA_ARGS+=(--force)
fi

echo "Rebuilding knowledge graph for: $PRODUCT_ROOT"
echo "Output: $OUT_DIR"

# Code + kit docs; skip heavy/reference blobs via focusing paths when present.
# graphify update walks the given root; we pass product root and rely on
# typical ignores. Force after large refactors.
mkdir -p "$OUT_DIR"

# Prefer product sources first for a denser graph if multi-root not needed:
# update whole product so ARCHITECTURE + backend + frontend share one graph.
graphify update "$PRODUCT_ROOT" "${EXTRA_ARGS[@]}"

# Optional clustering / HTML can be slow; enable when graph is stable:
# graphify cluster-only "$PRODUCT_ROOT" --no-viz

if [[ -f "$OUT_DIR/graph.json" ]]; then
  NODES=$(python3 -c "import json; g=json.load(open('$OUT_DIR/graph.json')); print(len(g.get('nodes', g if isinstance(g,list) else [])))" 2>/dev/null || echo "?")
  echo "OK: graphify-out/graph.json ready (nodes≈$NODES)"
  echo "Query examples:"
  echo "  graphify explain \"EventLogStore\" --graph graphify-out/graph.json"
  echo "  graphify path \"OrchestratorAutomaton\" \"EventLogStore\" --graph graphify-out/graph.json"
else
  echo "WARN: graph.json not found after update — check graphify output above." >&2
  exit 1
fi
