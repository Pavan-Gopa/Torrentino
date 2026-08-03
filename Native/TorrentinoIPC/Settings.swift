// Layer: IPC (settings protocol, plan §7.4 transactional apply).
// Role: the settings contract between UI and agent: immutable candidate
// values, revision-based optimistic concurrency, and a transaction whose
// steps (validate → revision check → persist → apply → rollback on failure)
// are enforced before any revision is published.
// Must-not: perform I/O itself — persistence/apply are injected by the agent.
// Invariants: EngineSettings is immutable; SettingsRevision is agent-owned;
// a failed apply rolls the persisted revision back.

import Foundation

/// Agent-owned settings revision. Every successful apply bumps it exactly once.
public typealias SettingsRevision = UInt64

/// Candidate settings snapshot (v1 surface). All fields are always present;
/// partial edits are expressed as a full candidate the UI assembled.
public struct EngineSettings: Codable, Sendable, Equatable {
    public let downloadDirectory: String
    public let maxDownloadBytesPerSec: Int64
    public let maxUploadBytesPerSec: Int64
    public let listenPort: UInt16
    public let dhtEnabled: Bool
    public let lsdEnabled: Bool
    public let upnpEnabled: Bool
    public let natPmpEnabled: Bool
    public let encryptionEnabled: Bool

    public init(
        downloadDirectory: String,
        maxDownloadBytesPerSec: Int64,
        maxUploadBytesPerSec: Int64,
        listenPort: UInt16,
        dhtEnabled: Bool,
        lsdEnabled: Bool,
        upnpEnabled: Bool,
        natPmpEnabled: Bool,
        encryptionEnabled: Bool
    ) {
        self.downloadDirectory = downloadDirectory
        self.maxDownloadBytesPerSec = maxDownloadBytesPerSec
        self.maxUploadBytesPerSec = maxUploadBytesPerSec
        self.listenPort = listenPort
        self.dhtEnabled = dhtEnabled
        self.lsdEnabled = lsdEnabled
        self.upnpEnabled = upnpEnabled
        self.natPmpEnabled = natPmpEnabled
        self.encryptionEnabled = encryptionEnabled
    }

    /// v1 defaults. Not a source of truth — only the fallback before the agent
    /// has published its first revision.
    public static let `default` = EngineSettings(
        downloadDirectory: "~/Downloads",
        maxDownloadBytesPerSec: 0,
        maxUploadBytesPerSec: 0,
        listenPort: 6881,
        dhtEnabled: true,
        lsdEnabled: true,
        upnpEnabled: true,
        natPmpEnabled: true,
        encryptionEnabled: true
    )
}

/// One validation problem: which field and why. Shown verbatim in the UI.
public struct SettingsValidationError: Codable, Sendable, Equatable {
    public let field: String
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }
}

/// Pure validation rules. No I/O, no side effects — fully testable.
public enum SettingsRules {
    /// Returns every rule violation in the candidate, empty when valid.
    public static func validate(_ settings: EngineSettings) -> [SettingsValidationError] {
        var errors: [SettingsValidationError] = []
        if settings.downloadDirectory.isEmpty {
            errors.append(SettingsValidationError(field: "downloadDirectory", message: "must not be empty"))
        }
        if settings.maxDownloadBytesPerSec < 0 {
            errors.append(SettingsValidationError(field: "maxDownloadBytesPerSec", message: "must be >= 0"))
        }
        if settings.maxUploadBytesPerSec < 0 {
            errors.append(SettingsValidationError(field: "maxUploadBytesPerSec", message: "must be >= 0"))
        }
        if settings.listenPort < 1 || settings.listenPort > 65535 {
            errors.append(SettingsValidationError(field: "listenPort", message: "must be between 1 and 65535"))
        }
        return errors
    }
}

/// The settings apply transaction (plan §7.4):
/// 1. validate the candidate without touching the active config;
/// 2. check expectedRevision against the current one;
/// 3. persist the candidate (durably);
/// 4. apply to the engine;
/// 5. on apply failure, roll the persisted state back;
/// 6. only then is the new revision considered published.
public struct SettingsTransaction: Sendable {
    /// Agent-provided side effects, injected so the IPC layer stays pure.
    public struct Context: Sendable {
        public let currentRevision: SettingsRevision
        /// Persists the candidate and returns the NEW revision. Throwing means
        /// the store rejected the write.
        public let persist: @Sendable (EngineSettings, SettingsRevision) throws -> SettingsRevision
        /// Applies the candidate to the live engine.
        public let apply: @Sendable (EngineSettings) -> Result<Void, EngineFault>
        /// Reverts the persisted state to the pre-transaction revision.
        public let rollback: @Sendable (EngineSettings, SettingsRevision) throws -> Void

