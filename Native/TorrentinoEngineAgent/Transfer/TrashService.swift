// Layer: EngineAgent (Transfer) — WP-10 safe file operations.
// Role: per-item Trash operation. Performs the TOCTOU-safe, chain-validated
// move of ONE manifest entry to the platform Trash through an injected
// provider (so tests can simulate trash failures and partial results).
// Must-not: touch the journal, decide policy (shared skip happens before this
// type is consulted for ordinary entries), or permanently delete anything.
// Invariants: every failure is a typed TrashItemFailure; the item is only
// offered to the provider after FileSafetyValidator re-verified the chain;
// success is reported only when the provider reports success.

import Foundation

/// Typed per-item trash failure (WP-10 partial-trash evidence).
struct TrashItemFailure: Sendable, Equatable {
    let code: String
    let message: String
}

enum TrashOutcome: Sendable, Equatable {
    case trashed(relativePath: String, sizeBytes: Int64)
    case failed(TrashItemFailure)
}

/// The platform trash primitive. Injected so tests can fail or record calls
/// without touching the real Trash.
protocol TrashProviding: Sendable {
    /// Moves the item at `absolutePath` to the platform Trash.
    func moveToTrash(at absolutePath: String) throws
}

/// FileManager-based provider: Finder-visible Trash, cross-volume capable,
/// no permanent delete. Errors surface as NSError (typed below).
struct FileManagerTrashProvider: TrashProviding {
    func moveToTrash(at absolutePath: String) throws {
        let url = URL(fileURLWithPath: absolutePath)
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }
}

/// Per-item trash executor. Owns no state; the coordinator sequences journal
/// rows around each call.
struct TrashService {
    let trash: any TrashProviding

    init(trash: any TrashProviding = FileManagerTrashProvider()) {
        self.trash = trash
    }

    /// Trashes one manifest entry. Shared entries are never offered to the
    /// provider; verification failures and provider failures are typed.
    func trash(
        entry: RemovalManifestItem,
        manifest: RemovalManifest
    ) -> TrashOutcome {
        let absolute = manifest.absolutePath(for: entry)
        switch entry.kind {
        case .file:
            if let issue = FileSafetyValidator.verifyFileIdentity(
                absolutePath: absolute,
                expectedSize: entry.sizeBytes
            ) {
                return .failed(failure(from: issue, path: absolute))
            }
        case .directory:
            if let issue = FileSafetyValidator.verifyDirectoryIdentity(absolutePath: absolute) {
                return .failed(failure(from: issue, path: absolute))
            }
        }
        do {
            try trash.moveToTrash(at: absolute)
        } catch {
            let nsError = error as NSError
            return .failed(TrashItemFailure(
                code: "trash_failed",
                message: nsError.localizedDescription
            ))
        }
        return .trashed(relativePath: entry.relativePath, sizeBytes: entry.sizeBytes)
    }

    private func failure(from issue: FileSafetyValidator.Issue, path: String) -> TrashItemFailure {
        switch issue {
        case .symlink(let foundAt):
            return TrashItemFailure(
                code: "unsafe_symlink",
                message: "symlink refused at \(foundAt)"
            )
        case .missing:
            return TrashItemFailure(
                code: "missing",
                message: "item missing at \(path)"
            )
        case .wrongKind:
            return TrashItemFailure(
                code: "wrong_kind",
                message: "item kind mismatch at \(path)"
            )
        case .sizeMismatch(let expected, let actual):
            return TrashItemFailure(
                code: "size_mismatch",
                message: "size changed at \(path) (expected \(expected), actual \(actual))"
            )
        }
    }
}
