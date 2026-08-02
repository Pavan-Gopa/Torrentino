#!/usr/bin/env bash
#
# QA WP-02 — LIFECYCLE_CONTRACT.md completeness (feature 9).
#
# Verifies the frozen contract document contains all required sections:
#   bundle layout, plist, label, MachServices, BundleProgram, restart throttle,
#   exit-code policy, idle policy, user-disabled, logout/reboot, bounded
#   termination, update state machine — plus cross-checks against the real
#   plist and source identifiers.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

assert_file "${WP02_CONTRACT_MD}" "LIFECYCLE_CONTRACT.md present"
assert_file "${WP02_PLIST_SRC}" "com.torrentino.app.engine-agent.plist present"

DOC="$(cat "${WP02_CONTRACT_MD}")"
PLIST="$(cat "${WP02_PLIST_SRC}")"

# --- required document sections / keywords ----------------------------------
assert_contains "${DOC}" "Contents/Library/LaunchAgents" "bundle layout (LaunchAgents path)"
assert_contains "${DOC}" "com.torrentino.app.engine-agent" "label"
assert_contains "${DOC}" "MachServices" "MachServices section"
assert_contains "${DOC}" "com.torrentino.app.engine-agent.mach" "Mach service name"
assert_contains "${DOC}" "BundleProgram" "BundleProgram key documented"
assert_contains "${DOC}" "ThrottleInterval" "restart throttle"
assert_contains "${DOC}" "ExitTimeOut" "bounded termination (ExitTimeOut)"
assert_contains "${DOC}" "exit" "exit-code policy present"
assert_contains "${DOC}" "SuccessfulExit" "idle / KeepAlive SuccessfulExit policy"
assert_contains "${DOC}" "requiresApproval" "user-disabled / approval path"
assert_contains "${DOC}" "logout" "logout/reboot semantics" || assert_contains "${DOC}" "shutdown" "logout/reboot/shutdown semantics"
assert_contains "${DOC}" "TTC1" "update state machine (v1 magic)"
assert_contains "${DOC}" "TTC2" "update state machine (v2 magic)"
assert_contains "${DOC}" "downgrade" "downgrade semantics"
assert_contains "${DOC}" "flock" "single-instance flock"
assert_contains "${DOC}" "in-process" "denial: no in-process fallback"
assert_contains "${DOC}" "SMAppService" "SMAppService registration"
assert_contains "${DOC}" "XPC_SERVICE_NAME" "launchd-only serving guard"

# --- numbered contract sections present -------------------------------------
for n in 1 2 3 4 5 6 7 8 9 10 11; do
	assert_match "${DOC}" "## ${n}\." "section ${n} heading"
done

# --- exit codes table values ------------------------------------------------
assert_contains "${DOC}" "| \`0\`" "exit code 0 documented"
assert_contains "${DOC}" "| \`1\`" "exit code 1 documented"
assert_contains "${DOC}" "| \`78\`" "exit code 78 documented"

# --- reconnect policy -------------------------------------------------------
assert_contains "${DOC}" "5" "reconnect max attempts mentioned"
assert_contains "${DOC}" "DEGRADED" "DEGRADED UI state"

# --- cross-check: source plist matches contract ----------------------------
assert_contains "${PLIST}" "<string>com.torrentino.app.engine-agent</string>" "plist Label"
assert_contains "${PLIST}" "BundleProgram" "plist has BundleProgram"
assert_contains "${PLIST}" "Contents/Library/LaunchAgents/TorrentinoEngineAgent" "plist BundleProgram path"
assert_contains "${PLIST}" "com.torrentino.app.engine-agent.mach" "plist MachServices"
assert_contains "${PLIST}" "ThrottleInterval" "plist ThrottleInterval"
assert_contains "${PLIST}" "<integer>10</integer>" "plist ThrottleInterval=10"
assert_contains "${PLIST}" "ExitTimeOut" "plist ExitTimeOut"
assert_contains "${PLIST}" "<integer>30</integer>" "plist ExitTimeOut=30"
assert_contains "${PLIST}" "SuccessfulExit" "plist KeepAlive.SuccessfulExit"
assert_contains "${PLIST}" "RunAtLoad" "plist RunAtLoad"

# plutil validation
plutil -lint "${WP02_PLIST_SRC}" >/dev/null
qa_ok "source plist passes plutil -lint"

# --- cross-check: Swift frozen identifiers match contract -------------------
PROTO="${NATIVE_DIR}/TorrentinoEngineAgent/XPC/TorrentinoEngineXPCProtocol.swift"
assert_file "${PROTO}" "XPC protocol source present"
PROTO_SRC="$(cat "${PROTO}")"
assert_contains "${PROTO_SRC}" 'uiAppBundleIdentifier = "com.torrentino.app"' "UI bundle id frozen"
assert_contains "${PROTO_SRC}" 'agentBundleIdentifier = "com.torrentino.app.engine-agent"' "agent id frozen"
assert_contains "${PROTO_SRC}" 'machServiceName = "com.torrentino.app.engine-agent.mach"' "mach name frozen"
assert_contains "${PROTO_SRC}" 'teamIdentifier = "438UQRF7JV"' "team id frozen"

# XPC 5 methods present in protocol
for sel in "hello(reply:" "health(reply:" "incrementCounter(reply:" "getCounter(reply:" "shutdown(reply:"; do
	assert_contains "${PROTO_SRC}" "${sel}" "protocol method ${sel}"
done

qa_pass
