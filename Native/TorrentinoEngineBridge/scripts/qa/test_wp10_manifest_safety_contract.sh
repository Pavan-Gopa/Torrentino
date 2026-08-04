#!/usr/bin/env bash
#
# QA WP-10 - manifest-scoped trash and descriptor-based directory verification.
#
# Runtime XCTest coverage proves the observable behavior. This contract keeps
# the implementation details that make the behavior safe from silently
# regressing: leaf-first ordering, one O_NOFOLLOW directory descriptor, and a
# final chain/identity check immediately before the injected Trash provider.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

MANIFEST="${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/RemovalManifest.swift"
TRASH="${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/TrashService.swift"
TESTS="${NATIVE_DIR}/Tests/TorrentinoEngineAgentTests/WPSafeFileOperationsTests.swift"

for file in "${MANIFEST}" "${TRASH}" "${TESTS}"; do
	[[ -f "${file}" ]] || qa_die "missing WP-10 manifest safety input: ${file}"
done

python3 - "${MANIFEST}" "${TRASH}" "${TESTS}" <<'PY'
import sys
from pathlib import Path

manifest, trash, tests = [Path(path).read_text(encoding="utf-8") for path in sys.argv[1:]]
issues = []

def function_body(source: str, marker: str) -> str:
    start = source.find(marker)
    if start < 0:
        return ""
    opening = source.find("{", start)
    if opening < 0:
        return ""
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    return ""

ordered = function_body(manifest, "func orderedEntries()")
if "case (.file, .directory)" not in ordered:
    issues.append("orderedEntries does not put files before directories")
if "lhsDepth > rhsDepth" not in ordered:
    issues.append("orderedEntries does not sort directories deepest-first")

empty = function_body(manifest, "static func verifyDirectoryEmpty(absolutePath: String)")
for needle, description in (
    ("O_NOFOLLOW", "O_NOFOLLOW directory open"),
    ("Darwin.open", "directory descriptor open"),
    ("Darwin.fstat", "descriptor identity check"),
    ("Darwin.fdopendir", "descriptor directory scan"),
    ("Darwin.readdir", "directory entry scan"),
):
    if needle not in empty:
        issues.append(f"{description} is missing from verifyDirectoryEmpty")
if empty.count("Darwin.open") != 1:
    issues.append("verifyDirectoryEmpty must use exactly one open call")
if "contentsOfDirectory" in empty or "FileManager" in empty:
    issues.append("verifyDirectoryEmpty fell back to a path-based FileManager scan")

for needle, description in (
    ("FileSafetyValidator.verifyChain", "full chain verification before Trash"),
    ("FileSafetyValidator.verifyFileIdentity", "file identity verification before Trash"),
    ("FileSafetyValidator.verifyDirectoryEmpty", "directory emptiness verification before Trash"),
    ("trash.moveToTrash(at: absolute)", "provider call is Trash-only"),
):
    if needle not in trash:
        issues.append(f"TrashService missing {description}")

for needle, description in (
    ("testWP10CommitRemovalTrashesEveryManifestItemAndRemovesRecord", "leaf-first full commit XCTest"),
    ("testWP10UnmanifestedSiblingSurvivesDirectoryTrash", "unmanifested sibling XCTest"),
    ("testWP10AncestorSymlinkSwapRefusedBeforeAnyMutation", "ancestor swap XCTest"),
    ("testWP10SameSizeReplacementRefusedByIdentity", "same-size replacement XCTest"),
    ("testWP10HardlinkSwapRefusedByIdentity", "hardlink swap XCTest"),
):
    if needle not in tests:
        issues.append(f"{description} is missing")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    raise SystemExit(1)

print("OK: manifest ordering, one-descriptor directory emptiness, chain, and identity gates are present")
PY

qa_ok "manifest-scoped Trash and descriptor safety contract"
qa_pass
