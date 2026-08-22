#!/usr/bin/env bash
# WP-13 security engagement — adversarial redactor semantics probe.
# Scope: verify the COMPILED redactor (RedactedLogFileManager.redact, source of
# truth compiled into the agent from PersistenceStore.swift) against hostile
# secret vectors: plain query params, private-tracker key=/uid=/authkey= query
# styles, path-embedded passkeys, yaml-ish "password: value", JSON secrets
# (balanced AND unterminated/unbalanced-quote), Authorization headers, user
# paths, word-boundary false positives, and newline safety.
# SEC-3/SEC-4 closure: the four former documented-gap vectors are now HARD
# requirements (a surviving marker fails the run), as is the unterminated-quote
# vector that used to be a documented claim mismatch.
# Method: the script extracts the verbatim redact() body from the production
# source at run time, compiles it standalone with swiftc in a mktemp dir, and
# asserts expected behavior. Local fixtures only; no product code is modified.
# Exit 0 = all covered vectors redacted and no false positives.
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
  echo "mirror-sanity: mirror declares $RULES_MIRROR regex rules (compiled source declares 7 rules in one patterns array; authoritative parity: WP13DiagnosticsSecurityTests lockstep XCTest)"
  if [[ "$RULES_MIRROR" != "7" ]]; then echo "WARN: mirror rule count changed ($RULES_MIRROR != 7) — re-verify lockstep"; fi
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
/// Inverse direction: ordinary words / structures must NOT be destroyed.
func expectUntouched(_ name: String, _ input: String, _ mustSurvive: [String]) {
    let out = RedactorShim.redact(input)
    let destroyed = mustSurvive.filter { !out.contains($0) }
    if destroyed.isEmpty {
        print("PASS  [no-false-positive] \(name)")
    } else {
        print("FAIL  [FALSE POSITIVE] \(name): destroyed=\(destroyed) output=\(out.debugDescription)")
        failures += 1
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
// value — the fail-safe direction.
expectRedacted("json value over-redacts to next quote", #"{"password":"unterm LEAK2","k":"v"}"#,
               ["LEAK2"])

// --- Formerly-documented gaps, CLOSED by SEC-3 (now hard requirements) ---
expectRedacted("private-tracker key= param", "http://t.example/announce?key=DEADBEEF_KEY&uid=7", ["DEADBEEF_KEY"])
expectRedacted("uid= param", "http://t.example/announce?uid=42&key=K2", ["uid=42"])
expectRedacted("authkey= param", "http://t.example/announce.php?authkey=AUTHKEY_LEAK_9&zz=1", ["AUTHKEY_LEAK_9"])
expectRedacted("path-embedded tracker credential", "https://tracker.example.net/PATHKEY123456/announce", ["PATHKEY123456"])
expectRedacted("tracker path credential + query creds combined",
               "http://t.example/A1B2C3D4E5F6G7/announce?key=COMBO_Q_LEAK&uid=8",
               ["A1B2C3D4E5F6G7", "COMBO_Q_LEAK"])
expectRedacted("yaml-ish colon secret", "proxy password: COLON_LEAK", ["COLON_LEAK"])
expectRedacted("underscore-led announce token", "https://tracker.example.net/_SECRET12345/announce", ["_SECRET12345"])
expectRedacted("dash-led announce token", "https://tracker.example.net/-SECRET12345/announce", ["-SECRET12345"])

// Word-boundary safety: ordinary words containing marker substrings and
// announce URLs without an opaque first segment must survive untouched.
expectUntouched("keyboard/guid/guidd false-positive guard",
                "keyboard=QWERTY_OK monkey=brown guid=xyz guidd=abc",
                ["keyboard=QWERTY_OK", "monkey=brown", "guid=xyz", "guidd=abc"])
expectUntouched("ordinary announce url survives",
                "http://t.example/announce?info_hash=abcd&x=1",
                ["http://t.example/announce?info_hash=abcd&x=1"])

// --- SEC-3 announce policy (WP13-SEC-HARDEN-001 REVIEW-002): INTENTIONALLY
// --- BROAD. ANY opaque [A-Za-z0-9_-]{9,} first segment before
// --- /announce(.php)? is redacted BY DESIGN regardless of digits or leading
// --- character. The former digit-heuristic "survivor" framing is removed:
// --- these are covered vectors now.
expectRedacted("numeric-bearing announce segment",
               "https://tracker.example.net/tracker-path2/announce", ["tracker-path2"])
expectRedacted("underscore-led announce token without any digit",
               "https://tracker.example.net/_passkey_nodigit/announce", ["_passkey_nodigit"])
expectRedacted("dash-led announce token without any digit",
               "https://tracker.example.net/-PASSKEY-LED/announce", ["-PASSKEY-LED"])
expectRedacted("plain alphanumeric announce token without any digit",
               "https://tracker.example.net/AbCdEfGhIj/announce", ["AbCdEfGhIj"])
expectRedacted("former digit-heuristic survivor redacted by design",
               "http://t.example/tracker-path/announce", ["tracker-path"])
do {
    // Deliberate diagnostic-fidelity tradeoff: host and announce suffix
    // always survive; only the opaque segment is replaced.
    let out = RedactorShim.redact("https://tracker.example.net/_passkey_nodigit/announce.php")
    if out == "https://tracker.example.net/<redacted>/announce.php" {
        print("PASS  [announce-shape] host and announce suffix survive, segment replaced")
    } else {
        print("FAIL  [announce-shape] output=\(out.debugDescription)")
        failures += 1
    }
}

// --- Former CLAIM-MISMATCH (SEC-4), now CLOSED: an unterminated JSON value
// with NO later quote on the line must redact to end of line, per line.
expectRedacted("unbalanced json quote (no later quote)",
               #"{"password":"unterminated UNBAL_LEAK tail"#,
               ["UNBAL_LEAK"])
expectRedacted("escaped-unterminated json secret (escape pairs consumed)",
               #"{"password":"esc \" ESC_UNTERM_LEAK tail"#,
               ["ESC_UNTERM_LEAK"])
expectRedacted("trailing-backslash unterminated json secret",
               #"{"token":"TRAILBS_LEAK\"#,
               ["TRAILBS_LEAK"])
do {
    let input = "{\"password\":\"BALNL_LEAK\nKEEP_LINE_TWO\":\"safe\"}"
    let expected = "{\"password\":\"<redacted>\"\nKEEP_LINE_TWO\":\"safe\"}"
    let out = RedactorShim.redact(input)
    if !out.contains("BALNL_LEAK") && out == expected {
        print("PASS  [line-integrity] balanced-json value split by newline: following line byte-intact")
    } else {
        print("FAIL  [line-integrity] output=\(out.debugDescription) expected=\(expected.debugDescription)")
        failures += 1
    }
}
do {
    let out = RedactorShim.redact("password:\nPLAIN_NEXT_LINE")
    if out == "password:\nPLAIN_NEXT_LINE" {
        print("PASS  [separator-line-integrity] colon separator does not bridge lines")
    } else {
        print("FAIL  [separator-line-integrity] output=\(out.debugDescription)")
        failures += 1
    }
}
do {
    let input = "{\n\"secret\":\"UNBAL2_LEAK tail\nstill-no-quotes-here"
    let out = RedactorShim.redact(input)
    if !out.contains("UNBAL2_LEAK") && out.hasSuffix("\nstill-no-quotes-here") {
        print("PASS  [unterminated-json newline safety] truncated line redacted, following line intact")
    } else {
        print("FAIL  [unterminated-json newline safety] output=\(out.debugDescription)")
        failures += 1
    }
}

if failures > 0 {
    print("RESULT: FAIL (\(failures) vector(s) survived or were falsely destroyed by the compiled redactor)")
    exit(1)
}
print("RESULT: PASS — compiled redactor scrubs all covered vectors incl. tracker styles and unterminated JSON values")
SWIFT_EOF
sed -i '' -e '/^REDACT_METHOD$/{r '"$TMP"'/redact_method.swift' -e 'd;}' "$TMP/main.swift"

swiftc -O -o "$TMP/probe" "$TMP/main.swift" 2>&1 | { grep -v "warning" || true; }
"$TMP/probe"
