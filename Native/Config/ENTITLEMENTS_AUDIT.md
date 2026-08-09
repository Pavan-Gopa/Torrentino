# Entitlements & Security Posture Audit — WP-13

Authoritative review and justification of entitlements for **Torrentino Native macOS** (v1 Release track).

---

## 1. Executive Summary

Torrentino Native macOS is engineered with a **minimal-privilege model** for notarized Developer ID distribution.

- **No App Sandbox in v1:** App Sandbox is explicitly disabled in v1 due to BitTorrent network socket handling, LaunchAgent IPC architecture (`SMAppService`), and user-configured multi-volume storage paths.
- **Hardened Runtime Enabled:** `ENABLE_HARDENED_RUNTIME = YES` is enforced in `Native/Config/Shared.xcconfig` for both the main UI App (`Torrentino.app`) and the engine agent (`com.torrentino.app.engine-agent`).
- **No Debugger Attach / No get-task-allow:** `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` guarantees that release builds do not allow arbitrary task attachment or debugging.
- **Minimal Entitlement Files:** Both `Torrentino.entitlements` and `TorrentinoEngineAgent.entitlements` contain empty property dictionaries (`<dict></dict>`), declaring zero entitlement overrides or exception keys.

---

## 2. Target Entitlements Audit

### A. Torrentino UI App (`Torrentino.entitlements`)
- **Location:** `Native/Config/Entitlements/Torrentino.entitlements`
- **Contents:** `<dict></dict>` (empty)
- **Justifications:**
  - `com.apple.security.app-sandbox`: **OFF**. (v1 architecture uses LaunchAgent via `SMAppService` and direct user folder selection).
  - `com.apple.security.get-task-allow`: **OFF**. (Hardened runtime safety; prevented in production binaries).
  - `com.apple.security.network.client`: Not needed without sandbox (system permits outgoing connections by default).
  - `com.apple.security.network.server`: Not needed without sandbox (system permits listening sockets by default).
  - `com.apple.security.files.user-selected.read-write`: Not needed without sandbox.

### B. Torrentino Engine LaunchAgent (`TorrentinoEngineAgent.entitlements`)
- **Location:** `Native/Config/Entitlements/TorrentinoEngineAgent.entitlements`
- **Contents:** `<dict></dict>` (empty)
- **Justifications:**
  - `com.apple.security.app-sandbox`: **OFF**. (LaunchAgent requires unrestricted file access for torrent data storage across external volumes).
  - `com.apple.security.get-task-allow`: **OFF**. (Hardened runtime safety).
  - `com.apple.security.files.downloads.read-write`: Not needed without sandbox.

---

## 3. Code Signing & Hardened Runtime Posture (`Shared.xcconfig`)

| Build Setting | Value | Security Impact |
|---|---|---|
| `DEVELOPMENT_TEAM` | `438UQRF7JV` | Pinned Developer ID Team identifier. |
| `CODE_SIGN_IDENTITY` | `Developer ID Application` | Mandatory Developer ID signature. |
| `ENABLE_HARDENED_RUNTIME` | `YES` | Hardened Runtime enabled for all targets. |
| `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` | `NO` | Prevents Xcode from automatically injecting `get-task-allow`. |
| `SWIFT_STRICT_CONCURRENCY` | `complete` | Swift 6 strict concurrency checks. |
| `SWIFT_TREAT_WARNINGS_AS_ERRORS` | `YES` | Zero compiler warnings permitted in Release build. |

---

## 4. Conclusion

The entitlement posture for Torrentino Native macOS is **strictly minimal** and fully compliant with Apple Developer ID Notarization requirements.
