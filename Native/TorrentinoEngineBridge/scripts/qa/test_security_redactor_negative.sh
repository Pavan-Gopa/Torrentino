#!/usr/bin/env bash
# WP-13 security engagement — adversarial redactor semantics probe.
# Scope: verify the COMPILED redactor (RedactedLogFileManager.redact, source of
# truth compiled into the agent from PersistenceStore.swift) against hostile
# secret vectors, including styles the shipped tests do not cover
# (private-tracker key=/uid= query params, path-embedded passkeys, yaml-ish
# "password: value", unbalanced-quote over-redaction, newline safety).
# Method: the script extracts the verbatim redact() body from the production
# source at run time, compiles it standalone with swiftc in a mktemp dir, and
# asserts expected behavior. Local fixtures only; no product code is modified.
# Exit 0 = all covered vectors redacted and gap vectors behave as documented.
set -euo pipefail
cd "$(dirname "$0")/../../../.."

SRC="Native/TorrentinoEngineAgent/Persistence/PersistenceStore.swift"
MIRROR="Native/TorrentinoEngineAgent/Agent/RedactedLogFileManager.swift"
[[ -f "$SRC" ]] || { echo "FATAL: compiled redactor source not found: $SRC"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Extract the verbatim production redact() method.
awk '/public static func redact\(/{f=1} f{print} f && /^    \}$/{exit}' "$SRC" > "$TMP/redact_method.swift"
grep -q "public static func redact" "$TMP/redact_method.swift" || { echo "FATAL: extraction failed"; exit 2; }
grep -q "return redacted" "$TMP/redact_method.swift" || { echo "FATAL: extraction truncated"; exit 2; }

# 2. Mirror lockstep sanity (authoritative parity lives in
#    WP13DiagnosticsSecurityTests.testMirrorRedactorStaysInLockstepWithCompiledRedactor).
if [[ -f "$MIRROR" ]]; then
  RULES_MIRROR="$(grep -c 'try? NSRegularExpression(' "$MIRROR" || true)"
  echo "mirror-sanity: mirror declares $RULES_MIRROR regex rules (compiled source declares 4 rules in one patterns array; authoritative parity: WP13DiagnosticsSecurityTests lockstep XCTest)"
  if [[ "$RULES_MIRROR" != "4" ]]; then echo "WARN: mirror rule count changed ($RULES_MIRROR != 4) — re-verify lockstep"; fi
fi

# 3. Harness: wrap the verbatim method, run hostile vectors.
cat > "$TMP/main.swift" <<'SWIFT_EOF'
import Foundation

enum RedactorShim {
REDACT_METHOD
}

var failures = 0
func expectRedacted(_ name: String, _ input: String, _ leaks: [String]) {
    let out = RedactorShim.redact(input)
    let surviving = leaks.filter { out.contains($0) }
    if surviving.isEmpty {
        print("PASS  [redacted] \(name)")
    } else {
        print("FAIL  [LEAK] \(name): surviving=\(surviving) output=\(out.debugDescription)")
        failures += 1
    }
}
func expectGap(_ name: String, _ input: String, _ marker: String) {
    let out = RedactorShim.redact(input)
    if out.contains(marker) {
        print("GAP-CONFIRMED  \(name): marker survives redaction (documented residual)")
    } else {
        print("GAP-CLOSED     \(name): marker now redacted — update SECURITY_FINDINGS.md residual")
    }
}

// --- Covered vectors (must be scrubbed) ---
expectRedacted("plain query passkey", "announce?passkey=SECRET_PK1&x=1", ["SECRET_PK1"])
expectRedacted("plain query token", "announce?token=SECRET_TK1", ["SECRET_TK1"])
expectRedacted("json escaped-quote secret", #"json probe {"password":"pre\"QUOTE_LEAK b\\BS_LEAK"}"#,
               ["QUOTE_LEAK", "BS_LEAK"])
expectRedacted("json proxyPassword", #"\{"proxyPassword":"PW_JSON_LEAK"\}"#, ["PW_JSON_LEAK"])
expectRedacted("bearer header", "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.LEAK", ["eyJhbGciOiJIUzI1NiJ9.LEAK"])
expectRedacted("user path", "file /Users/alice/secret-dir/x.torrent ok", ["/Users/alice"])
expectRedacted("volume path", "seed /Volumes/Backups/x ok", ["/Volumes/Backups"])
expectRedacted("multiline stays per-line", "a password=PW_A\nb token=TK_B\nc",
               ["PW_A", "TK_B"])
// Newline safety: the second line must survive intact (no cross-line match).
do {
    let out = RedactorShim.redact("a password=PW_A\nb token=TK_B\nc")
    if out.contains("b token=<redacted>") && out.contains("\nc") {
        print("PASS  [newline-safety] no cross-line consumption")
    } else {
        print("FAIL  [newline-safety] output=\(out.debugDescription)")
        failures += 1
    }
}
// Balanced-line over-redaction: a later quote lets the JSON rule consume the
// value — the documented fail-safe direction.
expectRedacted("json value over-redacts to next quote", #"{"password":"unterm LEAK2","k":"v"}"#,
               ["LEAK2"])
// CLAIM-MISMATCH probe (WP-13 engagement): with NO later quote on the line the
// JSON rule cannot match and the secret survives verbatim. The source comment
// claims over-redaction is fail-safe ("never a secret leak"); the compiled
// behavior contradicts that for truncated/unterminated lines. Tracked as
// SECURITY_FINDINGS.md SEC-4. The script asserts CURRENT behavior so a future
// fix flips this line to CLAIM-MISMATCH-CLOSED.
do {
    let input = #"{"password":"unterminated UNBAL_LEAK tail"#
    let out = RedactorShim.redact(input)
    if out.contains("UNBAL_LEAK") {
        print("CLAIM-MISMATCH-CONFIRMED  unbalanced json quote (no later quote): secret survives — see SEC-4")
    } else {
        print("CLAIM-MISMATCH-CLOSED     unbalanced json quote: now redacted — update SECURITY_FINDINGS.md SEC-4")
    }
}

// --- Documented gap vectors (current behavior: marker SURVIVES) ---
expectGap("private-tracker key= param", "http://t.example/announce?key=DEADBEEF_KEY&uid=7", "DEADBEEF_KEY")
expectGap("path-embedded tracker credential", "https://tracker.example.net/PATHKEY123456/announce", "PATHKEY123456")
expectGap("uid= param", "http://t.example/announce?uid=42&key=K2", "uid=42")
expectGap("yaml-ish colon secret", "proxy password: COLON_LEAK", "COLON_LEAK")

if failures > 0 {
    print("RESULT: FAIL (\(failures) leak vector(s) survived the compiled redactor)")
    exit(1)
}
print("RESULT: PASS — compiled redactor scrubs all covered vectors; gap vectors match the documented residuals")
SWIFT_EOF
sed -i '' -e '/^REDACT_METHOD$/{r '"$TMP"'/redact_method.swift' -e 'd;}' "$TMP/main.swift"

swiftc -O -o "$TMP/probe" "$TMP/main.swift" 2>&1 | { grep -v "warning" || true; }
"$TMP/probe"
