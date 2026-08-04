#!/usr/bin/env bash
#
# QA WP-10 - delete-free native bridge ABI.
#
# The Swift agent owns manifest-scoped Trash. The C++ facade, ObjC adapter, and
# Swift bridge DTO must not expose a delete_files/delete-files/deleteFiles
# switch that could route payload deletion through libtorrent.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

BRIDGE_H="${NATIVE_DIR}/TorrentinoEngineBridge/bridge/EngineBridge.h"
BRIDGE_CPP="${NATIVE_DIR}/TorrentinoEngineBridge/bridge/EngineBridge.cpp"
ADAPTER_H="${NATIVE_DIR}/TorrentinoEngineBridge/adapter/EngineBridgeAdapter.h"
ADAPTER_MM="${NATIVE_DIR}/TorrentinoEngineBridge/adapter/EngineBridgeAdapter.mm"
COORDINATOR="${NATIVE_DIR}/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift"
DTO="${NATIVE_DIR}/TorrentinoEngineAgent/EngineCoordinator/EngineBridgeDTOs.swift"
SMOKE="${NATIVE_DIR}/TorrentinoEngineBridge/bridge/bridge_smoke.cpp"

for file in "${BRIDGE_H}" "${BRIDGE_CPP}" "${ADAPTER_H}" "${ADAPTER_MM}" \
	"${COORDINATOR}" "${DTO}" "${SMOKE}"; do
	[[ -f "${file}" ]] || qa_die "missing delete-free ABI input: ${file}"
done

python3 - "${BRIDGE_H}" "${BRIDGE_CPP}" "${ADAPTER_H}" "${ADAPTER_MM}" \
	"${COORDINATOR}" "${DTO}" "${SMOKE}" <<'PY'
import re
import sys
from pathlib import Path

sources = [Path(path).read_text(encoding="utf-8") for path in sys.argv[1:]]

def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*", "", text)

code = [strip_comments(text) for text in sources]
bridge_h, bridge_cpp, adapter_h, adapter_mm, coordinator, dto, smoke = code
issues = []

for text, description, needles in (
    (bridge_h + bridge_cpp, "C++ bridge", ("delete_files", "delete-files", "deleteFiles")),
    (adapter_h + adapter_mm, "ObjC adapter", ("delete_files", "delete-files", "deleteFiles")),
    (coordinator + dto, "Swift bridge DTO/coordinator", ("delete_files", "delete-files", "deleteFiles")),
):
    for needle in needles:
        if needle in text:
            issues.append(f"{description} exposes forbidden {needle} ABI text")

if not re.search(r"prepareRemoval\(const TorrentRecordID& id\)", bridge_h):
    issues.append("C++ prepareRemoval signature is not the token-only form")
if not re.search(r"commitRemoval\(const RemovalToken& token\)", bridge_h):
    issues.append("C++ commitRemoval signature is not the token-only form")
if "lt::remove_flags_t flags{}" not in bridge_cpp:
    issues.append("C++ commitRemoval does not explicitly use empty remove flags")
if "session_->remove_torrent(handle.value(), flags)" not in bridge_cpp:
    issues.append("C++ commitRemoval call shape changed from empty flags")
if "prepareRemovalWithPayloadData" not in adapter_h or "commitRemovalWithTokenData" not in adapter_h:
    issues.append("ObjC token-only removal methods are missing")

token_start = dto.find("public struct RemovalTokenDTO")
token_end = dto.find("public struct RemovalResultDTO", token_start)
if token_start < 0 or token_end < 0:
    issues.append("Swift RemovalTokenDTO is missing")
else:
    token_body = dto[token_start:token_end]
    if "torrentID" not in token_body or "nonce" not in token_body:
        issues.append("Swift RemovalTokenDTO lost its stable token fields")

if "RemovalToken token" not in smoke or "bridge.prepareRemoval" not in smoke:
    issues.append("bridge smoke removal lifecycle assertion is missing")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    raise SystemExit(1)

print("OK: C++/ObjC++/Swift removal ABI is token-only and uses empty libtorrent flags")
PY

qa_ok "delete-free bridge and adapter ABI"
qa_pass
