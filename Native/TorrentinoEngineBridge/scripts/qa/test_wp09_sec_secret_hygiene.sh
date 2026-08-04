#!/usr/bin/env bash
#
# QA WP-09 security - Secret hygiene: proxy password / Keychain must not
# leak into logs, events, snapshots, or health (ADR-014).
#
# WP-09 surface: the agent is network- and filesystem-facing. The proxy
# password (ProxyConfiguration.password) and Keychain credentials must travel
# only over peer-verified XPC inside apply/testProxy commands, and must NEVER
# appear in renderable projections (EngineSnapshot/TorrentDelta), in events
# (SettingsChangedEvent/SystemConditionEvent), in the health snapshot the
# agent exposes, or in any product print/os_log call.
#
# This is a source-contract test (same style as test_wp08_accessibility.sh):
# it asserts the product sources carry the no-leak contract. It does not
# execute product code. Runtime leakage is additionally covered by the XCTest
# testWP09SecurityNoSecretLeakageInSnapshotsAndEvents (run via
# test_wp09_sec_matrix.sh).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

IPC_DIR="${NATIVE_DIR}/TorrentinoIPC"
AGENT_DIR="${NATIVE_DIR}/TorrentinoEngineAgent"
APP_DIR="${NATIVE_DIR}/TorrentinoApp"
STATE="${IPC_DIR}/State.swift"
SNAPSHOT="${IPC_DIR}/Snapshot.swift"
EVENTS="${IPC_DIR}/Events.swift"
AGENT_SERVICE="${AGENT_DIR}/Agent/AgentService.swift"

for f in "${STATE}" "${SNAPSHOT}" "${EVENTS}" "${AGENT_SERVICE}"; do
	[[ -f "${f}" ]] || qa_die "missing source: ${f}"
done

python3 - "${IPC_DIR}" "${AGENT_DIR}" "${APP_DIR}" "${STATE}" "${SNAPSHOT}" "${EVENTS}" "${AGENT_SERVICE}" <<'PY'
import re
import sys
from pathlib import Path

ipc_dir       = Path(sys.argv[1])
agent_dir     = Path(sys.argv[2])
app_dir       = Path(sys.argv[3])
state_src     = Path(sys.argv[4]).read_text(encoding="utf-8")
snapshot_src  = Path(sys.argv[5]).read_text(encoding="utf-8")
events_src    = Path(sys.argv[6]).read_text(encoding="utf-8")
service_src   = Path(sys.argv[7]).read_text(encoding="utf-8")
issues = []

SECRET_FIELDS = ("password", "secret", "credential", "passkey")

# 1. Renderable projections must not declare secret-bearing fields.
#    EngineSnapshot / TorrentSnapshot / TorrentDelta carry torrents, revisions,
#    instanceID, rates, peers, limits, saveLocation — none of which is a secret.
for label, src in (("Snapshot", snapshot_src), ("Events", events_src)):
    for field in SECRET_FIELDS:
        # Look for a stored property declaration `let <field>` or `var <field>`.
        if re.search(r'\b(?:let|var)\s+' + field + r'\b', src, re.IGNORECASE):
            issues.append(f"{label} declares a secret-bearing field '{field}'")

# 2. ProxyConfiguration must NOT be a field of any snapshot/event type.
#    (It is allowed only inside command request payloads.)
for label, src in (("Snapshot", snapshot_src), ("Events", events_src)):
    if re.search(r'\b(?:let|var)\s+proxy\b', src, re.IGNORECASE) or \
       "ProxyConfiguration" in src:
        issues.append(f"{label} embeds ProxyConfiguration (password carrier)")

# 3. Health snapshot payload must not include secret/proxy fields.
#    AgentService.healthSnapshot returns a [String: Any] dictionary; assert its
#    keys exclude secret/proxy identifiers.
health_keys = re.findall(r'"([a-zA-Z_]+)":', service_src)
secret_keys_in_health = [k for k in health_keys
                         if k.lower() in SECRET_FIELDS or k.lower() == "proxy"]
if secret_keys_in_health:
    issues.append("health snapshot exposes secret/proxy keys: "
                  + repr(secret_keys_in_health))

# 4. NEGATIVE: no product print/os_log/Logger call may reference a secret or
#    the proxy config (would leak to logs/diagnostic bundle).
product_all = "\n".join(
    p.read_text(encoding="utf-8", errors="ignore")
    for tree in (ipc_dir, agent_dir, app_dir)
    for p in tree.rglob("*.swift")
)
leak_log = re.findall(
    r'(?:print|os_log|os\.log|Logger\([^)]*\)\.[a-z]+|logger\.[a-z]+)\s*\(?[^)]{0,120}'
    r'(?:password|secret|passkey|proxyPassword)',
    product_all, re.IGNORECASE)
if leak_log:
    issues.append("product logging references a secret: " + repr(leak_log[:3]))

# 5. ProxyConfiguration has NO custom redacted description, so a future
#    `String(describing: proxy)` would dump the password. This is a residual
#    risk to flag (not a product bug today — no code path stringifies it).
has_proxy_description = bool(re.search(
    r'extension\s+ProxyConfiguration\b[^{]*\{[^}]*CustomStringConvertible',
    state_src, re.S)) or "ProxyConfiguration: CustomStringConvertible" in state_src
if not has_proxy_description:
    print("[info] ProxyConfiguration has no redacted CustomStringConvertible "
          "description (residual: future String(describing:) could leak; no "
          "product path stringifies it today)")

if issues:
    print("[FAIL] WP-09 secret-hygiene contract:")
    for i in issues:
        print("  - " + i)
    sys.exit(1)
print("[ok] WP-09 no secret leakage into snapshots/events/health/logs")
PY

echo "WP-09 secret hygiene: PASS"
