#!/usr/bin/env bash
# cline_graphify_mcp.sh — wire Graphify as an MCP server for Cline CLI/IDE
#
# Agents building DialGent should see Graphify tools (query/path/explain)
# via MCP, not only via shell CLI.
#
# Usage:
#   ./AI_Workflow_Kit/script/cline_graphify_mcp.sh          # write MCP config
#   ./AI_Workflow_Kit/script/cline_graphify_mcp.sh --rebuild  # also refresh graph
#   ./AI_Workflow_Kit/script/cline_graphify_mcp.sh --status   # show config paths
#
# After running: fully quit and restart Cline CLI so MCP reloads.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GRAPH_JSON="$PRODUCT_ROOT/graphify-out/graph.json"
GRAPHIFY_PY="${GRAPHIFY_PY:-$HOME/.local/share/uv/tools/graphifyy/bin/python}"
CLINE_SETTINGS="$HOME/.cline/data/settings/cline_mcp_settings.json"
CLINE_MCP_JSON="$HOME/.cline/mcp.json"

cmd_status() {
  echo "Product root:  $PRODUCT_ROOT"
  echo "Graph JSON:    $GRAPH_JSON ($( [[ -f "$GRAPH_JSON" ]] && echo OK || echo MISSING ))"
  echo "Graphify py:   $GRAPHIFY_PY ($( [[ -x "$GRAPHIFY_PY" ]] && echo OK || echo MISSING ))"
  echo "Cline settings:$CLINE_SETTINGS ($( [[ -f "$CLINE_SETTINGS" ]] && echo present || echo absent ))"
  echo "Cline mcp.json:$CLINE_MCP_JSON ($( [[ -f "$CLINE_MCP_JSON" ]] && echo present || echo absent ))"
  if [[ -f "$CLINE_SETTINGS" ]]; then
    echo "--- cline_mcp_settings.json ---"
    cat "$CLINE_SETTINGS"
  fi
}

write_config() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<EOF
{
  "mcpServers": {
    "graphify": {
      "disabled": false,
      "timeout": 60,
      "type": "stdio",
      "command": "${GRAPHIFY_PY}",
      "args": [
        "-m",
        "graphify.serve",
        "${GRAPH_JSON}"
      ],
      "env": {}
    }
  }
}
EOF
  echo "Wrote $target"
}

cmd_install() {
  if [[ ! -x "$GRAPHIFY_PY" ]]; then
    echo "ERROR: graphify python not found at $GRAPHIFY_PY" >&2
    echo "Install: uv tool install graphifyy" >&2
    exit 1
  fi
  if [[ ! -f "$GRAPH_JSON" ]]; then
    echo "WARN: $GRAPH_JSON missing — running rebuild..."
    "$SCRIPT_DIR/graphify_rebuild.sh" || true
  fi
  if [[ ! -f "$GRAPH_JSON" ]]; then
    echo "ERROR: still no graph.json — run ./AI_Workflow_Kit/script/graphify_rebuild.sh" >&2
    exit 1
  fi

  write_config "$CLINE_SETTINGS"
  write_config "$CLINE_MCP_JSON"
  echo ""
  echo "Done. Fully quit Cline CLI and restart, then open MCP panel — server 'graphify' should appear."
  echo "If the graph is stale after big code changes: ./AI_Workflow_Kit/script/graphify_rebuild.sh"
  echo "Note: MCP server loads graph.json at process start; rebuild then restart Cline (or reconnect MCP)."
}

case "${1:-}" in
  --status) cmd_status ;;
  --rebuild)
    "$SCRIPT_DIR/graphify_rebuild.sh"
    cmd_install
    ;;
  ""|--install)
    cmd_install
    ;;
  *)
    echo "Usage: $0 [--install|--rebuild|--status]" >&2
    exit 2
    ;;
esac
