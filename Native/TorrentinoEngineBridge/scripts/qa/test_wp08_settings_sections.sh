#!/usr/bin/env bash
#
# QA WP-08 - Settings sections and validation coverage.
#
# This check distinguishes the five visible tabs from the validation contract:
# a field shown in Settings but absent from SettingsRules is a defect.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

SETTINGS_VIEW="${NATIVE_DIR}/TorrentinoApp/Features/Settings/SettingsView.swift"
SETTINGS="${NATIVE_DIR}/TorrentinoIPC/Settings.swift"

[[ -f "${SETTINGS_VIEW}" ]] || qa_die "SettingsView.swift is missing"
[[ -f "${SETTINGS}" ]] || qa_die "Settings.swift is missing"

python3 - "${SETTINGS_VIEW}" "${SETTINGS}" <<'PY'
import re
import sys
from pathlib import Path

view = Path(sys.argv[1]).read_text(encoding="utf-8")
rules = Path(sys.argv[2]).read_text(encoding="utf-8")
issues = []

enum_match = re.search(r'enum SettingsTab:.*?\n\s*var title', view, re.S)
enum_body = enum_match.group(0) if enum_match else ""
for tab in ("general", "bandwidth", "network", "transfers", "notifications"):
    if len(re.findall(rf'\bcase {tab}\b', enum_body)) != 1:
        issues.append(f"SettingsTab.{tab} missing or duplicated")
    if f'.tag(SettingsTab.{tab})' not in view:
        issues.append(f"SettingsTab.{tab} has no TabView tag")

for key in (
    "settings.tab.general", "settings.tab.bandwidth", "settings.tab.network",
    "settings.tab.transfers", "settings.tab.notifications",
):
    if key not in view:
        issues.append(f"missing localized section key {key}")

rules_match = re.search(r'public enum SettingsRules\s*\{(?P<body>.*?)\n\}\n\n/// The settings apply', rules, re.S)
rules_body = rules_match.group("body") if rules_match else ""
for field in ("downloadDirectory", "maxDownloadBytesPerSec", "maxUploadBytesPerSec", "listenPort"):
    if field not in rules_body:
        issues.append(f"SettingsRules does not validate {field}")
for field in ("maxDownloadBytesPerSec", "maxUploadBytesPerSec"):
    if not re.search(rf'settings\.{field}\s*<\s*0', rules_body):
        issues.append(f"negative {field} is not rejected")

if 'let port = UInt16(listenPort) ?? 6881' in view:
    issues.append("invalid listenPort text silently falls back to 6881 instead of producing an inline validation error")

validation_at = view.find('let errors = SettingsRules.validate(candidate)')
persist_at = view.find('KeychainStore.saveProxyPassword')
send_at = view.find('viewModel.client.sendCommand')
if validation_at < 0 or (persist_at >= 0 and validation_at > persist_at):
    issues.append("SettingsRules.validate is not before credential persistence")
if validation_at < 0 or (send_at >= 0 and validation_at > send_at):
    issues.append("SettingsRules.validate is not before apply command")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: five Settings sections and field validation are present")
PY

qa_ok "settings sections/validation source contract"
qa_pass
