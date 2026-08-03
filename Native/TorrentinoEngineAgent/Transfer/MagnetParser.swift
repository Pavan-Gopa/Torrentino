// Layer: EngineAgent (Transfer).
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
    /// Optional display name (dn=), percent-decoded.
    public let displayName: String?
    public let trackers: [String]

    public init(infoHashV1: Data, displayName: String?, trackers: [String]) {
        self.infoHashV1 = infoHashV1
        self.displayName = displayName
        self.trackers = trackers
    }

    public var infoHashHex: String {
        infoHashV1.map { String(format: "%02x", $0) }.joined()
    }
}

public enum MagnetParser {
    public static func parse(_ uri: String) throws -> MagnetLink {
        guard uri.count <= TransferLimits.maxMagnetLength else { throw MagnetError.tooLong }
        guard uri.lowercased().hasPrefix("magnet:?") else { throw MagnetError.notAMagnet }

        let query = String(uri.dropFirst("magnet:?".count))
        let rawParameters = query.split(separator: "&", omittingEmptySubsequences: true)

        var infoHash: Data?
        var displayName: String?
        var trackers: [String] = []

        for rawParameter in rawParameters {
            let parameter = String(rawParameter)
            guard let equals = parameter.firstIndex(of: "=") else {
                throw MagnetError.invalidParameter(parameter)
            }
            let key = String(parameter[..<equals])
            let value = String(parameter[parameter.index(after: equals)...])
            let decodedValue = percentDecode(value)

            switch key.lowercased() {
            case "xt":
                let scheme = decodedValue.lowercased()
                if scheme.hasPrefix("urn:btih:") {
                    guard infoHash == nil else { throw MagnetError.invalidParameter("duplicate xt") }
                    let encoded = String(decodedValue.dropFirst("urn:btih:".count))
                    guard let hash = decodeInfoHash(encoded) else {
                        throw MagnetError.invalidHash(encoded)
                    }
                    infoHash = hash
                }
                // urn:btmh: (v2) is out of scope for the v1 slice: ignore
                // rather than fail — the torrent still works via btih when
                // both are present, and hybrid magnets carry btih first.
            case "dn":
                if displayName == nil, !decodedValue.isEmpty {
                    displayName = String(decodedValue.prefix(1024))
                }
            case "tr":
                guard let url = URL(string: decodedValue),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" || scheme == "udp" || scheme == "ws" || scheme == "wss",
                      decodedValue.count <= 2048 else {
                    throw MagnetError.invalidTrackerURL(decodedValue)
                }
                if !trackers.contains(decodedValue) { trackers.append(decodedValue) }
                if trackers.count >= TransferLimits.maxTrackers { break }
            default:
                break // unknown parameters (xl, as, ws, ...) are ignored
            }
        }

        guard let infoHash else { throw MagnetError.missingHash }
        return MagnetLink(infoHashV1: infoHash, displayName: displayName, trackers: trackers)
    }

    /// Decodes a 40-char lowercase hex or 32-char base32 (RFC 4648, no padding)
    /// representation of a 20-byte SHA-1 into raw bytes.
    static func decodeInfoHash(_ encoded: String) -> Data? {
        let normalized = encoded.lowercased()
        if normalized.count == 40, normalized.allSatisfy({ $0.isHexDigit }) {
            var bytes = [UInt8]()
            bytes.reserveCapacity(20)
            var index = normalized.startIndex
            while index < normalized.endIndex {
                let next = normalized.index(index, offsetBy: 2)
                guard let value = UInt8(normalized[index..<next], radix: 16) else { return nil }
                bytes.append(value)
                index = next
            }
            return Data(bytes)
        }
        if normalized.count == 32 {
            let alphabet = "abcdefghijklmnopqrstuvwxyz234567"
            var bits = 0
            var value: UInt32 = 0
            var bytes = [UInt8]()
            for character in normalized {
                guard let index = alphabet.firstIndex(of: character) else { return nil }
                value = (value << 5) | UInt32(alphabet.distance(from: alphabet.startIndex, to: index))
                bits += 5
                if bits >= 8 {
                    bits -= 8
                    bytes.append(UInt8((value >> bits) & 0xFF))
                }
            }
            guard bytes.count == 20 else { return nil }
            return Data(bytes)
        }
        return nil
    }

    /// RFC 3986 percent-decoding; '+' is literal (magnet uses %20 for spaces).
    private static func percentDecode(_ value: String) -> String {
        guard value.contains("%") else { return value }
        var result = Data()
        result.reserveCapacity(value.count)
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "%", value.index(index, offsetBy: 2, limitedBy: value.endIndex) != nil {
                let hexStart = value.index(after: index)
                let hexEnd = value.index(hexStart, offsetBy: 2)
                let hex = String(value[hexStart..<hexEnd])
                if let byte = UInt8(hex, radix: 16) {
                    result.append(byte)
                    index = hexEnd
                    continue
                }
            }
            if let byte = value[index].asciiValue {
                result.append(byte)
            } else {
                result.append(contentsOf: String(value[index]).utf8)
            }
            index = value.index(after: index)
        }
        return String(data: result, encoding: .utf8) ?? value
    }
}
