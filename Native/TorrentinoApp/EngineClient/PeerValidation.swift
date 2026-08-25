// Layer: UI-side peer code-signing policy (plan §23, WP-05).
// Role: the five frozen identities + validation helpers the UI enforces
// BEFORE any payload decode or mutation over XPC: static package preflight
// + exact dynamic live-PID SecCode validation. Rejects unsigned peers and
// same-Team/wrong-ID peers. Owns the identity constants for the app-side control plane.
// Must-not: decode payloads, mutate state, or perform network I/O.
// Invariants: identities are immutable and frozen; validation returns typed
// PeerValidationError values; no raw C++/libtorrent text ever leaks.
// Enforcement gate: Developer-ID (Release) builds enforce static package preflight
// + exact dynamic live-PID validation before trusting hello or sending health/payload/mutation.
// Debug builds are unsigned by design (no embedded agent, ad-hoc agent binary),
// so the checks are skipped there — WP-02 QA and local dev runs against the Debug app must keep working.

import Foundation
import Security

enum PeerValidation {
    /// The five immutable identities (plan §23, LIFECYCLE_CONTRACT.md).
    struct Identity: Sendable, Equatable {
        /// App signing ID (com.torrentino.app).
        let appSigningID: String
        /// Agent signing ID (com.torrentino.app.engine-agent).
        let agentSigningID: String
        /// LaunchAgent label registered via SMAppService.
        let launchAgentLabel: String
        /// Mach service name the agent checks into.
        let machServiceName: String
        /// LaunchAgent plist filename inside the app bundle.
        let plistFilename: String
    }

    /// Frozen identity set. The app-side control plane (ServiceRegistration,
    /// EngineClient) reads these; the agent-side XPC file freezes the same
    /// values independently.
    static let identity = Identity(
        appSigningID: "com.torrentino.app",
        agentSigningID: "com.torrentino.app.engine-agent",
        launchAgentLabel: "com.torrentino.app.engine-agent",
        machServiceName: "com.torrentino.app.engine-agent.mach",
        plistFilename: "com.torrentino.app.engine-agent.plist"
    )

    /// Frozen agent executable name ("TorrentinoEngineAgent").
    static let agentExecutableName = "TorrentinoEngineAgent"

    /// Developer ID team (frozen in Config/Shared.xcconfig).
    static let teamIdentifier = "438UQRF7JV"

    /// Whether the peer code-signing checks are enforced on this build.
    /// Release (Developer ID) ships with the agent embedded and signed, so
    /// the UI must reject unsigned/wrong-team peers. Debug cannot satisfy
    /// the checks (no embedded agent, ad-hoc signing) and skips them.
    static var isEnforcementActive: Bool {
#if DEBUG
        false
#else
        true
#endif
    }

