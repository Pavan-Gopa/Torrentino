#!/usr/bin/env bash
#
# QA WP-08 - Keychain save/load/delete and security boundary checks.
#
# This is intentionally negative: a single happy-path smoke test is not
# sufficient for three public Keychain operations or for the security rule
# that credentials must never reach UserDefaults.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

KEYCHAIN="${NATIVE_DIR}/TorrentinoApp/Features/Settings/KeychainStore.swift"
APP_DIR="${NATIVE_DIR}/TorrentinoApp"
APP_TESTS="${NATIVE_DIR}/Tests/TorrentinoAppTests/TorrentinoAppTests.swift"
SETTINGS_VIEW="${NATIVE_DIR}/TorrentinoApp/Features/Settings/SettingsView.swift"

[[ -f "${KEYCHAIN}" ]] || qa_die "KeychainStore.swift is missing"
[[ -f "${APP_TESTS}" ]] || qa_die "TorrentinoAppTests.swift is missing"
[[ -f "${SETTINGS_VIEW}" ]] || qa_die "SettingsView.swift is missing"

python3 - "${KEYCHAIN}" "${APP_DIR}" "${APP_TESTS}" "${SETTINGS_VIEW}" <<'PY'
import re
import sys
from pathlib import Path

keychain = Path(sys.argv[1]).read_text(encoding="utf-8")
app_dir = Path(sys.argv[2])
tests = Path(sys.argv[3]).read_text(encoding="utf-8")
settings_view = Path(sys.argv[4]).read_text(encoding="utf-8")
issues = []

for api in ("SecItemAdd", "SecItemCopyMatching", "SecItemDelete"):
    if api not in keychain:
        issues.append(f"missing Security API {api}")
for key in ("kSecClassGenericPassword", "kSecAttrService", "kSecAttrAccount", "kSecValueData", "kSecAttrAccessibleAfterFirstUnlock"):
    if key not in keychain:
        issues.append(f"missing Keychain attribute {key}")
if '"com.torrentino.app"' not in keychain or '"proxy_password"' not in keychain:
    issues.append("proxy Keychain service/account are not pinned")
if keychain.count("Task.detached") < 3:
    issues.append("all three Keychain operations must leave the MainActor via Task.detached")
if "@MainActor" in keychain:
    issues.append("KeychainStore must not be MainActor-isolated")
if "password: nil" not in settings_view:
    issues.append("SettingsView candidate must omit proxy password from IPC settings")

for source_file in app_dir.rglob("*.swift"):
    source = re.sub(r'//.*', '', source_file.read_text(encoding="utf-8"))
    if "UserDefaults" in source:
        issues.append(f"UserDefaults appears in app source: {source_file.name}")
if re.search(r'\b(print|NSLog|os_log)\s*\(', keychain):
    issues.append("KeychainStore logs potentially sensitive values")

keychain_files = list(app_dir.rglob("KeychainStore.swift"))
if len(keychain_files) != 1:
    issues.append(f"expected exactly one KeychainStore.swift, found {len(keychain_files)}")

test_functions = re.findall(r'\bfunc\s+(test\w*Keychain\w*)\s*\(', tests)
if len(test_functions) < 3:
    issues.append("Keychain public API has fewer than three dedicated unit tests")
if not re.search(r"XCTAssertNil\(\s*(?:await\s+)?KeychainStore\.loadProxyPassword\(\)|loaded\s*\)", tests):
    issues.append("no negative load-after-delete assertion")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: SecItem round-trip, negative deletion check, no UserDefaults, and secure attributes are covered")
PY

qa_ok "Keychain security boundary source and test contract"
qa_pass
