// Layer: Hashing research (WP-12) — benchmark executable target
// Role: reproducible measurement + verification harness for the experimental
// backends. Produces the raw numbers cited by the WP-12 report and ADR.
// Commands:
//   bench          timed runs over a corpus (cpu|metal|all backends)
//   verify         CPU vs GPU bit-for-bit equality on a corpus
//   torrent        write a deterministic .torrent from hashing output
//   support-check  §12.8 supported-hook query
// Invariants: deterministic output ordering; no production Application
// Support paths; corpora are read-only.

import CommonCrypto
import Foundation
import TorrentinoHashing

// MARK: - Corpus scanning (mirror of production SourceScanner semantics)

struct CorpusFile: Sendable {
    let relativePath: String
    let fullPath: String
    let deviceID: UInt64
    let fileResourceID: UInt64
    let sizeBytes: Int64
    let mtimeSeconds: Int64
    let mtimeNanos: Int64
}

enum CorpusScanner {
    static func scan(root: String) throws -> (rootName: String, files: [HashSourceFile]) {
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        let rootName = rootURL.lastPathComponent
        var entries: [CorpusFile] = []

        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        guard let enumerator else {
            throw NSError(domain: "CorpusScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot enumerate \(root)"])
        }
        for case let fileURL as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            var st = stat()
            guard lstat(fileURL.path, &st) == 0 else { continue }
            let relative = String(fileURL.standardizedFileURL.path.dropFirst(rootURL.standardizedFileURL.path.count + 1))
            entries.append(CorpusFile(
                relativePath: relative,
                fullPath: fileURL.path,
                deviceID: UInt64(st.st_dev),
                fileResourceID: UInt64(st.st_ino),
                sizeBytes: Int64(st.st_size),
                mtimeSeconds: Int64(st.st_mtimespec.tv_sec),
                mtimeNanos: Int64(st.st_mtimespec.tv_nsec)
            ))
        }
        guard !entries.isEmpty else {
            throw NSError(domain: "CorpusScanner", code: 2, userInfo: [NSLocalizedDescriptionKey: "no files in \(root)"])
        }
        entries.sort { $0.relativePath < $1.relativePath }
        let files = entries.map {
            HashSourceFile(
                relativePath: $0.relativePath, fullPath: $0.fullPath,
                deviceID: $0.deviceID, fileResourceID: $0.fileResourceID,
                sizeBytes: $0.sizeBytes, mtimeSeconds: $0.mtimeSeconds, mtimeNanos: $0.mtimeNanos
            )
        }
        return (rootName, files)
    }
}

// MARK: - Minimal deterministic bencode writer + metainfo builder

enum Bencode {
    indirect enum Value {
        case integer(Int64)
        case bytes(Data)
        case string(String)
        case list([Value])
        case dictionary([Data: Value])
    }

    static func encode(_ value: Value) -> Data {
        switch value {
        case .integer(let n):
            return Data("i\(n)e".utf8)
        case .bytes(let data):
            var out = Data("\(data.count):".utf8)
            out.append(data)
            return out
        case .string(let s):
            return encode(.bytes(Data(s.utf8)))
        case .list(let items):
            var out = Data("l".utf8)
            for item in items { out.append(encode(item)) }
            out.append(Data("e".utf8))
            return out
        case .dictionary(let pairs):
            var out = Data("d".utf8)
            for key in pairs.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                out.append(encode(.bytes(key)))
                out.append(encode(pairs[key]!))
            }
            out.append(Data("e".utf8))
            return out
        }
    }
}

