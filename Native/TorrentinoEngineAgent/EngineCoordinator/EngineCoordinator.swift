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

        var error: NSError?
        guard let response = adapter.startEngine(configurationData: data, error: &error) else {
            throw error(for: error)
        }
        started = true
        return try decode(BootReportDTO.self, from: response)
    }

    /// Adds a torrent from a .torrent file bytes or a magnet URI (exactly one).
    public func add(specification: AddSpecificationDTO) throws -> AddResultDTO {
        guard started else { throw EngineCoordinatorError.notStarted }
        let data = try encode(specification)
        var error: NSError?
        guard let response = adapter.addTorrent(specificationData: data, error: &error) else {
            throw error(for: error)
        }
        return try decode(AddResultDTO.self, from: response)
    }

    public func pause(torrentID: String) throws {
        try voidCall { adapter.pause(payloadData: $0, error: &$1) }
    }

    public func resume(torrentID: String) throws {
        try voidCall { adapter.resume(payloadData: $0, error: &$1) }
    }

    public func recheck(torrentID: String) throws {
        try voidCall { adapter.recheck(payloadData: $0, error: &$1) }
    }

    /// Two-phase removal (ADR-010). prepare returns an opaque token; commit
    /// performs the actual removal and reports whether files were deleted.
    public func prepareRemoval(torrentID: String, deleteFiles: Bool = false) throws -> RemovalTokenDTO {
        guard started else { throw EngineCoordinatorError.notStarted }
        let payload = try encode(RemovalTokenDTO(torrentID: torrentID, deleteFiles: deleteFiles, nonce: 0))
        var error: NSError?
        guard let response = adapter.prepareRemoval(payloadData: payload, error: &error) else {
            throw error(for: error)
        }
        return try decode(RemovalTokenDTO.self, from: response)
    }

    public func commitRemoval(token: RemovalTokenDTO) throws -> RemovalResultDTO {
        guard started else { throw EngineCoordinatorError.notStarted }
        let data = try encode(token)
        var error: NSError?
        guard let response = adapter.commitRemoval(tokenData: data, error: &error) else {
            throw error(for: error)
        }
        return try decode(RemovalResultDTO.self, from: response)
    }

    /// Drains and returns the current alert batch (may be empty).
    public func drainAlerts(maxCount: Int = 100) throws -> [EngineAlertDTO] {
        guard started else { return [] } // engine not running: empty batch, like the bridge
        let payload = try encode(AlertDrainPayload(maxCount: maxCount))
        var error: NSError?
        guard let response = adapter.drainAlerts(payloadData: payload, error: &error) else {
            throw error(for: error)
        }
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
        var error: NSError?
        guard let response = adapter.requestResumeData(payloadData: payload, error: &error) else {
            throw error(for: error)
        }
        return try decode(ResumeDataDTO.self, from: response)
    }

    /// Returns the engine health snapshot.
    public func health() throws -> HealthDTO {
        var error: NSError?
        guard let response = adapter.health(error: &error) else {
            throw error(for: error)
        }
        return try decode(HealthDTO.self, from: response)
    }

    /// Re-bounds the operation deadline for subsequent engine calls.
    public func setOperationTimeout(millis: UInt32) throws {
        guard started else { throw EngineCoordinatorError.notStarted }
        let payload = try encode(TimeoutPayload(millis: millis))
        var error: NSError?
        guard let _ = adapter.setOperationTimeout(payloadData: payload, error: &error) else {
            throw error(for: error)
        }
    }

    /// Deterministic shutdown. Always safe, even if never started.
    public func shutdown() {
        adapter.shutdown()
        started = false
    }

    // MARK: - Envelope helpers (JSON wire schema, frozen)

    private struct TorrentIDPayload: Codable {
        let torrentID: String
        enum CodingKeys: String, CodingKey { case torrentID = "torrent-id" }
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

    /// Runs a void adapter call; throws if the adapter returned an NSError.
    private func voidCall(_ call: (Data, inout NSError?) throws -> Data?) throws {
        guard started else { throw EngineCoordinatorError.notStarted }
        var error: NSError?
        let payload = Data("{}".utf8)
        _ = try call(payload, &error)
        if let error {
            throw error(for: error)
        }
    }

    /// Maps an NSError produced by the adapter to an EngineCoordinatorError,
    /// preserving the localized bridge message for diagnostics.
    private func error(for error: NSError?) -> EngineCoordinatorError {
        guard let error else {
            return .internalError
        }
        let base = EngineCoordinatorError.bridgeError(from: error.code)
        switch base {
        case .internalError:
            return .malformedPayload(error.localizedDescription)
        default:
            return base
        }
    }
}