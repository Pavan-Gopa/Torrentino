// Layer: EngineCoordinator (WP-04 bridge actor).
// Role:     the Swift-side owner of the native engine. Creates the ObjC++
//           adapter INSIDE the actor (so C++ pointers never cross the
//           concurrency boundary), serializes every engine call, and converts
//           the adapter's NSData JSON envelopes / NSError into Sendable DTOs.
// Must not: leak the adapter or any C++ pointer to callers, block the actor
//           forever (adapter calls are bounded by EngineBridge deadlines), or
//           run without a matching EngineBridgeAdapter in the process.
// Invariants: exactly one adapter per coordinator; start() before any other
//           call; shutdown() is idempotent and safe to call from deinit paths.

import Foundation
import TorrentinoIPC

/// Swift actor owning the native engine through the ObjC++ bridge adapter.
/// All calls are serialized; each returns Sendable, immutable DTOs.
public actor EngineCoordinator {
    private let adapter: TorrentinoEngineBridgeAdapter
    private var started = false

    public init() {
        // The adapter is created here, inside the actor: any C++/ObjC object it
        // owns stays on the main/actor heap and never crosses a boundary.
        self.adapter = TorrentinoEngineBridgeAdapter()
    }

    // MARK: - Engine lifecycle

    /// Starts the engine. `configuration` may be nil to use bridge defaults.
    /// Returns the boot report describing the actual bound port and peer ID.
    public func start(configuration: SessionConfigurationDTO? = nil) throws -> BootReportDTO {
        // If already running, fail fast client-side: the bridge returns
        // alreadyStarted as well, but keeping the state here avoids two actors
        // racing through the same bridge.
        guard !started else { throw EngineCoordinatorError.alreadyStarted }

        let data: Data
        if let configuration {
            guard let encoded = try? JSONEncoder().encode(configuration) else {
                throw EngineCoordinatorError.internalError
            }
            data = encoded
        } else {
            data = Data("{}".utf8)
        }

        let response = try envelope { try adapter.startEngine(withConfigurationData: data) }
        started = true
        return try decode(BootReportDTO.self, from: response)
    }

    /// Applies the agent's complete settings candidate to the live session.
    /// The bridge applies settings asynchronously inside libtorrent without
    /// destroying torrent handles. The download directory is retained by the
    /// bridge as the default for future add requests.
    public func apply(settings: EngineSettings) throws {
        let configuration = Self.sessionConfiguration(for: settings)
        if started {
            let data = try encode(configuration)
            _ = try envelope { try adapter.applyEngine(withConfigurationData: data) }
        } else {
            _ = try start(configuration: configuration)
        }
    }

    public func setLimits(torrentID: String, limits: TorrentinoIPC.TransferLimits) throws {
        let payload = try encode(TorrentLimitsPayload(torrentID: torrentID, limits: limits))
        try voidCall(payload) { try adapter.setLimitsWithPayloadData($0) }
    }

    public func editTrackers(torrentID: String, trackers: [String]) throws {
        let payload = try encode(TrackersPayload(torrentID: torrentID, trackers: trackers))
        try voidCall(payload) { try adapter.editTrackers(withPayloadData: $0) }
    }

    public func reannounce(torrentID: String) throws {
        let payload = try encode(TorrentIDPayload(torrentID: torrentID))
        try voidCall(payload) { try adapter.reannounce(withPayloadData: $0) }
    }

    /// Adds a torrent from a .torrent file bytes or a magnet URI (exactly one).
    public func add(specification: AddSpecificationDTO) throws -> AddResultDTO {
        guard started else { throw EngineCoordinatorError.notStarted }
        let data = try encode(specification)
        let response = try envelope { try adapter.addTorrent(withSpecificationData: data) }
        return try decode(AddResultDTO.self, from: response)
    }

    public func pause(torrentID: String) throws {
        let payload = try encode(TorrentIDPayload(torrentID: torrentID))
        try voidCall(payload) { try adapter.pause(withPayloadData: $0) }
    }

    public func resume(torrentID: String) throws {
        let payload = try encode(TorrentIDPayload(torrentID: torrentID))
        try voidCall(payload) { try adapter.resume(withPayloadData: $0) }
    }

    public func recheck(torrentID: String) throws {
        let payload = try encode(TorrentIDPayload(torrentID: torrentID))
        try voidCall(payload) { try adapter.recheck(withPayloadData: $0) }
    }

    /// Two-phase removal (ADR-010). prepare returns an opaque token; commit
    /// performs the actual removal and reports whether files were deleted.
    public func prepareRemoval(torrentID: String, deleteFiles: Bool = false) throws -> RemovalTokenDTO {
        guard started else { throw EngineCoordinatorError.notStarted }
        let payload = try encode(RemovalTokenDTO(torrentID: torrentID, deleteFiles: deleteFiles, nonce: 0))
        let response = try envelope { try adapter.prepareRemoval(withPayloadData: payload) }
        return try decode(RemovalTokenDTO.self, from: response)
    }

    public func commitRemoval(token: RemovalTokenDTO) throws -> RemovalResultDTO {
        guard started else { throw EngineCoordinatorError.notStarted }
        let data = try encode(token)
        let response = try envelope { try adapter.commitRemoval(withTokenData: data) }
        return try decode(RemovalResultDTO.self, from: response)
    }

    /// Drains and returns the current alert batch (may be empty).
    public func drainAlerts(maxCount: Int = 100) throws -> [EngineAlertDTO] {
        guard started else { return [] } // engine not running: empty batch, like the bridge
        let payload = try encode(AlertDrainPayload(maxCount: maxCount))
        let response = try envelope { try adapter.drainAlerts(withPayloadData: payload) }
        do {
            let decoder = JSONDecoder()
            return try decoder.decode([EngineAlertDTO].self, from: response)
        } catch {
            throw EngineCoordinatorError.malformedPayload("alert batch: \(error)")
        }
    }

    /// Requests bencoded resume data for a torrent (bounded by engine timeout).
    public func requestResumeData(torrentID: String) throws -> ResumeDataDTO {
        guard started else { throw EngineCoordinatorError.notStarted }
        let payload = try encode(TorrentIDPayload(torrentID: torrentID))
        let response = try envelope { try adapter.requestResumeData(withPayloadData: payload) }
        return try decode(ResumeDataDTO.self, from: response)
    }

    /// Returns the engine health snapshot.
    public func health() throws -> HealthDTO {
        let response = try envelope { try adapter.health() }
        return try decode(HealthDTO.self, from: response)
    }

    /// Re-bounds the operation deadline for subsequent engine calls.
    public func setOperationTimeout(millis: UInt32) throws {
        guard started else { throw EngineCoordinatorError.notStarted }
        let payload = try encode(TimeoutPayload(millis: millis))
        _ = try envelope { try adapter.setOperationTimeoutWithPayloadData(payload) }
    }

    /// Deterministic shutdown. Always safe, even if never started.
    public func shutdown() {
        adapter.shutdown()
        started = false
    }

    private static func sessionConfiguration(for settings: EngineSettings) -> SessionConfigurationDTO {
        SessionConfigurationDTO(
            listenPort: Int(settings.listenPort),
            downloadDir: settings.downloadDirectory,
            enableDHT: settings.dhtEnabled,
            enableLSD: settings.lsdEnabled,
            enableUPnP: settings.upnpEnabled,
            enableNATPMP: settings.natPmpEnabled,
            encryptionEnabled: settings.encryptionEnabled,
            maxDownloadBytesPerSec: settings.maxDownloadBytesPerSec,
            maxUploadBytesPerSec: settings.maxUploadBytesPerSec,
            proxy: SessionProxyDTO(
                kind: settings.proxy.kind.rawValue,
                host: settings.proxy.host,
                port: settings.proxy.port,
                username: settings.proxy.username
            )
        )
    }

    // MARK: - Envelope helpers (JSON wire schema, frozen)

    private struct TorrentIDPayload: Codable {
        let torrentID: String
        enum CodingKeys: String, CodingKey { case torrentID = "torrent-id" }
    }

    private struct TorrentLimitsPayload: Codable {
        let torrentID: String
        let limits: TorrentinoIPC.TransferLimits

        enum CodingKeys: String, CodingKey {
            case torrentID = "torrent-id"
            case limits
        }
    }

    private struct TrackersPayload: Codable {
        let torrentID: String
        let trackers: [String]

        enum CodingKeys: String, CodingKey {
            case torrentID = "torrent-id"
            case trackers
        }
    }

    private struct AlertDrainPayload: Codable {
        let maxCount: Int
        enum CodingKeys: String, CodingKey { case maxCount = "max-count" }
    }

    private struct TimeoutPayload: Codable {
        let millis: UInt32
        enum CodingKeys: String, CodingKey { case millis = "millis" }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw EngineCoordinatorError.malformedPayload("encode: \(error)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw EngineCoordinatorError.malformedPayload("decode \(type): \(error)")
        }
    }

    /// Runs an adapter call that returns a JSON envelope; maps any bridge
    /// NSError into an EngineCoordinatorError. A nil envelope without an error
    /// is an adapter contract violation and surfaces as internalError.
    private func envelope(_ call: () throws -> Data?) throws -> Data {
        do {
            guard let response = try call() else {
                throw EngineCoordinatorError.internalError
            }
            return response
        } catch let error as EngineCoordinatorError {
            throw error
        } catch {
            throw mapError(error)
        }
    }

    /// Runs a void adapter call with an explicit payload; throws if the
    /// adapter returned an NSError. The payload is always produced by the
    /// caller (e.g. TorrentIDPayload) so no operation silently drops its
    /// arguments on the wire.
    private func voidCall(_ payload: Data, _ call: (Data) throws -> Data?) throws {
        guard started else { throw EngineCoordinatorError.notStarted }
        do {
            _ = try call(payload)
        } catch let error as EngineCoordinatorError {
            throw error
        } catch {
            throw mapError(error)
        }
    }

    /// Maps an NSError produced by the adapter to an EngineCoordinatorError,
    /// preserving the localized bridge message for diagnostics.
    private func mapError(_ error: any Error) -> EngineCoordinatorError {
        let nsError = error as NSError
        if nsError.code == 10 {
            return .unsupportedOperation(nsError.localizedDescription)
        }
        let base = EngineCoordinatorError.bridgeError(from: nsError.code)
        switch base {
        case .internalError:
            return .malformedPayload(nsError.localizedDescription)
        default:
            return base
        }
    }
}
