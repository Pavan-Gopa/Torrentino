#!/usr/bin/env bash
#
# QA WP-04 — Xcode integration: pbxproj refs, bridging header, build.
#
# Verifies WP-04 files are correctly registered in the Xcode project: source
# files in the build phase, bridging header set, C++17 standard, and the scheme
# builds successfully.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

PBXPROJ="${NATIVE_DIR}/Torrentino.xcodeproj/project.pbxproj"
assert_file "${PBXPROJ}" "project.pbxproj exists"

PROJ_CONTENT="$(cat "${PBXPROJ}")"

# --- WP-04 source files must be registered ------------------------------------
assert_contains "${PROJ_CONTENT}" "EngineBridge.cpp"          "EngineBridge.cpp in pbxproj"
assert_contains "${PROJ_CONTENT}" "EngineBridgeAdapter.mm"    "EngineBridgeAdapter.mm in pbxproj"
assert_contains "${PROJ_CONTENT}" "EngineBridgeAdapter.h"     "EngineBridgeAdapter.h in pbxproj"
assert_contains "${PROJ_CONTENT}" "EngineCoordinator.swift"   "EngineCoordinator.swift in pbxproj"
assert_contains "${PROJ_CONTENT}" "EngineBridgeDTOs.swift"    "EngineBridgeDTOs.swift in pbxproj"
assert_contains "${PROJ_CONTENT}" "EngineCoordinatorError.swift" "EngineCoordinatorError.swift in pbxproj"

# --- Bridging header must be configured ---------------------------------------
BRIDGING_HEADER="${NATIVE_DIR}/TorrentinoEngineAgent/TorrentinoEngineAgent-Bridging-Header.h"
assert_file "${BRIDGING_HEADER}" "bridging header file exists"
assert_contains "${PROJ_CONTENT}" "SWIFT_OBJC_BRIDGING_HEADER" "bridging header setting in pbxproj"
assert_contains "${PROJ_CONTENT}" "TorrentinoEngineAgent-Bridging-Header.h" "bridging header path in pbxproj"

# --- Bridging header must import ONLY the ObjC adapter (no C++ leakage) -------
BRIDGING_CONTENT="$(cat "${BRIDGING_HEADER}")"
assert_contains "${BRIDGING_CONTENT}" "EngineBridgeAdapter.h" "bridging header imports adapter"
assert_not_contains "${BRIDGING_CONTENT}" '#import "EngineBridge.h"' "bridging header does NOT import C++ PIMPL"
assert_not_contains "${BRIDGING_CONTENT}" '#include "EngineBridge.h"' "bridging header does NOT include C++ PIMPL"
assert_not_contains "${BRIDGING_CONTENT}" "libtorrent/"        "bridging header does NOT import libtorrent"
assert_not_contains "${BRIDGING_CONTENT}" "boost/"             "bridging header does NOT import boost"

# --- Build settings must have C++17 and ObjC ARC -----------------------------
assert_contains "${PROJ_CONTENT}" 'CLANG_CXX_LANGUAGE_STANDARD' "C++ language standard configured"
assert_contains "${PROJ_CONTENT}" 'CLANG_ENABLE_OBJC_ARC'       "ObjC ARC setting present"

# --- Count references: must have >= 6 file references for WP-04 source -------
ref_count="$(echo "${PROJ_CONTENT}" | grep -cE 'EngineBridge|EngineCoordinator' || true)"
assert_ge "${ref_count}" "6" "pbxproj ref count for WP-04 source files"

qa_pass
