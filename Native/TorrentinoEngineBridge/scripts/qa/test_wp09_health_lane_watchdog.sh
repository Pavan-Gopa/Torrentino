#!/usr/bin/env bash
#
# QA WP-09 - Health lane is distinct; watchdog disabled (no false restart).
#
# Axis 12 of the WP-09 plan. The product deliberately ships WITHOUT a
# restart-on-idle watchdog: crash-loop protection and safe recovery are owned
# by CrashLoopGuard / SystemConditionMonitor / restartEngineSafely, never by a
# timer that force-restarts the engine (which would violate the "no false
# restart" WP-14 gate). The liveness lane (AgentHealthLane) must also be a
# distinct accounting surface from engine work: command-lane admission
# (tryBeginCommand / commandLimit) is tracked separately from engine ticks
# (noteEngineTick / noteEngineFailure).
#
# This is a source-contract test (same style as test_wp08_accessibility.sh):
# it asserts the product sources carry the contract and that NO watchdog
# restart/kill code path exists. It does not execute product code.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

AGENT_DIR="${NATIVE_DIR}/TorrentinoEngineAgent"
APP_DIR="${NATIVE_DIR}/TorrentinoApp"
AGENT_SERVICE="${AGENT_DIR}/Agent/AgentService.swift"
RUNTIME="${AGENT_DIR}/Agent/AgentRuntime.swift"
COORDINATOR="${AGENT_DIR}/Transfer/TransferCoordinator.swift"
CLIENT_TYPES="${APP_DIR}/EngineClient/EngineClientTypes.swift"
CLIENT="${APP_DIR}/EngineClient/EngineClient.swift"
VIEWMODEL="${APP_DIR}/Features/TorrentListViewModel.swift"

[[ -f "${AGENT_SERVICE}" ]] || qa_die "AgentService.swift missing"
[[ -f "${RUNTIME}" ]]       || qa_die "AgentRuntime.swift missing"
[[ -f "${COORDINATOR}" ]]  || qa_die "TransferCoordinator.swift missing"
[[ -f "${CLIENT_TYPES}" ]]  || qa_die "EngineClientTypes.swift missing"
[[ -f "${CLIENT}" ]]        || qa_die "EngineClient.swift missing"
[[ -f "${VIEWMODEL}" ]]     || qa_die "TorrentListViewModel.swift missing"

python3 - "${AGENT_DIR}" "${APP_DIR}" "${AGENT_SERVICE}" "${RUNTIME}" "${COORDINATOR}" "${CLIENT_TYPES}" "${CLIENT}" "${VIEWMODEL}" <<'PY'
import re
import sys
from pathlib import Path

agent_dir     = Path(sys.argv[1])
app_dir       = Path(sys.argv[2])
service_src   = Path(sys.argv[3]).read_text(encoding="utf-8")
runtime_src   = Path(sys.argv[4]).read_text(encoding="utf-8")
coord_src     = Path(sys.argv[5]).read_text(encoding="utf-8")
client_types_src = Path(sys.argv[6]).read_text(encoding="utf-8")
client_src    = Path(sys.argv[7]).read_text(encoding="utf-8")
viewmodel_src = Path(sys.argv[8]).read_text(encoding="utf-8")
issues = []

# 1. healthSnapshot must explicitly report watchdog disabled (not unknown,
#    not enabled). This is the product contract that there is no watchdog.
if '"watchdog": "disabled"' not in service_src:
    issues.append("AgentService.healthSnapshot does not pin watchdog = disabled")

# 2. healthSnapshot must report a distinct liveness lane label.
if '"healthLane": "liveness"' not in service_src:
    issues.append("AgentService.healthSnapshot does not declare healthLane = liveness")

# 3. The app client surfaces watchdog as a typed field (so UI can show it is
#    disabled, and so a future change is visible rather than silent).
if "watchdog" not in client_types_src:
    issues.append("EngineClientTypes does not surface a watchdog field to the UI")

# 4. AgentHealthLane is a distinct class with its own command-lane admission
#    budget, separate from engine tick/failure accounting.
if "class AgentHealthLane" not in service_src:
    issues.append("AgentHealthLane distinct liveness class is absent")
if "tryBeginCommand" not in service_src or "commandLimit" not in service_src:
    issues.append("command-lane admission (tryBeginCommand/commandLimit) missing")
if "noteEngineTick" not in service_src or "noteEngineFailure" not in service_src:
    issues.append("engine tick/failure accounting missing on health lane")

# 5. NEGATIVE: no watchdog timer that force-restarts / kills the engine.
#    Restart safety is owned by restartEngineSafely + CrashLoopGuard only.
agent_all = "\n".join(p.read_text(encoding="utf-8", errors="ignore")
                      for p in agent_dir.rglob("*.swift"))
app_all   = "\n".join(p.read_text(encoding="utf-8", errors="ignore")
                      for p in app_dir.rglob("*.swift"))
combined  = agent_all + "\n" + app_all

# A watchdog that restarts the engine would look like a periodic timer /
# dispatch source that calls terminate/relaunch on idle. Forbid these.
watchdog_restart = re.findall(
    r'watchdog[^"\n]{0,40}\b(?:terminate|relaunch|kill|restart|exit)\w*',
    combined, re.IGNORECASE)
# Filter out the harmless "watchdog": "disabled" snapshot string and comments.
real = [w for w in watchdog_restart
        if 'disabled' not in w.lower() and '//' not in w]
if real:
    issues.append("watchdog restart/kill code path present: " + repr(real[:3]))

# 6. restartEngineSafely is the legitimate, crash-loop-guarded recovery path
#    (not a watchdog). TransferCoordinator must handle the .restartEngineSafely
#    command and clear safeRecovery on success; the UI must be able to invoke it.
if ".restartEngineSafely" not in coord_src:
    issues.append("TransferCoordinator does not handle the .restartEngineSafely command")
if "safeRecovery = false" not in coord_src:
    issues.append("restartEngineSafely path does not clear safeRecovery on success")
if "markSafeRecovery" not in runtime_src:
    issues.append("safe-recovery accounting (markSafeRecovery) missing on runtime/health lane")
if "restartEngineSafely" not in client_src:
    issues.append("EngineClient does not expose restartEngineSafely to the UI")
if "restartEngineSafely" not in viewmodel_src:
    issues.append("TorrentListViewModel does not make restartEngineSafely user-invokable")

if issues:
    print("[FAIL] WP-09 health-lane/watchdog contract:")
    for i in issues:
        print("  - " + i)
    sys.exit(1)
print("[ok] WP-09 health lane distinct; watchdog disabled; recovery via restartEngineSafely")
PY

echo "WP-09 health-lane/watchdog: PASS"