enum BenchMetainfo {
    /// Deterministic .torrent bytes (no timestamps/trackers) mirroring the
    /// production MetainfoGenerator layout for v1/v2/hybrid.
    static func build(
        rootName: String,
        isDirectory: Bool,
        files: [HashSourceFile],
        pieceSizeBytes: Int64,
        format: ResearchFormat,
        output: HashingOutput
    ) throws -> Data {
        var infoPairs: [(String, Bencode.Value)] = []
        infoPairs.append(("name", .string(rootName)))
        infoPairs.append(("piece length", .integer(pieceSizeBytes)))

        if format.isV1Needed {
            infoPairs.append(("pieces", .bytes(output.v1PiecesData)))
            if !isDirectory && files.count == 1 {
                infoPairs.append(("length", .integer(files[0].sizeBytes)))
            } else {
                let reference = CPUReferenceHasher()
                let padding = reference.v1PaddingBytes(files: files, pieceSizeBytes: pieceSizeBytes, format: format)
                var filesList: [Bencode.Value] = []
                for (index, file) in files.enumerated() {
                    let pathParts = file.relativePath.split(separator: "/").map { String($0) }
                    filesList.append(.dictionary([
                        Data("length".utf8): .integer(file.sizeBytes),
                        Data("path".utf8): .list(pathParts.map { .string($0) }),
                    ]))
                    if index < padding.count, padding[index] > 0 {
                        var parts = file.relativePath.split(separator: "/").dropLast().map { String($0) }
                        let digest = Self.sha1Hex(file.relativePath)
                        parts.append("_____padding_file_\(index)_\(digest)")
                        filesList.append(.dictionary([
                            Data("length".utf8): .integer(padding[index]),
                            Data("path".utf8): .list(parts.map { .string($0) }),
                            Data("attr".utf8): .string("p"),
                        ]))
                    }
                }
                infoPairs.append(("files", .list(filesList)))
            }
        }

        var pieceLayersDict: [Data: Bencode.Value] = [:]
        if format.isV2Needed {
            var fileTreeRoot: [Data: Bencode.Value] = [:]
            for file in files {
                // Empty files have no v2 tree (BEP-52: no leaf, no root).
                guard let v2Entry = output.v2FileTrees[file.relativePath] else {
                    if file.sizeBytes == 0 { continue }
                    throw NSError(domain: "BenchMetainfo", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing v2 tree for \(file.relativePath)"])
                }
                if !v2Entry.pieceLayers.isEmpty {
                    pieceLayersDict[v2Entry.piecesRoot] = .bytes(v2Entry.pieceLayers)
                }
                let pathParts: [String]
                if !isDirectory && files.count == 1 {
                    pathParts = [rootName]
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
            infoPairs.append(("file tree", .dictionary(fileTreeRoot)))
            infoPairs.append(("meta version", .integer(2)))
        }

        var topPairs: [(String, Bencode.Value)] = []
        topPairs.append(("info", .dictionary(pairs(infoPairs))))
        topPairs.append(("created by", .string("Torrentino WP-12 bench")))
        if format.isV2Needed {
            topPairs.append(("piece layers", .dictionary(pieceLayersDict)))
        }
        return Bencode.encode(.dictionary(pairs(topPairs)))
    }

    private static func pairs(_ list: [(String, Bencode.Value)]) -> [Data: Bencode.Value] {
        var dict: [Data: Bencode.Value] = [:]
        for (key, value) in list { dict[Data(key.utf8)] = value }
        return dict
    }

    private static func sha1Hex(_ string: String) -> String {
        var digest = [UInt8](repeating: 0, count: 20)
        Data(string.utf8).withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                CC_SHA1(base, CC_LONG(string.utf8.count), &digest)
            }
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func insertIntoFileTree(
        tree: inout [Data: Bencode.Value],
        components: [String],
        fileSize: Int64,
        piecesRoot: Data?
    ) {
        guard !components.isEmpty else { return }
        let head = Data(components[0].utf8)
        if components.count == 1 {
            var leafPairs: [(String, Bencode.Value)] = [("length", .integer(fileSize))]
            if let piecesRoot, fileSize > 0 {
                leafPairs.append(("pieces root", .bytes(piecesRoot)))
            }
            var leaf: [Data: Bencode.Value] = [:]
            leaf[Data()] = .dictionary(pairs(leafPairs))
            tree[head] = .dictionary(leaf)
        } else {
            var childTree: [Data: Bencode.Value] = [:]
            if case .dictionary(let existing)? = tree[head] {
                childTree = existing
            }
            insertIntoFileTree(tree: &childTree, components: Array(components.dropFirst()), fileSize: fileSize, piecesRoot: piecesRoot)
            tree[head] = .dictionary(childTree)
        }
    }
}

// MARK: - Metrics

struct RunMetrics: Sendable {
    let wallSeconds: Double
    let cpuSecondsDelta: Double
    let peakRSSBytes: Int64
    let thermalBefore: String
    let thermalAfter: String
    let cpuSpeedLimit: Int
    let gpuWallSeconds: Double
    let fallbackCount: Int
    let stagedBytes: Int64
}

func measure<R>(_ body: () async throws -> (R, BackendRunReport)) async throws -> (R, RunMetrics) {
    let before = EnergySampler.sample()
    var rusageStart = rusage()
    getrusage(RUSAGE_SELF, &rusageStart)
    let wallStart = DispatchTime.now()
    let (result, report) = try await body()
    let wallSeconds = Double(DispatchTime.now().uptimeNanoseconds - wallStart.uptimeNanoseconds) / 1_000_000_000
    let after = EnergySampler.sample()
    var rusageEnd = rusage()
    getrusage(RUSAGE_SELF, &rusageEnd)
    let peakRSSBytes = rusageEnd.ru_maxrss
    let metrics = RunMetrics(
        wallSeconds: wallSeconds,
        cpuSecondsDelta: EnergySampler.cpuDelta(from: before, to: after),
        peakRSSBytes: Int64(peakRSSBytes),
        thermalBefore: "\(before.thermalStateRaw)",
        thermalAfter: "\(after.thermalStateRaw)",
        cpuSpeedLimit: after.cpuSpeedLimitPercent,
        gpuWallSeconds: report.gpuWallSeconds,
        fallbackCount: report.fallbackCount,
        stagedBytes: report.stagedBytes
    )
    return (result, metrics)
}

// MARK: - CLI

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self {
        case .usage(let message): return message
        }
    }
}

func parsePieceSize(_ raw: String) throws -> Int64 {
    guard let kib = Int64(raw), [256, 1024, 4096, 16384].contains(kib) else {
        throw CLIError.usage("piece size must be one of 256|1024|4096|16384 KiB")
    }
    return kib * 1024
}

func parseFormat(_ raw: String) throws -> ResearchFormat {
    switch raw {
    case "v1": return .v1
    case "v2": return .v2
    case "hybrid": return .hybrid
    default: throw CLIError.usage("format must be v1|v2|hybrid")
    }
}

@main
struct TorrentinoHashingBench {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            try await run(arguments: arguments)
        } catch let error as CLIError {
            print("usage error: \(error)")
            print("commands: bench | verify | torrent | support-check")
            exit(2)
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    static func run(arguments: [String]) async throws {
        guard let command = arguments.first else {
            throw CLIError.usage("missing command")
        }
        switch command {
        case "bench":
            try await bench(arguments: Array(arguments.dropFirst()))
        case "verify":
            try await verify(arguments: Array(arguments.dropFirst()))
        case "torrent":
            try await torrent(arguments: Array(arguments.dropFirst()))
        case "support-check":
            try await supportCheck(arguments: Array(arguments.dropFirst()))
        case "gpudbg":
            try await gpuDebug()
        default:
            throw CLIError.usage("unknown command \(command)")
        }
    }

    static func gpuDebug() async throws {
        let environment = MetalEnvironment()
        let runtime = try await environment.ensureRuntime()
        let zeroBlock = Data(repeating: 0, count: 16 * 1024)
        let aBlock = Data(repeating: 0x61, count: 16 * 1024)
        var mixedBlock = Data(repeating: 0, count: 16 * 1024)
        mixedBlock[0] = 0x01
        mixedBlock[63] = 0x02
        mixedBlock[64] = 0x03
        mixedBlock[127] = 0x04
        var altBlock = Data(repeating: 0, count: 16 * 1024)
        for i in stride(from: 1, to: 16 * 1024, by: 2) { altBlock[i] = 0xFF }
        for (name, input) in [("zeros", zeroBlock), ("a", aBlock), ("mixed", mixedBlock), ("alt", altBlock)] {
            let expected = CPUReferenceHasher.sha256(input)
            let digests = try await GPUBlockHasher.hash(
                data: input, runtime: runtime, stagingBytes: 4 * 1024 * 1024, injection: .none
            )
            let ok = digests.count == 1 && digests[0] == expected
            print("\(name): \(ok ? "OK" : "MISMATCH") expected=\(expected.map { String(format: "%02x", $0) }.joined()) gpu=\(digests[0].map { String(format: "%02x", $0) }.joined())")
        }
    }

    static func parseOptions(_ arguments: [String]) throws -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--") else {
                throw CLIError.usage("unexpected positional argument \(flag)")
            }
            guard index + 1 < arguments.count else {
                throw CLIError.usage("missing value for \(flag)")
            }
            options[String(flag.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        return options
    }

    static func bench(arguments: [String]) async throws {
        let options = try parseOptions(arguments)
        guard let dir = options["dir"] else { throw CLIError.usage("bench requires --dir") }
        let pieceSizeBytes = try parsePieceSize(options["piece"] ?? "1024")
        let format = try parseFormat(options["format"] ?? "hybrid")
        let backendRaw = options["backend"] ?? "all"
        let reps = Int(options["reps"] ?? "10") ?? 10
        let backends: [HashingBackendChoice]
        switch backendRaw {
        case "cpu": backends = [.cpu]
        case "metal": backends = [.metal]
        case "all": backends = [.cpu, .metal]
        default: throw CLIError.usage("backend must be cpu|metal|all")
        }

        let scan = try CorpusScanner.scan(root: dir)
        let totalBytes = scan.files.reduce(Int64(0)) { $0 + $1.sizeBytes }
        print("corpus: root=\(scan.rootName) files=\(scan.files.count) bytes=\(totalBytes) piece=\(pieceSizeBytes) format=\(format.rawValue)")

        // Randomized backend order per rep (§12.7: randomized CPU/Metal order).
        var runs: [(Int, HashingBackendChoice)] = []
        for rep in 0..<reps {
            let order = backends.shuffled()
            for backend in order {
                runs.append((rep, backend))
            }
        }

        print("run,cell,backend,wall_s,cpu_s,peak_rss_mb,thermal_before,thermal_after,cpu_speed_limit,gpu_wall_s,fallbacks,staged_bytes,throughput_mib_s")
        for (rep, backendChoice) in runs {
            let (_, metrics) = try await measure {
                let backend = ResearchHashingBackend()
                let result = try await backend.hash(
                    scannedFiles: scan.files,
                    pieceSizeBytes: pieceSizeBytes,
                    format: format,
                    choice: backendChoice
                )
                return (result.output, result.report)
            }
            let throughputMiB = totalBytes > 0 ? Double(totalBytes) / (1024 * 1024) / max(metrics.wallSeconds, 0.000001) : 0
            let cell = "\(scan.rootName)/\(pieceSizeBytes / 1024)KiB"
            print("\(rep),\(cell),\(backendChoice.rawValue),\(String(format: "%.4f", metrics.wallSeconds)),\(String(format: "%.4f", metrics.cpuSecondsDelta)),\(String(format: "%.1f", Double(metrics.peakRSSBytes) / 1024 / 1024)),\(metrics.thermalBefore),\(metrics.thermalAfter),\(metrics.cpuSpeedLimit),\(String(format: "%.4f", metrics.gpuWallSeconds)),\(metrics.fallbackCount),\(metrics.stagedBytes),\(String(format: "%.2f", throughputMiB))")
        }
    }

    static func verify(arguments: [String]) async throws {
        let options = try parseOptions(arguments)
        guard let dir = options["dir"] else { throw CLIError.usage("verify requires --dir") }
        let pieceSizeBytes = try parsePieceSize(options["piece"] ?? "1024")
        let format = try parseFormat(options["format"] ?? "hybrid")

        let scan = try CorpusScanner.scan(root: dir)
        guard ExperimentalGate.isMetalExperimentsEnabled else {
            print("verify: SKIP (experimental flag \(ExperimentalGate.flagName) not set)")
            exit(3)
        }

        let cpu = try await CPUReferenceHasher().hash(
            scannedFiles: scan.files, pieceSizeBytes: pieceSizeBytes, format: format
        )
        let backend = ResearchHashingBackend()
        let metal = try await backend.hash(
            scannedFiles: scan.files, pieceSizeBytes: pieceSizeBytes, format: format, choice: .metal
        )
        guard metal.report.actualEngine == .metal else {
            print("verify: FAIL (metal fell back to CPU: \(metal.report.rejectionReason ?? "unknown"))")
            exit(1)
        }
        guard metal.output == cpu else {
            print("verify: FAIL (bit-for-bit mismatch)")
            exit(1)
        }
        print("verify: PASS bits=\(metal.output.totalBytesHashed) pieces=\(metal.output.v1PiecesData.count / 20) v2trees=\(metal.output.v2FileTrees.count) fallbacks=\(metal.report.fallbackCount)")
    }

    static func torrent(arguments: [String]) async throws {
        let options = try parseOptions(arguments)
        guard let dir = options["dir"] else { throw CLIError.usage("torrent requires --dir") }
        guard let out = options["out"] else { throw CLIError.usage("torrent requires --out") }
        let pieceSizeBytes = try parsePieceSize(options["piece"] ?? "1024")
        let format = try parseFormat(options["format"] ?? "hybrid")

        let scan = try CorpusScanner.scan(root: dir)
        let hashing = try await CPUReferenceHasher().hash(
            scannedFiles: scan.files, pieceSizeBytes: pieceSizeBytes, format: format
        )
        let bytes = try BenchMetainfo.build(
            rootName: scan.rootName,
            isDirectory: scan.files.count > 1,
            files: scan.files,
            pieceSizeBytes: pieceSizeBytes,
            format: format,
            output: hashing
        )
        try bytes.write(to: URL(fileURLWithPath: out))
        print("torrent: wrote \(out) (\(bytes.count) bytes)")
    }

    static func supportCheck(arguments: [String]) async throws {
        let options = try parseOptions(arguments)
        let environment = MetalEnvironment(
            injection: options["inject-fail-device"] == "1"
                ? MetalInjection(failDeviceCreation: true)
                : .none
        )
        let report = await environment.report()
        print("supported=\(report.isSupported) device=\(report.devicePresent) library=\(report.libraryCompiles) selftest=\(report.selfTestPassed) lpm=\(report.lowPowerMode) thermal=\(report.thermalState) reason=\(report.reason ?? "nil")")
        if !report.libraryCompiles, let compileError = await environment.lastCompileError {
            print("compile-error: \(compileError)")
        }
    }
}
