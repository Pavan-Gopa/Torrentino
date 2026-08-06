// Layer: EngineAgent (Transfer).
// Role: the pure add-flow domain operations behind inspectAddSource/commitAdd:
// magnet + .torrent inspection, duplicate-aware identity building, file
// selection validation, and engine DTO construction. No I/O, no persistence,
// no state — the TransferCoordinator owns all side effects and state.
// Must-not: fetch over the network, touch PersistenceStore, or mutate engine
// state; HTTP source fetching lives in HTTPSourceFetcher and is orchestrated
// by the coordinator.
// Invariants: every entry point is a pure function; every rejected input
// throws a typed error; a magnet that ignores v2-only hashes still yields a
// v1 identity (BEP-9).

import Foundation
import TorrentinoDomain
import TorrentinoIPC

public enum TorrentAdderError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSelectionPath(String)
    case fileNotInTorrent(String)

    public var description: String {
        switch self {
        case .invalidSelectionPath(let p): return "invalid selection path '\(p)'"
        case .fileNotInTorrent(let p): return "file '\(p)' is not part of the torrent"
        }
    }
}

public enum TorrentAdder {
    /// Everything learned about an add source before commitAdd. The
    /// coordinator keeps this per operationID so commitAdd needs no refetch.
    public struct Inspection: Sendable, Equatable {
        public let operationID: AddOperationID
        public let contentIdentity: ContentIdentity
        public let displayName: String
        public let sizeBytes: Int64?
        public let warnings: [String]
        /// nil for magnet sources (metadata not yet known).
        public let metainfo: Metainfo?
        public let magnet: MagnetLink?
        /// The exact source bytes for metainfo sources (the engine and the
        /// store need the full .torrent file, not just the info dict).
        public let sourceData: Data?

        public init(
            operationID: AddOperationID,
            contentIdentity: ContentIdentity,
            displayName: String,
            sizeBytes: Int64?,
            warnings: [String],
            metainfo: Metainfo?,
            magnet: MagnetLink?,
            sourceData: Data? = nil
        ) {
            self.operationID = operationID
            self.contentIdentity = contentIdentity
            self.displayName = displayName
            self.sizeBytes = sizeBytes
            self.warnings = warnings
            self.metainfo = metainfo
            self.magnet = magnet
            self.sourceData = sourceData
        }
    }

    /// Inspects a magnet URI (no I/O). v2-only hashes (urn:btmh) are not a
    /// v1 add source: without a btih the magnet is rejected by the parser.
    public static func inspectMagnet(uri: String, desiredName: String?) throws -> Inspection {
        let magnet = try MagnetParser.parse(uri)
        let identity = ContentIdentity(infoHashV1: magnet.infoHashV1, infoHashV2: nil)
        let fallbackName = "magnet:\(magnet.infoHashHex.prefix(8))"
        var warnings: [String] = []
        if magnet.trackers.isEmpty {
            warnings.append("no_trackers")
        }
        return Inspection(
            operationID: AddOperationID(),
            contentIdentity: identity,
            displayName: desiredName ?? magnet.displayName ?? fallbackName,
            sizeBytes: nil,
            warnings: warnings,
            metainfo: nil,
            magnet: magnet
        )
    }

    /// Inspects raw .torrent bytes: size gate → parse → policy gate.
    public static func inspectTorrentData(_ data: Data, desiredName: String?) throws -> Inspection {
        let metainfo = try Preflight.validateTorrentData(data)
        let identity = ContentIdentity(
            infoHashV1: metainfo.infoHashV1,
            infoHashV2: metainfo.infoHashV2
        )
        return Inspection(
            operationID: AddOperationID(),
            contentIdentity: identity,
            displayName: desiredName ?? metainfo.name,
            sizeBytes: metainfo.totalSize,
            warnings: Preflight.warnings(for: metainfo),
            metainfo: metainfo,
            magnet: nil,
            sourceData: data
        )
    }

