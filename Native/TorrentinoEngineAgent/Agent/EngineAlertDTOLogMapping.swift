// Layer: Engine Agent (Diagnostics & Observability).
// Role: CANONICAL EngineAlertDTO alert→log mapping, compiled into BOTH the
//       agent PRODUCT target and the TorrentinoEngineAgentTests bundle
//       (StatusCache.swift target-shared precedent): the bridge drain path in
//       BridgeTransferEngine.swift calls these members, and the WP-13 suites
//       assert the exact production strings against this same source file.
// Must-not: emit unredacted alert payloads — every message still passes
//           through TorrentinoLog.record's redactor downstream.
// Invariants: pure functions over EngineAlertDTO; no I/O; a single source of
//             truth for the mapping (no mirror copy to drift).

import Foundation

extension EngineAlertDTO {
    /// Idle drain ticks must stay silent: only a non-empty batch logs.
    static func alertDrainLogMessage(count: Int) -> String? {
        count > 0 ? "bridge alerts drained count=\(count)" : nil
    }

    /// Maps a live bridge alert into its redacted log record shape. The empty
    /// error field falls back to message, then to a readable placeholder.
    static func alertLogMessage(for alert: EngineAlertDTO) -> (severity: String, message: String) {
        let type: String
        switch alert.kind {
        case "error": type = "torrent_error_alert"
        case "unknown": type = "tracker_announce"
        case "session": type = "storage"
        default: type = alert.kind
        }
        let severity = alert.kind == "session" ? "warning" : "error"
        let message = (alert.error?.isEmpty == false ? alert.error : nil) ?? alert.message ?? "alert"
        return (
            severity: severity,
            message: "libtorrent alert type=\(type) severity=\(severity) message=\(message)"
        )
    }
}
