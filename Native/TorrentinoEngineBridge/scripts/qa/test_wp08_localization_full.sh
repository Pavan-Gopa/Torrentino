#!/usr/bin/env bash
#
# QA WP-08 - complete EN/RU String Catalog and long-string evidence.
#
# This extends the older catalog check by verifying every static key referenced
# by the app source, not just every entry present in the catalog.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

CATALOG="${NATIVE_DIR}/TorrentinoApp/Resources/Localizable.xcstrings"
APP_DIR="${NATIVE_DIR}/TorrentinoApp"

[[ -f "${CATALOG}" ]] || qa_die "Localizable.xcstrings is missing"
[[ -d "${APP_DIR}" ]] || qa_die "TorrentinoApp source directory is missing"

python3 - "${CATALOG}" "${APP_DIR}" <<'PY'
import json
import re
import sys
from pathlib import Path

catalog_path = Path(sys.argv[1])
app_dir = Path(sys.argv[2])
issues = []
try:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    print(f"FAIL: invalid String Catalog JSON: {exc}", file=sys.stderr)
    sys.exit(1)

strings = catalog.get("strings")
if catalog.get("sourceLanguage") != "en" or not isinstance(strings, dict) or not strings:
    issues.append("catalog sourceLanguage/strings map is invalid")

def value(entry, language):
    return (((entry.get("localizations") or {}).get(language) or {}).get("stringUnit") or {}).get("value")

missing = []
for key, entry in (strings or {}).items():
    if not isinstance(entry, dict):
        missing.append(f"{key}: entry is not an object")
        continue
    for language in ("en", "ru"):
        translated = value(entry, language)
        if not isinstance(translated, str) or not translated.strip():
            missing.append(f"{key}: missing/empty {language}")
if missing:
    issues.extend(missing)

referenced = set()
for source_file in app_dir.rglob("*.swift"):
    text = source_file.read_text(encoding="utf-8")
    referenced.update(re.findall(r'String\(localized:\s*"([^"]+)"', text))
for key in sorted(referenced - set(strings or {})):
    issues.append(f"app references catalog key absent from catalog: {key}")

long_ru = []
for key, entry in (strings or {}).items():
    en = value(entry, "en") or ""
    ru = value(entry, "ru") or ""
    if len(ru) > len(en) and len(ru) >= 40:
        long_ru.append(key)
if not long_ru:
    issues.append("no Russian long-string cases found for layout validation")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print(f"OK: {len(strings)} keys have non-empty EN+RU values; long RU cases={len(long_ru)}")
PY

qa_ok "full EN/RU catalog and source-reference coverage"
qa_pass
