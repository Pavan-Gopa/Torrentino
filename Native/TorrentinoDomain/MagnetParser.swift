// Layer: Domain
// Role: strict magnet URI parsing (BEP-9/BEP-53 subset used by v1 torrents):
// xt=urn:btih:<hex|base32>, dn=<display name>, tr=<tracker>, ws=, as=, xl=.
// Must-not: follow the URI, resolve DNS, or accept malformed hashes; every
// rejected magnet leaves no state behind (reject before any payload write).
// Invariants: deterministic, no I/O; infoHashV1 is exactly 20 bytes;
// trackers are deduplicated and bounded (TransferLimits.maxTrackers).

import Foundation

public enum MagnetError: Error, Sendable, Equatable, CustomStringConvertible {
    case notAMagnet
    case tooLong
    case missingHash
    case invalidHash(String)
    case invalidParameter(String)
    case invalidTrackerURL(String)

    public var description: String {
        switch self {
        case .notAMagnet: return "not a magnet URI"
        case .tooLong: return "magnet URI too long"
        case .missingHash: return "missing xt=urn:btih: info hash"
        case .invalidHash(let h): return "invalid info hash '\(h)'"
        case .invalidParameter(let p): return "invalid parameter '\(p)'"
        case .invalidTrackerURL(let u): return "invalid tracker URL '\(u)'"
        }
    }
}

/// Parsed magnet link.
public struct MagnetLink: Sendable, Equatable {
    /// 20-byte v1 info hash.
    public let infoHashV1: Data
    public let displayName: String?
    public let trackers: [String]
    public let webSeeds: [String]
    public let totalSizeBytes: Int64?

    public init(
        infoHashV1: Data,
        displayName: String?,
        trackers: [String],
        webSeeds: [String],
        totalSizeBytes: Int64?
    ) {
        self.infoHashV1 = infoHashV1
        self.displayName = displayName
        self.trackers = trackers
        self.webSeeds = webSeeds
        self.totalSizeBytes = totalSizeBytes
    }

    public var infoHashHex: String {
        infoHashV1.map { String(format: "%02x", $0) }.joined()
    }
}

public enum MagnetParser {
    /// Parses a magnet: URI string. Throws MagnetError on any malformed
    /// scheme, hash, length or parameter.
    public static func parse(_ uriString: String) throws -> MagnetLink {
        guard uriString.count <= TransferLimits.maxMagnetLength else { throw MagnetError.tooLong }
        guard let urlComponents = URLComponents(string: uriString),
              urlComponents.scheme?.lowercased() == "magnet" else {
            throw MagnetError.notAMagnet
        }

        var infoHashV1: Data?
        var displayName: String?
        var trackers: [String] = []
        var webSeeds: [String] = []
        var totalSizeBytes: Int64?

        for item in urlComponents.queryItems ?? [] {
            let key = item.name.lowercased()
            let val = item.value ?? ""
            switch key {
            case "xt":
                guard val.lowercased().hasPrefix("urn:btih:") else { continue }
                let hashStr = String(val.dropFirst(9))
                let decoded = try parseInfoHash(hashStr)
                infoHashV1 = decoded
            case "dn":
                displayName = val
            case "tr":
                guard !val.isEmpty, val.count <= 2048 else { throw MagnetError.invalidTrackerURL(val) }
                if !trackers.contains(val) { trackers.append(val) }
            case "ws", "as":
                guard !val.isEmpty else { continue }
                if !webSeeds.contains(val) { webSeeds.append(val) }
            case "xl":
                guard let bytes = Int64(val), bytes >= 0 else { throw MagnetError.invalidParameter("xl=\(val)") }
                totalSizeBytes = bytes
            default:
                break
            }
        }

        guard let hash = infoHashV1 else { throw MagnetError.missingHash }

        return MagnetLink(
            infoHashV1: hash,
            displayName: displayName,
            trackers: Array(trackers.prefix(TransferLimits.maxTrackers)),
            webSeeds: webSeeds,
            totalSizeBytes: totalSizeBytes
        )
    }

    private static func parseInfoHash(_ raw: String) throws -> Data {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count == 40 {
            // Hex encoded (20 bytes)
            guard let data = Data(hexString: cleaned), data.count == 20 else {
                throw MagnetError.invalidHash(raw)
            }
            return data
        } else if cleaned.count == 32 {
            // Base32 encoded (20 bytes)
            guard let data = Data(base32String: cleaned), data.count == 20 else {
                throw MagnetError.invalidHash(raw)
            }
            return data
        } else {
            throw MagnetError.invalidHash(raw)
        }
    }
}

// MARK: - Hex & Base32 Decoding Helpers

private extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var i = hexString.startIndex
        for _ in 0..<len {
            let next = hexString.index(i, offsetBy: 2)
            guard let b = UInt8(hexString[i..<next], radix: 16) else { return nil }
            data.append(b)
            i = next
        }
        self = data
    }

    init?(base32String: String) {
        // Base32 decoding per RFC 4648
        let alphabet = "abcdefghijklmnopqrstuvwxyz234567"
        var buffer: UInt64 = 0
        var bitsLeft = 0
        var result = Data()

        for char in base32String.lowercased() {
            guard let idx = alphabet.firstIndex(of: char) else { return nil }
            let val = alphabet.distance(from: alphabet.startIndex, to: idx)
            buffer = (buffer << 5) | UInt64(val)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                let byte = UInt8((buffer >> bitsLeft) & 0xFF)
                result.append(byte)
            }
        }
        self = result
    }
}
