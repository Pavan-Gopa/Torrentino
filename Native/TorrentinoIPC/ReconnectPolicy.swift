// Layer: IPC (client reconnect policy, plan §8.4 + WP-02 bounded retries).
// Role: the shared, testable contract for bounded reconnects: attempt budget
// and backoff schedule. The EngineClient consumes this instead of local
// constants so both sides of the contract agree on "how long is too long".
// Must-not: open connections or track live state — pure schedule math.
// Invariants: attempts are 0-based; attempt >= maxAttempts has no delay
// (budget exhausted); backoff is strictly non-decreasing.

import Foundation

public struct ClientReconnectPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let backoffNanoseconds: [UInt64]

    public init(maxAttempts: Int, backoffNanoseconds: [UInt64]) {
        self.maxAttempts = maxAttempts
        self.backoffNanoseconds = backoffNanoseconds
    }

    /// The standard policy: 5 attempts, 250ms → 4s exponential backoff.
    public static let standard = ClientReconnectPolicy(
        maxAttempts: 5,
        backoffNanoseconds: [
            250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000, 4_000_000_000,
        ]
    )

    /// Delay before attempt `attempt` (0-based). Returns 0 for the first
    /// attempt and nil when the budget is exhausted.
    public func delayNanoseconds(forAttempt attempt: Int) -> UInt64? {
        guard attempt >= 0, attempt < maxAttempts else { return nil }
        guard attempt > 0 else { return 0 }
        let index = min(attempt - 1, max(backoffNanoseconds.count - 1, 0))
        return backoffNanoseconds[index]
    }

    /// True when attempt `attempt` lies outside the budget.
    public func isBudgetExhausted(afterAttempt attempt: Int) -> Bool {
        attempt >= maxAttempts
    }
}
