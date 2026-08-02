#!/usr/bin/env bash
#
# Torrentino — shared helpers for WP-02 QA scripts (Test Engineer).
#
# Role:     sourced by every test_wp02_*.sh after qa_common.sh. Resolves the
#           signed app/agent, launchd label, and provides wait/cli/cleanup
#           helpers. Product Application Support is hard-coded by the agent
#           (see LIFECYCLE_CONTRACT.md); every WP-02 script MUST call
#           wp02_cleanup on EXIT so the engine dir + launchd job never leak.
# Invariant: never leave residual jobs/processes/temp data; never require root.
#
# NOTE: macOS ships bash 3.2 — keep this portable (no mapfile/readarray).

# --- frozen identifiers (LIFECYCLE_CONTRACT.md) ------------------------------
WP02_LABEL="com.torrentino.app.engine-agent"
WP02_MACH="com.torrentino.app.engine-agent.mach"
WP02_DOMAIN="gui/$(id -u)"
WP02_TEAM="438UQRF7JV"
WP02_ENGINE_DIR="${HOME}/Library/Application Support/com.torrentino.app/Engine"
WP02_COUNTER="${WP02_ENGINE_DIR}/counter.dat"
WP02_LOCK="${WP02_ENGINE_DIR}/instance.lock"
WP02_LIFECYCLE_SH="${NATIVE_DIR}/Config/lifecycle_test.sh"
WP02_UPDATE_SH="${NATIVE_DIR}/Config/update_test.sh"
WP02_CONTRACT_MD="${NATIVE_DIR}/Config/LIFECYCLE_CONTRACT.md"
WP02_PLIST_SRC="${NATIVE_DIR}/Config/com.torrentino.app.engine-agent.plist"
WP02_PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

# Resolve newest Debug Torrentino.app from DerivedData (override via APP_PATH).
wp02_resolve_app() {
	if [[ -n "${APP_PATH:-}" && -d "${APP_PATH}" ]]; then
		WP02_APP="${APP_PATH}"
	else
		WP02_APP="$(ls -dt "${HOME}/Library/Developer/Xcode/DerivedData"/Torrentino-*/Build/Products/Debug/Torrentino.app 2>/dev/null | head -1 || true)"
	fi
	[[ -n "${WP02_APP}" && -d "${WP02_APP}" ]] || return 1
	WP02_CLI="${WP02_APP}/Contents/MacOS/Torrentino"
	WP02_AGENT_BIN="${WP02_APP}/Contents/Library/LaunchAgents/TorrentinoEngineAgent"
	WP02_AGENT_PLIST="${WP02_APP}/Contents/Library/LaunchAgents/${WP02_LABEL}.plist"
	[[ -x "${WP02_CLI}" && -x "${WP02_AGENT_BIN}" && -f "${WP02_AGENT_PLIST}" ]] || return 1
	return 0
}

# Standalone agent product (non-embedded) used by update/downgrade phases.
wp02_resolve_standalone_agent() {
	if [[ -n "${AGENT_BIN:-}" && -x "${AGENT_BIN}" ]]; then
		WP02_STANDALONE_AGENT="${AGENT_BIN}"
		return 0
	fi
	WP02_STANDALONE_AGENT="$(ls -dt "${HOME}/Library/Developer/Xcode/DerivedData"/Torrentino-*/Build/Products/Debug/TorrentinoEngineAgent 2>/dev/null | head -1 || true)"
	[[ -n "${WP02_STANDALONE_AGENT}" && -x "${WP02_STANDALONE_AGENT}" ]]
}

wp02_require_app() {
	wp02_resolve_app || qa_die "signed Torrentino.app not found (build Debug first or set APP_PATH)"
	qa_log "APP_PATH=${WP02_APP}"
}

wp02_agent_pid() {
	# Prefer embedded agent path; fall back to any TorrentinoEngineAgent.
	local p
	p="$(pgrep -f "Contents/Library/LaunchAgents/TorrentinoEngineAgent" 2>/dev/null | head -1 || true)"
	if [[ -z "${p}" ]]; then
		p="$(pgrep -x "TorrentinoEngineAgent" 2>/dev/null | head -1 || true)"
	fi
	if [[ -z "${p}" ]]; then
		p="$(pgrep -f "TorrentinoEngineAgent" 2>/dev/null | head -1 || true)"
	fi
	printf '%s' "${p}"
}

