#!/usr/bin/env bash
#
# QA WP-04 — PIMPL isolation: no C++ types visible to Swift API.
#
# Verifies the PIMPL boundary: the bridging header only imports the ObjC
# adapter (no C++ types leak to Swift), the adapter header uses only Foundation
# types, and EngineBridge.h is not imported anywhere Swift can see it.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

BRIDGING_HEADER="${NATIVE_DIR}/TorrentinoEngineAgent/TorrentinoEngineAgent-Bridging-Header.h"
ADAPTER_H="${BRIDGE_DIR}/adapter/EngineBridgeAdapter.h"
BRIDGE_H="${BRIDGE_DIR}/bridge/EngineBridge.h"

assert_file "${BRIDGING_HEADER}" "bridging header exists"
assert_file "${ADAPTER_H}"      "adapter header exists"
assert_file "${BRIDGE_H}"       "EngineBridge.h exists"

BRIDGING_CONTENT="$(cat "${BRIDGING_HEADER}")"
ADAPTER_H_CONTENT="$(cat "${ADAPTER_H}")"
BRIDGE_H_CONTENT="$(cat "${BRIDGE_H}")"

# --- Bridging header must NOT import C++ PIMPL or third-party -----------------
assert_contains "${BRIDGING_CONTENT}" "EngineBridgeAdapter.h" \
	"bridging header imports ObjC adapter"
assert_not_contains "${BRIDGING_CONTENT}" '#import "EngineBridge.h"' \
	"bridging header does NOT import C++ PIMPL"
assert_not_contains "${BRIDGING_CONTENT}" '#include "EngineBridge.h"' \
	"bridging header does NOT include C++ PIMPL"
assert_not_contains "${BRIDGING_CONTENT}" "#include" \
	"bridging header uses no C++ includes"
assert_not_contains "${BRIDGING_CONTENT}" "libtorrent/" \
	"bridging header has no libtorrent header includes"
assert_not_contains "${BRIDGING_CONTENT}" "boost/" \
	"bridging header has no boost header includes"
assert_not_contains "${BRIDGING_CONTENT}" "std::" \
	"bridging header has no std:: types"

# --- Adapter header only uses Foundation types --------------------------------
assert_contains "${ADAPTER_H_CONTENT}" "#import <Foundation/Foundation.h>" \
	"adapter imports only Foundation"
assert_not_contains "${ADAPTER_H_CONTENT}" "#include" \
	"adapter has no C++ includes"
adapter_std_count="$(grep -v '^[[:space:]]*//' "${ADAPTER_H}" | grep -c 'std::' || true)"
assert_eq "${adapter_std_count}" "0" "adapter exposes no std:: types in code"
adapter_lt_count="$(grep -v '^[[:space:]]*//' "${ADAPTER_H}" | grep -c 'libtorrent' || true)"
assert_eq "${adapter_lt_count}" "0" "adapter exposes no libtorrent types in code"
adapter_boost_count="$(grep -v '^[[:space:]]*//' "${ADAPTER_H}" | grep -c 'boost' || true)"
assert_eq "${adapter_boost_count}" "0" "adapter exposes no boost types in code"
assert_not_contains "${ADAPTER_H_CONTENT}" "EngineBridge.h" \
	"adapter header does not import C++ PIMPL"

# --- All adapter method params/returns are NSData/NSError (ObjC-safe) ---------
method_count="$(echo "${ADAPTER_H_CONTENT}" | grep -cE '^\- \(' || true)"
assert_ge "${method_count}" "10" "adapter has >= 10 ObjC methods"

nsdata_returns="$(echo "${ADAPTER_H_CONTENT}" | grep -cE 'NSData \*' || true)"
assert_ge "${nsdata_returns}" "8" "adapter methods use NSData (JSON envelopes)"

# --- C++ PIMPL uses 'private: struct Impl' (types hidden) --------------------
assert_contains "${BRIDGE_H_CONTENT}" "struct Impl" \
	"EngineBridge uses PIMPL (struct Impl)"
assert_contains "${BRIDGE_H_CONTENT}" "std::unique_ptr<Impl> impl_" \
	"PIMPL pointer is unique_ptr (private)"

qa_pass
