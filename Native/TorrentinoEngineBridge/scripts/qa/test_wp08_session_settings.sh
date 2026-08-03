#!/usr/bin/env bash
#
# QA WP-08 - session settings fetch, transactional live apply, and rollback.
#
# The settings UI and IPC transaction are not sufficient by themselves: every
# session field must reach the live EngineBridge path, and failed applies must
# leave both the engine and durable revision at the previous candidate.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

VIEW="${NATIVE_DIR}/TorrentinoApp/Features/Settings/SettingsView.swift"
COORDINATOR="${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift"
ENGINE_COORDINATOR="${NATIVE_DIR}/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift"
BRIDGE_SMOKE="${NATIVE_DIR}/TorrentinoEngineBridge/bridge/bridge_smoke.cpp"
TESTS="${NATIVE_DIR}/Tests/TorrentinoEngineAgentTests/TransferSmokeTests.swift"

for file in "${VIEW}" "${COORDINATOR}" "${ENGINE_COORDINATOR}" "${BRIDGE_SMOKE}" "${TESTS}"; do
	[[ -f "${file}" ]] || qa_die "missing session-settings input ${file}"
done

python3 - "${VIEW}" "${COORDINATOR}" "${ENGINE_COORDINATOR}" "${BRIDGE_SMOKE}" "${TESTS}" <<'PY'
import sys
from pathlib import Path

view, coordinator, engine_coordinator, bridge_smoke, tests = [
    Path(path).read_text(encoding="utf-8") for path in sys.argv[1:]
]
issues = []

for needle, description in (
    ("EngineCommandV1.fetchSettings", "Settings fetch command"),
    ("settingsRevision = result.revision", "settings revision fetch"),
    ("SettingsTransaction.run", "UI transaction preflight"),
    ("EngineCommandV1.applySettings", "Settings apply command"),
    ("SettingsRules.validate", "UI validation"),
    ("password: nil", "password omitted from IPC candidate"),
):
    if needle not in view:
        issues.append(f"{description} is missing from SettingsView")

for needle, description in (
    ("case .fetchSettings", "agent fetch dispatch"),
    ("SettingsTransaction.AsyncContext", "agent async transaction context"),
    ("persistence.persistSettings", "durable settings persist"),
    ("engine.apply(settings:", "live engine settings apply"),
    ("rollback: {", "settings rollback closure"),
    ("settingsChanged", "settings change event"),
):
    if needle not in coordinator:
        issues.append(f"{description} is missing from TransferCoordinator")

for needle, description in (
    ("SessionConfigurationDTO(", "session DTO construction"),
    ("enableDHT: settings.dhtEnabled", "DHT mapping"),
    ("enableLSD: settings.lsdEnabled", "LSD mapping"),
    ("enableUPnP: settings.upnpEnabled", "UPnP mapping"),
    ("enableNATPMP: settings.natPmpEnabled", "NAT-PMP mapping"),
    ("encryptionEnabled: settings.encryptionEnabled", "encryption mapping"),
    ("maxDownloadBytesPerSec: settings.maxDownloadBytesPerSec", "download-rate mapping"),
    ("maxUploadBytesPerSec: settings.maxUploadBytesPerSec", "upload-rate mapping"),
    ("proxy: SessionProxyDTO", "proxy metadata mapping"),
    ("adapter.applyEngine(withConfigurationData", "real bridge apply call"),
):
    if needle not in engine_coordinator:
        issues.append(f"{description} is missing from EngineCoordinator")

for needle, description in (
    ("live session settings", "native live-settings scenario"),
    ("applied.enable_dht", "native DHT setting"),
    ("applied.enable_lsd", "native LSD setting"),
    ("applied.enable_upnp", "native UPnP setting"),
    ("applied.enable_natpmp", "native NAT-PMP setting"),
    ("applied.encryption_enabled", "native encryption setting"),
    ("applied.max_download_bytes_per_sec", "native download-rate setting"),
    ("applied.max_upload_bytes_per_sec", "native upload-rate setting"),
    ("bridge.apply(applied)", "native live apply invocation"),
):
    if needle not in bridge_smoke:
        issues.append(f"{description} is missing from bridge_smoke")

for name in (
    "testSessionSettingsFetchApplyLiveAndPersist",
    "testSessionSettingsApplyFailureRollsBack",
    "testSessionSettingsInvalidCandidateDoesNotMutate",
    "testSessionSettingsRevisionConflictDoesNotMutate",
):
    if f"func {name}" not in tests:
        issues.append(f"missing dedicated XCTest axis {name}")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: session settings map through UI/IPC/agent/native apply with rollback and typed no-mutation tests")
PY

qa_ok "session settings live-apply and transaction contract"
qa_pass
