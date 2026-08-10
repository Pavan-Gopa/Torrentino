// Layer: shared pure helper for the WP13-LIVE-DND-UI-001 drop/UTI gate.
// Invariants: no engine/IPC state here; pure functions only.

import Foundation
import UniformTypeIdentifiers

/// `.torrent` gate shared by the window drop handler and Finder
/// open-document: file URL, extension/UTI match against the app-declared
/// `com.bittorrent.torrent` type (Info.plist exports it with the `torrent`
/// filename extension).
enum TorrentDropRouting {
    static func isTorrentDropURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if url.pathExtension.lowercased() == "torrent" { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.identifier == "com.bittorrent.torrent"
    }
}
