#!/bin/bash
# Layer: WP-02 lifecycle evidence (registration -> Mach XPC -> crash -> shutdown).
# Role: drive the signed app binary headlessly (--cli) and record launchd evidence.
# Must-not: run as root, or mutate anything outside the engine dir + launchd job.
# Usage: APP_PATH=/path/to/Torrentino.app ./lifecycle_test.sh
# Exit: 0 if all checks pass, 1 otherwise.
# Contract: Native/Config/LIFECYCLE_CONTRACT.md
set -u -o pipefail

LABEL="com.torrentino.app.engine-agent"
DOMAIN="gui/$(id -u)"
TEAM="438UQRF7JV"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NATIVE_DIR="$(dirname "$SCRIPT_DIR")"
ENGINE_DIR="$HOME/Library/Application Support/com.torrentino.app/Engine"
DEFAULT_APP="$(ls -dt "$HOME/Library/Developer/Xcode/DerivedData"/Torrentino-*/Build/Products/Debug/Torrentino.app 2>/dev/null | head -1 || true)"
APP_PATH="${APP_PATH:-$DEFAULT_APP}"
OUT_DIR="${OUT_DIR:-$NATIVE_DIR/test-results/lifecycle-$(date +%Y%m%d-%H%M%S)}"
EVIDENCE="$OUT_DIR/evidence.log"
AGENT_BIN="$APP_PATH/Contents/Library/LaunchAgents/TorrentinoEngineAgent"
AGENT_PLIST="$APP_PATH/Contents/Library/LaunchAgents/$LABEL.plist"
CLI="$APP_PATH/Contents/MacOS/Torrentino"

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
agent_pid() { pgrep -f "Contents/Library/LaunchAgents/TorrentinoEngineAgent" | head -1 || true; }
agent_running() { [ -n "$(agent_pid)" ]; }
agent_gone() { ! agent_running; }
dump_launchctl() {
  log "+ launchctl print $DOMAIN/$LABEL"
  launchctl print "$DOMAIN/$LABEL" >>"$EVIDENCE" 2>&1 || log "(launchctl print failed: job not loaded)"
}
last_exit_code() {
  launchctl print "$DOMAIN/$LABEL" 2>/dev/null | sed -n 's/.*last exit code = \([0-9]*\).*/\1/p' | head -1
}
cleanup() {
  local rc=$? # preserve script verdict through the EXIT trap
  log "--- cleanup ---"
  pkill -f "Contents/Library/LaunchAgents/TorrentinoEngineAgent" 2>/dev/null || true
  "$CLI" --cli unregister >>"$EVIDENCE" 2>&1 || true
  launchctl bootout "$DOMAIN/$LABEL" >>"$EVIDENCE" 2>&1 || true
  exit $rc
}
trap cleanup EXIT

log "=== WP-02 lifecycle test $(date) ==="
log "APP_PATH=$APP_PATH"
log "OUT_DIR=$OUT_DIR"

# --- preflight: layout + signing -------------------------------------------
[ -x "$CLI" ]; check "preflight.app_binary_exists" $?
[ -x "$AGENT_BIN" ]; check "preflight.agent_embedded" $?
[ -f "$AGENT_PLIST" ]; check "preflight.plist_embedded" $?
plutil -lint "$AGENT_PLIST" >>"$EVIDENCE" 2>&1; check "preflight.plist_valid" $?

REQ_APP="identifier \"com.torrentino.app\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\""
REQ_AGENT="identifier \"com.torrentino.app.engine-agent\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\""
codesign --verify --strict "$APP_PATH" >>"$EVIDENCE" 2>&1; check "preflight.app_codesign_valid" $?
codesign --verify "-R=$REQ_APP" "$APP_PATH" >>"$EVIDENCE" 2>&1; check "preflight.app_requirement" $?
codesign --verify "-R=$REQ_AGENT" "$AGENT_BIN" >>"$EVIDENCE" 2>&1; check "preflight.agent_requirement" $?

# --- reset state ------------------------------------------------------------
log "--- reset state ---"
run_cli unregister
launchctl bootout "$DOMAIN/$LABEL" >>"$EVIDENCE" 2>&1 || true
pkill -f "Contents/Library/LaunchAgents/TorrentinoEngineAgent" 2>/dev/null || true
sleep 1
rm -rf "$ENGINE_DIR"; log "removed $ENGINE_DIR"

# --- SMAppService registration (RunAtLoad should spawn the agent) -----------
run_cli register
echo "$CLI_OUT" | grep -q "status=enabled" && [ "$CLI_RC" -eq 0 ]; check "register.enabled" $?
wait_for 15 agent_running; check "launchd.run_at_load_spawn" $?
PID1="$(agent_pid)"; log "agent pid1=$PID1"

