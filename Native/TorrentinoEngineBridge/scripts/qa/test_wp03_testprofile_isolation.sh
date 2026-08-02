#!/usr/bin/env bash
#
# QA WP-03 — TestProfile isolation: temp dir, not production, cleanup works.
#
# 1) Source contract against TestProfile.swift
# 2) Standalone Swift probe (creates profile, asserts path, tearDown)
# 3) Domain XCTest cleanup test
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

PROFILE_SWIFT="${NATIVE_DIR}/Tests/TestSupport/TestProfile.swift"
assert_file "${PROFILE_SWIFT}" "TestProfile.swift"

SRC="$(cat "${PROFILE_SWIFT}")"
assert_contains "${SRC}" "productionAppSupportMarker" "production path marker"
assert_contains "${SRC}" "Application Support/com.torrentino.app" "production marker value"
assert_contains "${SRC}" "mkdtemp" "uses mkdtemp"
assert_contains "${SRC}" "tearDown" "cleanup API"
assert_contains "${SRC}" "precondition" "hard guard against production path"
assert_not_contains "${SRC}" "FileManager.default.urls(for: .applicationSupportDirectory" \
	"must not resolve Application Support via FileManager search"

# --- Standalone probe: compile+run a minimal TestProfile clone logic ---------
# Mirrors product TestProfile isolation rules without linking XCTest products.
PROBE_DIR="$(qa_mktemp)"
PROBE_SWIFT="${PROBE_DIR}/profile_probe.swift"
cat > "${PROBE_SWIFT}" <<'SWIFT'
import Foundation

let productionMarker = "Application Support/com.torrentino.app"
let fm = FileManager.default
let template = fm.temporaryDirectory
    .appendingPathComponent("torrentino-test.XXXXXX", isDirectory: true)
    .path
var buffer = Array(template.utf8CString)
let result = buffer.withUnsafeMutableBufferPointer { ptr -> UnsafeMutablePointer<CChar>? in
    guard let base = ptr.baseAddress else { return nil }
    return mkdtemp(base)
}
guard let result else {
    fputs("FAIL mkdtemp\n", stderr)
    exit(1)
}
let path = String(cString: result)
if path.contains(productionMarker) {
    fputs("FAIL production path: \(path)\n", stderr)
    exit(1)
}
if !FileManager.default.fileExists(atPath: path) {
    fputs("FAIL dir missing: \(path)\n", stderr)
    exit(1)
}
let probeFile = (path as NSString).appendingPathComponent("marker.txt")
try! "ok".write(toFile: probeFile, atomically: true, encoding: .utf8)
try! FileManager.default.removeItem(atPath: path)
if FileManager.default.fileExists(atPath: path) {
    fputs("FAIL cleanup left dir: \(path)\n", stderr)
    exit(1)
}
print("OK isolated=\(path) cleaned=true")
SWIFT

qa_log "running isolated TestProfile probe…"
swift "${PROBE_SWIFT}" || qa_die "standalone TestProfile probe failed"

# --- XCTest cleanup assertion ----------------------------------------------
XCODEPROJ="${NATIVE_DIR}/Torrentino.xcodeproj"
LOG="$(qa_mktemp)/testprofile-xctest.log"
qa_log "running Domain testTestProfileCleanupRemovesDirectory…"
set +e
xcodebuild test \
	-project "${XCODEPROJ}" \
	-scheme Torrentino \
	-destination 'platform=macOS,arch=arm64' \
	-only-testing:TorrentinoDomainTests/TorrentinoDomainTests/testTestProfileCleanupRemovesDirectory \
	-only-testing:TorrentinoDomainTests/TorrentinoDomainTests/testTestProfileCreatesIsolatedTempDirectory \
	CODE_SIGN_IDENTITY="Developer ID Application" \
	DEVELOPMENT_TEAM=438UQRF7JV \
	2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}
set -e
[[ ${rc} -eq 0 ]] || qa_die "TestProfile XCTest isolation/cleanup failed (rc=${rc})"

qa_ok "TestProfile isolation + cleanup verified"
qa_pass
