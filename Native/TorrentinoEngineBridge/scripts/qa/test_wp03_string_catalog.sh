#!/usr/bin/env bash
#
# QA WP-03 — String Catalog EN/RU complete.
#
# Validates Localizable.xcstrings is valid JSON and every key has both en + ru
# localizations with non-empty translated values.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

XCSTRINGS="${NATIVE_DIR}/TorrentinoApp/Resources/Localizable.xcstrings"
assert_file "${XCSTRINGS}" "Localizable.xcstrings"

# JSON validity via python3 (portable; plutil also works for .json but xcstrings
# is JSON with a custom extension).
python3 - <<'PY' "${XCSTRINGS}"
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except json.JSONDecodeError as e:
    print(f"FAIL: invalid JSON: {e}", file=sys.stderr)
    sys.exit(1)

if data.get("sourceLanguage") != "en":
    print(f"FAIL: sourceLanguage expected 'en', got {data.get('sourceLanguage')!r}", file=sys.stderr)
    sys.exit(1)

strings = data.get("strings")
if not isinstance(strings, dict) or not strings:
    print("FAIL: strings map missing or empty", file=sys.stderr)
    sys.exit(1)

required_langs = ("en", "ru")
missing = []
empty_val = []
for key, entry in sorted(strings.items()):
    if not isinstance(entry, dict):
        missing.append(f"{key}: entry not object")
        continue
    locs = entry.get("localizations") or {}
    for lang in required_langs:
        unit = (locs.get(lang) or {}).get("stringUnit") or {}
        val = unit.get("value")
        if lang not in locs:
            missing.append(f"{key}: missing {lang}")
        elif not isinstance(val, str) or not val.strip():
            empty_val.append(f"{key}: empty {lang}")

# Keys referenced by empty state / degraded banner must exist.
for must in (
    "empty.no_torrents",
    "empty.subtitle",
    "error.xpc_unavailable",
    "error.agent_denied",
    "error.timeout",
    "error.internal",
    "app.name",
):
    if must not in strings:
        missing.append(f"required key absent: {must}")

if missing or empty_val:
    for m in missing:
        print(f"FAIL: {m}", file=sys.stderr)
    for m in empty_val:
        print(f"FAIL: {m}", file=sys.stderr)
    sys.exit(1)

print(f"OK keys={len(strings)} langs=en+ru complete")
PY

qa_ok "xcstrings valid JSON; all keys have EN+RU"
qa_pass