        public init(
            currentRevision: SettingsRevision,
            persist: @escaping @Sendable (EngineSettings, SettingsRevision) throws -> SettingsRevision,
            apply: @escaping @Sendable (EngineSettings) -> Result<Void, EngineFault>,
            rollback: @escaping @Sendable (EngineSettings, SettingsRevision) throws -> Void
        ) {
            self.currentRevision = currentRevision
            self.persist = persist
            self.apply = apply
            self.rollback = rollback
        }
    }

    /// Async side effects used by the agent, whose persistence store and live
    /// engine are actor-isolated. The synchronous Context remains available to
    /// keep the pure IPC transaction tests and callers deterministic.
    public struct AsyncContext: Sendable {
        public let currentRevision: SettingsRevision
        public let persist: @Sendable (EngineSettings, SettingsRevision) async throws -> SettingsRevision
        public let apply: @Sendable (EngineSettings) async -> Result<Void, EngineFault>
        public let rollback: @Sendable (EngineSettings, SettingsRevision) async throws -> Void

        public init(
            currentRevision: SettingsRevision,
            persist: @escaping @Sendable (EngineSettings, SettingsRevision) async throws -> SettingsRevision,
            apply: @escaping @Sendable (EngineSettings) async -> Result<Void, EngineFault>,
            rollback: @escaping @Sendable (EngineSettings, SettingsRevision) async throws -> Void
        ) {
            self.currentRevision = currentRevision
            self.persist = persist
            self.apply = apply
            self.rollback = rollback
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// Persisted + applied; this is the new published revision.
        case applied(revision: SettingsRevision)
        case validationFailed([SettingsValidationError])
        /// expectedRevision did not match the agent's current revision.
        case revisionConflict(current: SettingsRevision)
        case failed(EngineFault)
    }

    /// Runs the full transaction. Pure control flow; all side effects are the
    /// caller's closures. Thread-safe: no mutable state escapes this call.
    public static func run(
        candidate: EngineSettings,
        expectedRevision: SettingsRevision?,
        context: Context,
        validation: (EngineSettings) -> [SettingsValidationError] = SettingsRules.validate
    ) -> Outcome {
        let errors = validation(candidate)
        guard errors.isEmpty else { return .validationFailed(errors) }

        if let expectedRevision, expectedRevision != context.currentRevision {
            return .revisionConflict(current: context.currentRevision)
        }

        let newRevision: SettingsRevision
        do {
            newRevision = try context.persist(candidate, context.currentRevision)
        } catch {
            return .failed(EngineFault.storeError(underlying: error))
        }

        switch context.apply(candidate) {
        case .success:
            return .applied(revision: newRevision)
        case .failure(let fault):
            do {
                try context.rollback(candidate, newRevision)
                return .failed(fault)
            } catch {
                return .failed(EngineFault.storeError(underlying: error))
            }
        }
    }

    /// Runs the same transaction for actor-backed persistence and apply
    /// operations. Validation and revision checks still happen before any I/O.
    public static func run(
        candidate: EngineSettings,
        expectedRevision: SettingsRevision?,
        context: AsyncContext,
        validation: @Sendable (EngineSettings) -> [SettingsValidationError] = SettingsRules.validate
    ) async -> Outcome {
        let errors = validation(candidate)
        guard errors.isEmpty else { return .validationFailed(errors) }

        if let expectedRevision, expectedRevision != context.currentRevision {
            return .revisionConflict(current: context.currentRevision)
        }

        let newRevision: SettingsRevision
        do {
            newRevision = try await context.persist(candidate, context.currentRevision)
        } catch {
            return .failed(EngineFault.storeError(underlying: error))
        }

        switch await context.apply(candidate) {
        case .success:
            return .applied(revision: newRevision)
        case .failure(let fault):
            do {
                try await context.rollback(candidate, newRevision)
                return .failed(fault)
            } catch {
                return .failed(EngineFault.storeError(underlying: error))
            }
        }
    }
}

extension EngineFault {
    /// Store-layer failure inside a settings transaction.
    public static func storeError(underlying: Error) -> EngineFault {
        EngineFault(
            code: .storeError,
            severity: .error,
            recoveryActions: ["retry_op", "export_diagnostics"],
            redactedContext: String(describing: underlying)
        )
    }
}