# --- XPC round trips ---------------------------------------------------------
run_cli hello
echo "$CLI_OUT" | grep -q "OK hello version=1.0.0-wp02-v2 pid=$PID1"; check "xpc.hello" $?
run_cli health
echo "$CLI_OUT" | grep -q "OK health" && echo "$CLI_OUT" | grep -q "format=v2"; check "xpc.health" $?
run_cli increment; echo "$CLI_OUT" | grep -q "counter=1"; check "counter.increment_1" $?
run_cli increment; echo "$CLI_OUT" | grep -q "counter=2"; check "counter.increment_2" $?
run_cli increment; echo "$CLI_OUT" | grep -q "counter=3"; check "counter.increment_3" $?
run_cli get-counter; echo "$CLI_OUT" | grep -q "OK counter=3"; check "counter.get_3" $?

# --- single-instance lock ----------------------------------------------------
# Direct launch while PID1 is alive: the duplicate must take the lock, decline,
# and exit 0 without disturbing the original. Checks run immediately (later
# sections deliberately stop the agent).
"$AGENT_BIN" >>"$EVIDENCE" 2>&1; DUP_RC=$?
log "duplicate direct launch rc=$DUP_RC"
sleep 1 # let the duplicate fully exit before pid sampling
[ "$DUP_RC" -eq 0 ]; check "lock.duplicate_instance_exit0" $?
agent_running && [ "$(agent_pid)" = "$PID1" ]; check "lock.original_still_running" $?

# --- SIGKILL durability + KeepAlive crash-respawn ----------------------------
log "--- SIGKILL durability ---"
kill -9 "$PID1"
wait_for 10 agent_gone; check "crash.process_gone" $?
dump_launchctl
# launchd records signal deaths as "last terminating signal = Killed: 9" rather
# than a "last exit code"; either a non-zero exit code or a recorded terminating
# signal proves the abnormal end was observed.
LEX="$(last_exit_code)"
LSIG="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | sed -n 's/.*last terminating signal = \(.*\)/\1/p' | head -1)"
log "after SIGKILL: exit_code=${LEX:-<none>} terminating_signal=${LSIG:-<none>}"
{ [ -n "$LEX" ] && [ "$LEX" != "0" ]; } || [ -n "$LSIG" ]; check "crash.nonzero_exit_recorded" $?
log "sleeping 11s (launchd ThrottleInterval=10s respawn window)"
sleep 11
run_cli get-counter
echo "$CLI_OUT" | grep -q "OK counter=3"; check "crash.counter_survived_sigkill" $?
PID2="$(agent_pid)"; log "agent pid2=$PID2"
[ -n "$PID2" ] && [ "$PID2" != "$PID1" ]; check "crash.respawned_new_pid" $?

# --- graceful XPC shutdown (ack first, then exit 0) --------------------------
log "--- graceful XPC shutdown ---"
run_cli shutdown
echo "$CLI_OUT" | grep -q "acknowledged=true" && [ "$CLI_RC" -eq 0 ]; check "shutdown.xpc_ack" $?
wait_for 10 agent_gone; check "shutdown.process_exited" $?
dump_launchctl
LEX="$(last_exit_code)"; log "last exit code after XPC shutdown: ${LEX:-<none>}"
[ "$LEX" = "0" ]; check "shutdown.exit_code_0" $?

# --- Mach on-demand relaunch after clean exit --------------------------------
log "--- Mach on-demand relaunch ---"
run_cli hello
[ "$CLI_RC" -eq 0 ] && echo "$CLI_OUT" | grep -q "OK hello"; check "ondemand.hello_after_clean_exit" $?
PID3="$(agent_pid)"; log "agent pid3=$PID3"
[ -n "$PID3" ] && [ "$PID3" != "$PID2" ]; check "ondemand.new_pid" $?

# --- SIGTERM graceful signal path --------------------------------------------
log "--- SIGTERM graceful path ---"
kill -TERM "$PID3"
wait_for 10 agent_gone; check "signal.sigterm_exited" $?
dump_launchctl
LEX="$(last_exit_code)"; log "last exit code after SIGTERM: ${LEX:-<none>}"
[ "$LEX" = "0" ]; check "signal.sigterm_exit_code_0" $?

# --- unregister ---------------------------------------------------------------
run_cli unregister
echo "$CLI_OUT" | grep -q "status=notRegistered"; check "unregister.not_registered" $?
launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
[ $? -ne 0 ]; check "unregister.job_removed_from_launchd" $?

# --- summary -------------------------------------------------------------------
{
  echo "# WP-02 lifecycle evidence — $(date)"
  echo
  echo "- App: \`$APP_PATH\`"
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
