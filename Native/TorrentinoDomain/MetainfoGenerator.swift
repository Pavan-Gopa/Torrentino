// Layer: Domain
// Role: Metainfo dictionary generator for v1, v2, and hybrid BitTorrent files.
// Must-not: generate unvalidated bencode or missing info dictionary keys.
// Invariants: lexicographically sorted bencode dictionaries; Sendable.

import Foundation
import TorrentinoIPC

public enum MetainfoGenerator {
    public static func buildTorrentFile(
        scanResult: SourceScanResult,
        options: CreateOptions,
        hashingResult: HashingResult,
        creationDate: Date = Date()
    ) throws -> Data {
        let isV1 = options.format == .v1 || options.format == .hybrid
        let isV2 = options.format == .v2 || options.format == .hybrid

        var infoDict: [String: BencodeEncoder.Value] = [:]
        infoDict["name"] = .string(scanResult.rootName)
        infoDict["piece length"] = .integer(scanResult.pieceSizeBytes)

        if options.isPrivate {
            infoDict["private"] = .integer(1)
        }

        if let source = options.source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            infoDict["source"] = .string(source.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if isV1 {
            infoDict["pieces"] = .bytes(hashingResult.v1PiecesData)
        }

        // Handle single file vs multi-file for v1
        if isV1 {
            if !scanResult.isDirectory && scanResult.files.count == 1 {
                infoDict["length"] = .integer(scanResult.files[0].sizeBytes)
            } else {
                var filesList: [BencodeEncoder.Value] = []
                for file in scanResult.files {
                    var fileDict: [String: BencodeEncoder.Value] = [:]
                    fileDict["length"] = .integer(file.sizeBytes)
                    let pathParts = file.relativePath.split(separator: "/").map { String($0) }
                    fileDict["path"] = .list(pathParts.map { .string($0) })
                    filesList.append(.dictionary(fileDict))
                }
                infoDict["files"] = .list(filesList)
            }
        }

        // Handle v2 file tree
        var pieceLayersDict: [String: BencodeEncoder.Value] = [:]

        if isV2 {
            var fileTreeRoot: [String: BencodeEncoder.Value] = [:]

            for file in scanResult.files {
                guard let v2Entry = hashingResult.v2FileTrees[file.relativePath] else {
                    continue
                }

                // If piece layers are present, add to piece layers dictionary
                if !v2Entry.pieceLayers.isEmpty {
                    let rootKey = String(decoding: v2Entry.piecesRoot, as: UTF8.self)
                    pieceLayersDict[rootKey] = .bytes(v2Entry.pieceLayers)
                }

                let pathParts: [String]
                if !scanResult.isDirectory && scanResult.files.count == 1 {
                    pathParts = [scanResult.rootName]
                } else {
                    pathParts = file.relativePath.split(separator: "/").map { String($0) }
                }

                insertIntoFileTree(
                    tree: &fileTreeRoot,
                    components: pathParts,
                    fileSize: file.sizeBytes,
                    piecesRoot: v2Entry.piecesRoot
                )
            }

            infoDict["file tree"] = .dictionary(fileTreeRoot)
            if options.format == .v2 {
                infoDict["meta version"] = .integer(2)
            }
        }

        var topDict: [String: BencodeEncoder.Value] = [:]
        topDict["info"] = .dictionary(infoDict)

        // Trackers tier handling
        let trackers = options.trackers.flatMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !trackers.isEmpty {
            topDict["announce"] = .string(trackers[0])
            var announceList: [BencodeEncoder.Value] = []
            for tier in options.trackers {
                let validUrls = tier.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !validUrls.isEmpty {
                    announceList.append(.list(validUrls.map { .string($0) }))
                }
            }
            if !announceList.isEmpty {
                topDict["announce-list"] = .list(announceList)
            }
        }

        if let comment = options.comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            topDict["comment"] = .string(comment.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        topDict["created by"] = .string("Torrentino Native 1.0")
        topDict["creation date"] = .integer(Int64(creationDate.timeIntervalSince1970))
        topDict["encoding"] = .string("UTF-8")

        if isV2 && !pieceLayersDict.isEmpty {
            topDict["piece layers"] = .dictionary(pieceLayersDict)
        }

        return BencodeEncoder.encode(.dictionary(topDict))
    }

    private static func insertIntoFileTree(
        tree: inout [String: BencodeEncoder.Value],
        components: [String],
        fileSize: Int64,
        piecesRoot: Data
    ) {
        guard !components.isEmpty else { return }

        let head = components[0]
        if components.count == 1 {
            var leafDict: [String: BencodeEncoder.Value] = [:]
            leafDict["length"] = .integer(fileSize)
            if fileSize > 0 {
                leafDict["pieces root"] = .bytes(piecesRoot)
            }

            var itemDict: [String: BencodeEncoder.Value] = [:]
            itemDict[""] = .dictionary(leafDict)
            tree[head] = .dictionary(itemDict)
        } else {
            var childTree: [String: BencodeEncoder.Value] = [:]
            if case .dictionary(let existing)? = tree[head] {
                childTree = existing
            }
            insertIntoFileTree(
                tree: &childTree,
                components: Array(components.dropFirst()),
                fileSize: fileSize,
                piecesRoot: piecesRoot
            )
            tree[head] = .dictionary(childTree)
        }
    }
}