    /// Validates and normalizes a UI file selection against the metainfo.
    /// Unknown files and paths that fail PathValidator are rejected; duplicate
    /// rows collapse to the first occurrence.
    public static func validateSelection(
        _ selection: [FileSelectionItem],
        against metainfo: Metainfo
    ) throws -> [RecordFileSelection] {
        var seen: Set<String> = []
        var result: [RecordFileSelection] = []
        for item in selection {
            let normalized: String
            do {
                normalized = try PathValidator.validatedRelativePath(item.relativePath)
            } catch {
                throw TorrentAdderError.invalidSelectionPath(item.relativePath)
            }
            guard metainfo.file(atPath: normalized) != nil else {
                throw TorrentAdderError.fileNotInTorrent(normalized)
            }
            guard seen.insert(normalized).inserted else { continue }
            result.append(RecordFileSelection(relativePath: normalized, priority: item.priority))
        }
        return result
    }

    /// Builds the engine add specification for a record. magnet sources use a
    /// regenerated URI (restart-safe re-add); file sources replay the exact
    /// metainfo bytes.
    public static func makeSpecification(
        identity: ContentIdentity,
        metainfoData: Data?,
        trackerTiers: [[String]],
        savePath: String,
        paused: Bool,
        privateTorrent: Bool = false
    ) -> AddSpecificationDTO {
        let enableDHT = privateTorrent ? false : nil
        let enablePEX = privateTorrent ? false : nil
        let enableLSD = privateTorrent ? false : nil
        if let metainfoData {
            return AddSpecificationDTO(
                torrentFile: metainfoData,
                magnetURI: nil,
                savePath: savePath,
                paused: paused,
                enableDHT: enableDHT,
                enablePEX: enablePEX,
                enableLSD: enableLSD
            )
        }
        if let infoHashV1 = identity.infoHashV1 {
            return AddSpecificationDTO(
                torrentFile: nil,
                magnetURI: buildMagnetURI(infoHashV1: infoHashV1, trackers: trackerTiers.flatMap { $0 }),
                savePath: savePath,
                paused: paused,
                enableDHT: enableDHT,
                enablePEX: enablePEX,
                enableLSD: enableLSD
            )
        }
        return AddSpecificationDTO(
            torrentFile: nil,
            magnetURI: nil,
            savePath: savePath,
            paused: paused,
            enableDHT: enableDHT,
            enablePEX: enablePEX,
            enableLSD: enableLSD
        )
    }

    /// Magnet-only compatibility entry point. Creator/metainfo re-adds use
    /// the structured overload above; this legacy scalar path has no tiered
    /// metainfo to reconstruct and is not used for normal restore/admission.
    public static func makeMagnetCompatibilitySpecification(
        identity: ContentIdentity,
        trackers: [String],
        savePath: String,
        paused: Bool,
        privateTorrent: Bool = false
    ) -> AddSpecificationDTO {
        makeSpecification(
            identity: identity,
            metainfoData: nil,
            trackerTiers: trackers.isEmpty ? [] : [trackers],
            savePath: savePath,
            paused: paused,
            privateTorrent: privateTorrent
        )
    }

    /// Regenerates a magnet URI from a v1 info hash + trackers (BEP-9).
    public static func buildMagnetURI(infoHashV1: Data, trackers: [String]) -> String {
        var uri = "magnet:?xt=urn:btih:\(hexString(infoHashV1))"
        for tracker in trackers.prefix(TransferLimits.maxTrackers) {
            uri += "&tr=\(percentEncode(tracker))"
        }
        return uri
    }

    // MARK: - Hex helpers

    public static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func dataFromHex(_ hex: String) -> Data? {
        let normalized = hex.lowercased()
        guard normalized.count % 2 == 0, normalized.allSatisfy({ $0.isHexDigit }) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let value = UInt8(normalized[index..<next], radix: 16) else { return nil }
            bytes.append(value)
            index = next
        }
        return Data(bytes)
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
