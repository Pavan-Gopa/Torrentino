#!/bin/bash
# Layer: WP-02 update/downgrade evidence (v1 -> v2 migration, checksum, downgrade).
# Role: build an N-1 (v1) and an N (v2) agent from the same source tree, serve
#       them via TEMPORARY launchd jobs against the shared engine dir, and drive
#       them via the app --cli. The fault phases (downgrade/corruption) run the
#       binary directly: they exit during bootstrap BEFORE the Mach check-in.
# Why launchd jobs for serving: named Mach services can only be vended by
#       launchd-managed jobs — a directly executed agent gets EPERM on listener
#       activation ("listener failed to activate: xpc_error=[1: Operation not
#       permitted]", macOS 26.5) and cannot serve. The temporary job mirrors the
#       production plist (same label, MachServices, RunAtLoad, KeepAlive).
# Must-not: leave any launchd job loaded after exit, re-register the real
#           SMAppService job; it unregisters/bootouts any existing job first.
# Usage: ./update_test.sh
# Exit: 0 if all checks pass, 1 otherwise.
# Contract: Native/Config/LIFECYCLE_CONTRACT.md
set -u -o pipefail

LABEL="com.torrentino.app.engine-agent"
MACH="com.torrentino.app.engine-agent.mach"
DOMAIN="gui/$(id -u)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NATIVE_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$NATIVE_DIR/Torrentino.xcodeproj"
ENGINE_DIR="$HOME/Library/Application Support/com.torrentino.app/Engine"
COUNTER="$ENGINE_DIR/counter.dat"
V1_DD="${TMPDIR:-/tmp}/torrentino-wp02-v1"
V2_DD="${TMPDIR:-/tmp}/torrentino-wp02-v2"
OUT_DIR="${OUT_DIR:-$NATIVE_DIR/test-results/update-$(date +%Y%m%d-%H%M%S)}"
EVIDENCE="$OUT_DIR/evidence.log"
V1_BIN="$V1_DD/Build/Products/Debug/TorrentinoEngineAgent"
V2_BIN="$V2_DD/Build/Products/Debug/TorrentinoEngineAgent"
CLI="$V2_DD/Build/Products/Debug/Torrentino.app/Contents/MacOS/Torrentino"

mkdir -p "$OUT_DIR"
PASS=0; FAIL=0; RESULTS=""

log() { echo "$@" | tee -a "$EVIDENCE"; }
check() { # <name> <rc>
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS+1)); RESULTS="$RESULTS|PASS $1"; log "CHECK PASS: $1"
  else
    FAIL=$((FAIL+1)); RESULTS="$RESULTS|FAIL $1"; log "CHECK FAIL: $1"
  fi
}
run_cli() { # <command> -> sets CLI_OUT / CLI_RC
  log "+ Torrentino --cli $1"
  CLI_OUT="$("$CLI" --cli "$1" 2>&1)"; CLI_RC=$?
  log "$CLI_OUT"; log "rc=$CLI_RC"
}
wait_for() { # <seconds> <cmd...>
  local deadline=$((SECONDS + $1)); shift
  while [ "$SECONDS" -lt "$deadline" ]; do "$@" >/dev/null 2>&1 && return 0; sleep 0.5; done
  return 1
}
agent_pid() { pgrep -f "Build/Products/Debug/TorrentinoEngineAgent" | head -1 || true; }
agent_running() { [ -n "$(agent_pid)" ]; }
magic() { head -c4 "$COUNTER" 2>/dev/null | od -An -c | tr -d ' \n'; }
mach_endpoint() { # the Mach service is registered for the job
  launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "$MACH"
}
start_job() { # <binary> <tag> — bootstrap a temporary launchd job (RunAtLoad)
  local bin="$1" tag="$2"
  local plist="$OUT_DIR/job-$tag.plist"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>Program</key>
	<string>$bin</string>
	<key>MachServices</key>
	<dict>
		<key>$MACH</key>
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
  launchctl bootout "$DOMAIN/$LABEL" >>"$EVIDENCE" 2>&1 || true
  log "+ launchctl bootstrap $DOMAIN $plist"
  if ! launchctl bootstrap "$DOMAIN" "$plist" >>"$EVIDENCE" 2>&1; then
    log "BOOTSTRAP FAILED for $plist"
    return 1
  fi
  wait_for 15 mach_endpoint
  wait_for 10 agent_running
  log "job running pid=$(agent_pid)"
}
stop_job() { # SIGTERM via launchctl, capture "last exit code", then bootout
  launchctl kill TERM "$DOMAIN/$LABEL" >>"$EVIDENCE" 2>&1 || true
  wait_for 10 agent_gone
  local i line=""
  for i in 1 2 3 4 5 6; do
    line="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep 'last exit code' || true)"
    [ -n "$line" ] && break
    sleep 0.5
  done
  log "job stop: $line"
  STOP_LINE="$line"
  launchctl bootout "$DOMAIN/$LABEL" >>"$EVIDENCE" 2>&1 || true
}
agent_gone() { ! agent_running; }
cleanup() {
  local rc=$? # preserve script verdict through the EXIT trap
  log "--- cleanup ---"
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  pkill -f "Build/Products/Debug/TorrentinoEngineAgent" 2>/dev/null || true
  cp "$COUNTER" "$OUT_DIR/counter-final.dat" 2>/dev/null || true
  rm -rf "$ENGINE_DIR"
  exit $rc
}
trap cleanup EXIT

log "=== WP-02 update test $(date) ==="
log "OUT_DIR=$OUT_DIR"