wp02_agent_running() { [[ -n "$(wp02_agent_pid)" ]]; }
wp02_agent_gone() { ! wp02_agent_running; }

wp02_wait_for() { # <seconds> <cmd...>
	local deadline=$((SECONDS + $1)); shift
	while [[ "${SECONDS}" -lt "${deadline}" ]]; do
		"$@" >/dev/null 2>&1 && return 0
		sleep 0.5
	done
	return 1
}

wp02_cli() { # <command> -> sets WP02_CLI_OUT / WP02_CLI_RC
	local cmd="$1"
	set +e
	WP02_CLI_OUT="$("${WP02_CLI}" --cli "${cmd}" 2>&1)"
	WP02_CLI_RC=$?
	set -e
	qa_log "cli ${cmd} rc=${WP02_CLI_RC}: ${WP02_CLI_OUT}"
}

wp02_last_exit_code() {
	launchctl print "${WP02_DOMAIN}/${WP02_LABEL}" 2>/dev/null \
		| sed -n 's/.*last exit code = \([0-9]*\).*/\1/p' | head -1
}

wp02_mach_endpoint() {
	launchctl print "${WP02_DOMAIN}/${WP02_LABEL}" 2>/dev/null | grep -q "${WP02_MACH}"
}

# Aggressive cleanup: unregister SMAppService, bootout job, kill agents, wipe
# engine dir. Safe to call multiple times. Does NOT touch production data
# outside com.torrentino.app/Engine.
wp02_cleanup() {
	if [[ -n "${WP02_CLI:-}" && -x "${WP02_CLI}" ]]; then
		"${WP02_CLI}" --cli unregister >/dev/null 2>&1 || true
	fi
	launchctl bootout "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1 || true
	pkill -f "Contents/Library/LaunchAgents/TorrentinoEngineAgent" 2>/dev/null || true
	pkill -f "Build/Products/Debug/TorrentinoEngineAgent" 2>/dev/null || true
	pkill -x "TorrentinoEngineAgent" 2>/dev/null || true
	# Give processes a moment to die before wiping the lock file.
	sleep 0.3
	rm -rf "${WP02_ENGINE_DIR}" 2>/dev/null || true
}

# Install EXIT trap that preserves script exit code, cleans WP-02 state, then
# runs qa_common's mktemp cleanup (overrides the default qa_cleanup-only trap).
wp02_trap_cleanup() {
	trap 'rc=$?; wp02_cleanup; qa_cleanup; exit $rc' EXIT
}

# Reset to a clean unregistered / no-agent / empty engine dir baseline.
wp02_reset() {
	wp02_cleanup
	sleep 0.5
	rm -rf "${WP02_ENGINE_DIR}"
}

# Bootstrap a temporary launchd job for a standalone agent binary (update-style).
# Mirrors production MachServices / KeepAlive / RunAtLoad.
wp02_start_temp_job() { # <binary> <plist_out>
	local bin="$1" plist="$2"
	cat > "${plist}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${WP02_LABEL}</string>
	<key>Program</key>
	<string>${bin}</string>
	<key>MachServices</key>
	<dict>
		<key>${WP02_MACH}</key>
		<true/>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ExitTimeOut</key>
	<integer>30</integer>
</dict>
</plist>
PLIST
	launchctl bootout "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1 || true
	launchctl bootstrap "${WP02_DOMAIN}" "${plist}" || return 1
	wp02_wait_for 15 wp02_mach_endpoint || return 1
	wp02_wait_for 10 wp02_agent_running || return 1
	return 0
}

wp02_stop_temp_job() {
	launchctl kill TERM "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1 || true
	wp02_wait_for 10 wp02_agent_gone || true
	launchctl bootout "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1 || true
}

# Counter magic helpers (on-disk format evidence).
wp02_counter_magic() {
	head -c4 "${WP02_COUNTER}" 2>/dev/null | od -An -c | tr -d ' \n'
}

# Ensure SMAppService is registered and agent is up (for scenarios needing a live agent).
wp02_register_and_wait() {
	wp02_cli register
	[[ "${WP02_CLI_RC}" -eq 0 ]] || return 1
	echo "${WP02_CLI_OUT}" | grep -q "status=enabled" || return 1
	wp02_wait_for 15 wp02_agent_running || return 1
	return 0
}
