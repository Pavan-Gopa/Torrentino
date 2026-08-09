// Layer: shared pure helpers for WP13-LIVE-DND-UI-001 (drop/UTI gate and
// adaptive files-pane sizing). Dependency-free like FixtureLibrary.swift so
// the app target and TorrentinoAppTests compile the same source and tests can
// exercise the identical logic the view uses.
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

/// Adaptive lower files-pane geometry: size to content for small file lists,
/// cap and scroll for large ones.
enum FilesPaneSizing {
    /// Row height allowance per visible file entry plus the header bar.
    static let baseHeight: CGFloat = 40
    static let rowHeight: CGFloat = 28
    /// Cap for large file lists; beyond this the pane scrolls.
    static let maxHeight: CGFloat = 320

    static func idealHeight(fileCount: Int) -> CGFloat {
        let clamped = max(1, fileCount)
        let content = baseHeight + rowHeight * CGFloat(clamped)
        return min(content, maxHeight)
    }
}
