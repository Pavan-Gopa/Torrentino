#!/usr/bin/env bash
# WP-23 QA Gate: Add pipeline (confirm-before-download, truthful progress, durable file selection)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../" && pwd)"

echo "=== WP-23 Add Pipeline Verification ==="
echo "Repository root: $REPO_ROOT"

cd "$REPO_ROOT"

# Run the agent and app integration test suites covering WP23
echo "Running WP-23 test suite..."
xcodebuild test \
    -project Native/Torrentino.xcodeproj \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoAppTests/WP23AddPipelineAppTests \
    -only-testing:TorrentinoEngineAgentTests/WP23AddPipelineAgentTests \
    2>&1 | tee /tmp/wp23_test.log | tail -25

# Check test result
if grep -q "\*\* TEST SUCCEEDED \*\*" /tmp/wp23_test.log; then
    echo "=== WP-23 Add Pipeline Verification: PASS ==="
    exit 0
else
    echo "=== WP-23 Add Pipeline Verification: FAIL ==="
    exit 1
fi
