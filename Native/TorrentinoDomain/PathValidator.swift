// Layer: Domain (pure value types).
// Role: path validation/normalization for untrusted torrent metainfo. Every
// relative path that will be materialized under the torrent root passes
// through this gate FIRST — nothing may reach payload write with an
// unvalidated path (WP-07 gate: untrusted source cannot create a path outside
// the validated torrent root).
// Must-not: touch the filesystem, resolve symlinks, or perform I/O. Symlink
// escape *detection* at materialization time is a runtime concern (WP-10);
// at the path level we reject every spelling that could encode an escape
// (absolute, .., backslash separators, null bytes).
// Invariants: pure functions, Sendable; the accepted spelling is NFC with
// components free of "." / ".." / leading "/" / trailing dots-spaces; all
// paths are relative to the torrent root.

import Foundation

public enum PathValidator {
    /// Why a path failed validation. Frozen vocabulary (WP-07 negative corpus).
    public enum ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
        case absolutePath
        case traversalComponent(String)
        case dotComponent
        case emptyComponent
        case emptyPath
        case nullByte
        case backslashSeparator
        case reservedName(String)
        case componentTooLong(String)
        case pathTooLong
        case invalidUTF8

        public var description: String {
            switch self {
            case .absolutePath: return "absolute path"
            case .traversalComponent(let c): return "traversal component '\(c)'"
            case .dotComponent: return "'.' component"
            case .emptyComponent: return "empty component"
            case .emptyPath: return "empty path"
            case .nullByte: return "null byte"
            case .backslashSeparator: return "backslash separator"
            case .reservedName(let n): return "reserved name '\(n)'"
            case .componentTooLong(let c): return "component too long '\(c)'"
            case .pathTooLong: return "path too long"
            case .invalidUTF8: return "invalid UTF-8"
            }
        }
    }

    /// Hard caps (plan §7.4 bounded reads / WP-07 preflight).
    public static let maxComponents = 512
    public static let maxComponentLength = 255
    public static let maxPathLength = 4096

    /// Windows reserved device names (case-insensitive, extension ignored).
    private static let reservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    /// Validates a raw metainfo path and returns the normalized relative
    /// spelling, or throws the first validation error.
    ///
    /// Accepted input: any string; the result is always NFC, "/"-separated,
    /// relative, with no "." / ".." components, no trailing dots/spaces, no
    /// backslashes, no null bytes, no reserved device names.
    public static func validatedRelativePath(_ raw: String) throws -> String {
        let error = validationError(raw)
        if let error { throw error }
        return normalizedPath(raw)
    }

    /// True when `raw` is a safe relative path (nil result = safe).
    public static func validationError(_ raw: String) -> ValidationError? {
        guard let utf8 = raw.data(using: .utf8) else { return .invalidUTF8 }
        guard !utf8.contains(0) else { return .nullByte }
        guard raw.contains("\\") == false else { return .backslashSeparator }

        let normalized = raw.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty else { return .emptyPath }
        guard normalized.hasPrefix("/") == false else { return .absolutePath }
        // Volume/colon prefixes (Windows "C:", macOS legacy) are absolute.
        if let first = normalized.first, first.isLetter, normalized.dropFirst().hasPrefix(":") {
            return .absolutePath
        }
        guard normalized.count <= maxPathLength else { return .pathTooLong }

        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= maxComponents else { return .pathTooLong }
        for component in components {
            let value = String(component)
            if value.isEmpty { return .emptyComponent }
            if value == ".." { return .traversalComponent(value) }
            if value == "." { return .dotComponent }
            if value.count > maxComponentLength { return .componentTooLong(value) }
            let stripped = value.trimmingTrailingDotsAndSpaces
            if stripped.isEmpty { return .emptyComponent }
            let base = stripped.split(separator: ".").first.map(String.init) ?? stripped
            if reservedNames.contains(base.uppercased()) { return .reservedName(base) }
        }
        return nil
    }

    /// Normalizes without validating: NFC, "/"-joins, strips trailing dots and
    /// spaces from every component (Windows compat). Only call on inputs that
    /// already passed `validationError` (the stripping is deterministic and
    /// idempotent).
    public static func normalizedPath(_ raw: String) -> String {
        let nfc = raw.precomposedStringWithCanonicalMapping
        let components = nfc.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingTrailingDotsAndSpaces }
            .filter { !$0.isEmpty }
        return components.joined(separator: "/")
    }

    /// True when a component name is reserved on Windows (drive-letter naming
    /// collisions; torrents are cross-platform).
    public static func isReservedName(_ name: String) -> Bool {
        let base = name.split(separator: ".").first.map(String.init) ?? name
        return reservedNames.contains(base.uppercased())
    }
}

private extension Substring {
    var trimmingTrailingDotsAndSpaces: String {
        var end = endIndex
        while end > startIndex {
            let before = index(before: end)
            let ch = self[before]
            if ch == "." || ch == " " {
                end = before
            } else {
                break
            }
        }
        return String(self[..<end])
    }
}

private extension String {
    var trimmingTrailingDotsAndSpaces: String {
        Substring(self).trimmingTrailingDotsAndSpaces
    }
}