    /// Requirement-language string the UI enforces on the agent connection:
    /// same Developer ID team (subject.OU) + exact agent identifier.
    static var expectedAgentRequirement: String {
        "identifier \"\(identity.agentSigningID)\" and anchor apple generic " +
        "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// Compiles a requirement-language expression into a SecRequirement.
    /// Nil means the expression is invalid (programmer error, fail loud).
    static func makeRequirement(_ expression: String) -> SecRequirement? {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(expression as CFString, [], &requirement)
        guard status == errSecSuccess else { return nil }
        return requirement
    }

    enum PeerValidationError: Error, Sendable, CustomStringConvertible, Equatable {
        /// Binary is not signed at all.
        case unsignedPeer
        /// Signed, but the designated requirement does not match our team or
        /// the expected identifier.
        case wrongTeamIdentifier
        /// Designated requirement could not be read (tooling/OS error).
        case codeSigningUnavailable(String)
        /// The embedded agent binary was not found where the app expects it.
        case agentBinaryNotFound(String)
        /// The frozen requirement expression failed to compile.
        case requirementInvalid
        /// Live process identifier is non-positive or invalid.
        case invalidLivePID
        /// Dynamic guest lookup via SecCodeCopyGuestWithAttributes failed.
        case dynamicGuestLookupFailed(String)
        /// Live agent process code-signing validity check against exact requirement failed.
        case liveRequirementMismatch
        /// Connection processIdentifier does not match the bootstrap hello PID.
        case helloPIDMismatch(connectionPID: pid_t, helloPID: Int64)

        var description: String {
            switch self {
            case .unsignedPeer: return "peer is unsigned"
            case .wrongTeamIdentifier: return "peer signing does not match team identifier"
            case .codeSigningUnavailable(let detail): return "code signing unavailable: \(detail)"
            case .agentBinaryNotFound(let path): return "agent binary not found at \(path)"
            case .requirementInvalid: return "frozen requirement expression is invalid"
            case .invalidLivePID: return "invalid live process identifier"
            case .dynamicGuestLookupFailed(let detail): return "dynamic guest lookup failed: \(detail)"
            case .liveRequirementMismatch: return "live agent requirement mismatch"
            case .helloPIDMismatch(let conn, let hello): return "connection PID (\(conn)) does not match hello PID (\(hello))"
            }
        }
    }

    /// Validates initial candidate PID against bootstrap hello PID.
    static func validateCandidatePIDs(
        connectionPID: pid_t,
        helloPID: Int64
    ) -> Result<pid_t, PeerValidationError> {
        guard connectionPID > 0 else {
            return .failure(.invalidLivePID)
        }
        guard Int64(connectionPID) == helloPID else {
            return .failure(.helloPIDMismatch(connectionPID: connectionPID, helloPID: helloPID))
        }
        return .success(connectionPID)
    }

    /// Validates that processIdentifier re-read after code-signing validation matches the initial validated PID.
    static func validatePostValidationPID(
        initialPID: pid_t,
        reReadPID: pid_t
    ) -> Result<pid_t, PeerValidationError> {
        guard reReadPID > 0, reReadPID == initialPID else {
            return .failure(.invalidLivePID)
        }
        return .success(initialPID)
    }

    /// Validates dynamic PID consistency across connection PID, bootstrap hello PID, and re-read PID.
    static func validateCandidatePIDs(
        connectionPID: pid_t,
        helloPID: Int64,
        reReadPID: pid_t
    ) -> Result<pid_t, PeerValidationError> {
        switch validateCandidatePIDs(connectionPID: connectionPID, helloPID: helloPID) {
        case .success(let pid):
            return validatePostValidationPID(initialPID: pid, reReadPID: reReadPID)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Validates the running agent process's dynamic code-signing requirement
    /// using SecCodeCopyGuestWithAttributes and SecCodeCheckValidity.
    static func validateRunningAgent(
        processIdentifier pid: pid_t,
        requirement: SecRequirement
    ) -> Result<Void, PeerValidationError> {
        switch TorrentinoXPCSecurity.validateDynamicPeer(processIdentifier: pid, requirement: requirement) {
        case .success:
            return .success(())
        case .failure(let error):
            switch error {
            case .invalidProcessIdentifier:
                return .failure(.invalidLivePID)
            case .guestLookupFailed(let status):
                return .failure(.dynamicGuestLookupFailed("SecCodeCopyGuestWithAttributes status=\(status)"))
            case .validityCheckFailed:
                return .failure(.liveRequirementMismatch)
            }
        }
    }

    /// Location of the agent binary embedded by the "Embed LaunchAgent" phase in a given bundle URL.
    static func embeddedAgentURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(agentExecutableName)", isDirectory: false)
    }

    /// Location of the agent binary embedded by the "Embed LaunchAgent" phase.
    static var embeddedAgentURL: URL {
        embeddedAgentURL(in: Bundle.main.bundleURL)
    }

    /// Validates the embedded agent binary's designated requirement BEFORE the
    /// UI decodes any peer payload: rejects unsigned binaries and binaries not
    /// signed by our team with our identifier.
    static func validateAgentBinary(at url: URL = PeerValidation.embeddedAgentURL) -> Result<Void, PeerValidationError> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(.agentBinaryNotFound(url.path))
        }
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return .failure(.codeSigningUnavailable("SecStaticCodeCreateWithPath status=\(createStatus)"))
        }
        // 1) Basic validity: rejects unsigned binaries and corrupt signatures.
        let validityStatus = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSBasicValidateOnly), nil)
        guard validityStatus == errSecSuccess else {
            // errSecCSUnsigned ⇒ not signed at all; anything else ⇒ invalid signature.
            return .failure(validityStatus == errSecCSUnsigned ? .unsignedPeer
                : .codeSigningUnavailable("SecStaticCodeCheckValidity status=\(validityStatus)"))
        }
        // 2) Team/identifier check: the frozen requirement (exact agent
        //    identifier + same Developer ID team, anchored to Apple generic)
        //    must be satisfied by the binary's designated requirement.
        guard let requirement = makeRequirement(expectedAgentRequirement) else {
            return .failure(.requirementInvalid)
        }
        let matchStatus = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement)
        guard matchStatus == errSecSuccess else {
            return .failure(.wrongTeamIdentifier)
        }
        return .success(())
    }
}
