// Layer: UI (Settings apply seam).
// Role: THE single application-level request-building and apply path for the
//       Settings window (WP13-SEC-HARDEN-001 REVIEW-002, TEST-HONESTY-UI-CHAIN).
//       The real SettingsView.applySettings delegates here, and
//       TorrentinoAppTests drive these very functions with a REAL KeychainStore
//       plus a spying send closure that captures the actual outgoing
//       ApplySettingsRequest. There is no mirrored duplicate in the tests, so a
//       mutation that drops the Keychain attachment (e.g. sending nil instead
//       of proxyPasswordForDelivery(kind:entered:)) makes the captured
//       request carry no credential while the Keychain holds one — every
//       captured-request assertion fails structurally.
// Must-not: touch SwiftUI state, persist credentials anywhere but
//       KeychainStore (and only after the agent accepted the transaction), or
//       bypass ApplySettingsRequest.proxyPasswordForDelivery.
// Invariants: the durable candidate stays credential-free (password: nil);
//       the credential crosses IPC exactly once, memory-only, in the request's
//       delivery field.
//
// Two-leg composition: this leg proves the UI chain honestly (real Keychain →
// seam → captured wire request). The captured request SHAPE — optional
// `proxyPassword` on the envelope, credential-free `candidate.proxy` — is the
// same shape the live bridge harness leg exercises end-to-end through
// EngineCoordinator → EngineBridgeAdapter → EngineBridge → libtorrent 2.1.1
// (`scripts/test_bridge_swift.sh`). Together they cover UI→IPC and IPC→engine;
// neither leg alone proves the whole chain.

import Foundation
import TorrentinoIPC

enum SettingsApplyFlow {
    /// Raw form state exactly as SettingsView holds it. `proxyPassword` is the
    /// SecureField value seeded by `KeychainStore.loadProxyPassword()` at load
    /// time — the value delivered on apply.
    struct FormInput: Sendable {
        var downloadDir: String
        var maxDownKB: String
        var maxUpKB: String
        var listenPort: String
        var dhtEnabled: Bool
        var lsdEnabled: Bool
        var upnpEnabled: Bool
        var natPmpEnabled: Bool
        var encryptionEnabled: Bool
        var proxyKind: ProxyConfiguration.Kind
        var proxyHost: String
        var proxyPort: String
        var proxyUsername: String
        var proxyPassword: String
    }

    enum BuildFailure: Error, Equatable {
        /// No fetched revision yet — apply is impossible without it.
        case missingRevision
        case validation([SettingsValidationError])
    }

    enum ApplyOutcome {
        case applied(revision: SettingsRevision, credentialsSaved: Bool)
        case failed(Error)
    }

    /// Error raised by the seam itself (not propagated transport errors).
    enum FlowError: Error, Equatable {
        case unexpectedReply
    }

    /// Builds the exact outgoing request: parse form values, validate the
    /// candidate, run the side-effect-free UI preflight transaction, then
    /// attach the Keychain-seeded credential via the single delivery rule.
    static func makeRequest(
        from input: FormInput,
        expectedRevision: SettingsRevision?
    ) -> Result<ApplySettingsRequest, BuildFailure> {
        guard let expectedRevision else {
            return .failure(.missingRevision)
        }

        var validationErrors: [SettingsValidationError] = []
        func parsedRate(_ value: String, field: String) -> Int64? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0 }
            guard let kilobytes = Int64(trimmed) else {
                validationErrors.append(
                    SettingsValidationError(field: field, message: "settings.validation.number_required")
                )
                return nil
            }
            let conversion = kilobytes.multipliedReportingOverflow(by: 1024)
            guard !conversion.overflow else {
                validationErrors.append(
                    SettingsValidationError(field: field, message: "settings.validation.number_required")
                )
                return nil
            }
            return conversion.partialValue
        }

        guard let downRate = parsedRate(input.maxDownKB, field: "maxDownloadBytesPerSec"),
              let upRate = parsedRate(input.maxUpKB, field: "maxUploadBytesPerSec") else {
            return .failure(.validation(validationErrors))
        }
        let port = UInt16(input.listenPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let proxyPortValue = UInt16(input.proxyPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        let candidate = EngineSettings(
            downloadDirectory: input.downloadDir,
            maxDownloadBytesPerSec: downRate,
            maxUploadBytesPerSec: upRate,
            listenPort: port,
            dhtEnabled: input.dhtEnabled,
            lsdEnabled: input.lsdEnabled,
            upnpEnabled: input.upnpEnabled,
            natPmpEnabled: input.natPmpEnabled,
            encryptionEnabled: input.encryptionEnabled,
            proxy: ProxyConfiguration(
                kind: input.proxyKind,
                host: input.proxyHost.trimmingCharacters(in: .whitespacesAndNewlines),
                port: proxyPortValue,
                username: input.proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : input.proxyUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: nil
            )
        )

        let errors = SettingsRules.validate(candidate)
        guard errors.isEmpty else {
            return .failure(.validation(errors))
        }

        // Side-effect-free UI preflight; the agent repeats the same
        // transaction with its real persistence/apply/rollback context.
        let preflight = SettingsTransaction.run(
            candidate: candidate,
            expectedRevision: expectedRevision,
            context: SettingsTransaction.Context(
                currentRevision: expectedRevision,
                persist: { _, revision in revision + 1 },
                apply: { _ in .success(()) },
                rollback: { _, _ in }
            )
        )
        guard case .applied = preflight else {
            return .failure(.validation([]))
        }

        // SEC-1 credential delivery: the Keychain-seeded form value crosses
        // IPC exactly here; the durable candidate stays credential-free.
        let deliveredProxyPassword = ApplySettingsRequest.proxyPasswordForDelivery(
            kind: input.proxyKind,
            entered: input.proxyPassword
        )
        return .success(ApplySettingsRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            candidate: candidate,
            expectedRevision: expectedRevision,
            proxyPassword: deliveredProxyPassword
        ))
    }

    /// Sends the built request and commits or clears the Keychain credential
    /// only AFTER the agent accepted the complete transaction. A failed send
    /// leaves the prior Keychain state untouched (prior state preserved).
    static func apply(
        _ request: ApplySettingsRequest,
        send: @escaping @Sendable (EngineCommandV1) async throws -> SuccessPayload
    ) async -> ApplyOutcome {
        do {
            guard case .settingsApply(let result) = try await send(.applySettings(request)) else {
                throw FlowError.unexpectedReply
            }
            // The credential crossed IPC once, memory-only, inside the
            // request above; the agent persists it nowhere. Keychain remains
            // the only durable secret store app-side, committed after the
            // agent accepted the complete transaction.
            let credentialsSaved: Bool
            if let deliveredProxyPassword = request.proxyPassword {
                credentialsSaved = await KeychainStore.saveProxyPassword(deliveredProxyPassword)
            } else {
                credentialsSaved = await KeychainStore.deleteProxyPassword()
            }
            return .applied(revision: result.revision, credentialsSaved: credentialsSaved)
        } catch {
            return .failed(error)
        }
    }
}
