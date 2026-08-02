// Layer: IPC (snapshot reconciliation, plan §8.2 gate "dropped delta").
// Role: decide whether a delta can be applied or a full snapshot is required.
// Deltas are only contiguous (engineRevision == lastSeen + 1); any gap means
// the UI dropped events. An instanceID change invalidates everything.
// Must-not: hold state — all decisions are pure functions of revisions.
// Invariants: monotonic engine revisions; instance change ⇒ full snapshot.

import Foundation

public enum SnapshotReconciliation {
    /// The UI has never seen this agent process (or saw a different one):
    /// every cached snapshot is invalid, full refetch required.
    public static func needsFullSnapshot(currentInstanceID: UUID?, latestInstanceID: UUID) -> Bool {
        guard let currentInstanceID else { return true }
        return currentInstanceID != latestInstanceID
    }

    /// A delta is applicable only when it continues exactly where the UI is.
    public static func isDeltaApplicable(deltaRevision: UInt64, lastSeenRevision: UInt64) -> Bool {
        deltaRevision == lastSeenRevision + 1
    }

    /// The UI is behind by more than one engine revision (or has no anchor):
    /// the dropped delta cannot be repaired locally — full snapshot required.
    public static func needsFullSnapshot(afterRevision: UInt64?, latestEngineRevision: UInt64) -> Bool {
        guard let afterRevision else { return true }
        return latestEngineRevision > afterRevision + 1
    }

    /// Guard: engine revisions must be strictly monotonic.
    public static func isStrictlyMonotonic(_ revisions: [UInt64]) -> Bool {
        for index in 1..<revisions.count where revisions[index] <= revisions[index - 1] {
            return false
        }
        return true
    }
}