# --- build v1 (N-1) and v2 (N) from the same source --------------------------
log "--- build v1 agent (COUNTER_FORMAT_V1) ---"
xcodebuild -project "$PROJECT" -scheme TorrentinoEngineAgent -configuration Debug \
  -derivedDataPath "$V1_DD" SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG COUNTER_FORMAT_V1' \
  build >>"$EVIDENCE" 2>&1
check "build.v1" $?
log "--- build v2 app + agent ---"
xcodebuild -project "$PROJECT" -scheme Torrentino -configuration Debug \
  -derivedDataPath "$V2_DD" build >>"$EVIDENCE" 2>&1
check "build.v2_app" $?
[ -x "$V1_BIN" ]; check "build.v1_binary" $?
[ -x "$V2_BIN" ]; check "build.v2_binary" $?
[ -x "$CLI" ]; check "build.cli_app" $?

# --- free the Mach namespace: no launchd job may own the service -------------
"$CLI" --cli unregister >>"$EVIDENCE" 2>&1 || true
launchctl bootout "$DOMAIN/$LABEL" >>"$EVIDENCE" 2>&1 || true
pkill -f "Build/Products/Debug/TorrentinoEngineAgent" 2>/dev/null || true
pkill -f "Contents/Library/LaunchAgents/TorrentinoEngineAgent" 2>/dev/null || true
rm -rf "$ENGINE_DIR"; log "removed $ENGINE_DIR"
sleep 1

# --- v1: fresh install --------------------------------------------------------
log "--- v1: fresh install ---"
start_job "$V1_BIN" v1
agent_running; check "v1.job_running" $?
mach_endpoint; check "v1.mach_endpoint" $?
run_cli hello
echo "$CLI_OUT" | grep -q "version=1.0.0-wp02-v1"; check "v1.hello_version" $?
run_cli increment; echo "$CLI_OUT" | grep -q "counter=1"; check "v1.increment_1" $?
run_cli increment; echo "$CLI_OUT" | grep -q "counter=2"; check "v1.increment_2" $?
run_cli health; echo "$CLI_OUT" | grep -q "format=v1"; check "v1.health_format" $?
M="$(magic)"; log "counter.dat magic=$M"
[ "$M" = "TTC1" ]; check "v1.magic_on_disk" $?
stop_job
echo "$STOP_LINE" | grep -q "last exit code = 0"; check "v1.sigterm_exit0" $?

# --- v2: transparent migration of the v1 store --------------------------------
log "--- v2: migration ---"
start_job "$V2_BIN" v2
agent_running; check "v2.job_running" $?
mach_endpoint; check "v2.mach_endpoint" $?
run_cli hello
echo "$CLI_OUT" | grep -q "version=1.0.0-wp02-v2"; check "v2.hello_version" $?
run_cli get-counter
echo "$CLI_OUT" | grep -q "OK counter=2"; check "v2.value_preserved" $?
run_cli increment
echo "$CLI_OUT" | grep -q "counter=3"; check "v2.increment_3" $?
run_cli health; echo "$CLI_OUT" | grep -q "format=v2"; check "v2.health_format" $?
M="$(magic)"; log "counter.dat magic=$M"
[ "$M" = "TTC2" ]; check "v2.magic_migrated_on_persist" $?
stop_job
echo "$STOP_LINE" | grep -q "last exit code = 0"; check "v2.sigterm_exit0" $?

# --- downgrade block: v1 binary must refuse the v2 store ----------------------
log "--- v1 on v2 data: downgrade block ---"
cp "$COUNTER" "$OUT_DIR/counter-v2.dat" 2>/dev/null || true
"$V1_BIN" >>"$EVIDENCE" 2>&1
DG_RC=$?
log "v1 direct launch on v2 data rc=$DG_RC"
[ "$DG_RC" -eq 78 ]; check "downgrade.exit_78" $?
grep -q "Downgrade blocked" "$EVIDENCE"; check "downgrade.fatal_logged" $?
agent_running; [ $? -ne 0 ]; check "downgrade.no_listener_started" $?

# --- checksum validation: flipped byte must be rejected, not overwritten ------
log "--- v2 on corrupted data: checksum block ---"
printf '\xff' | dd of="$COUNTER" bs=1 seek=4 count=1 conv=notrunc >>"$EVIDENCE" 2>&1
"$V2_BIN" >>"$EVIDENCE" 2>&1
COR_RC=$?
log "v2 direct launch on corrupt data rc=$COR_RC"
[ "$COR_RC" -eq 1 ]; check "corrupt.exit_1" $?
grep -q "counter store corrupt" "$EVIDENCE"; check "corrupt.fatal_logged" $?

# --- summary -------------------------------------------------------------------
{
  echo "# WP-02 update/downgrade evidence — $(date)"
  echo
  echo "- v1 build: \`$V1_DD\` (SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG COUNTER_FORMAT_V1')"
  echo "- v2 build: \`$V2_DD\`"
  echo "- Engine dir: \`$ENGINE_DIR\`"
  echo "- Raw log: \`evidence.log\`"
  echo
  echo "| Check | Result |"
  echo "| --- | --- |"
  OLDIFS="$IFS"; IFS="|"
  for r in $RESULTS; do [ -n "$r" ] && echo "| ${r#* } | ${r%% *} |"; done
  IFS="$OLDIFS"
  echo
  echo "PASS=$PASS FAIL=$FAIL"
} > "$OUT_DIR/EVIDENCE.md"

log "=== SUMMARY PASS=$PASS FAIL=$FAIL ==="
log "evidence: $OUT_DIR/EVIDENCE.md"
[ "$FAIL" -eq 0 ]
