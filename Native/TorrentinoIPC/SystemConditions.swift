// Layer: IPC (system condition vocabulary, plan §20.6 fault matrix).
// Role: the wire types the agent publishes when the environment changes —
// network reachability, thermal state, memory pressure, Low Power Mode and
// sleep state. The UI renders these as surfaced recovery states (never silent
// death); the coordinator uses them to gate engine work without busy loops.
// Must-not: carry per-torrent data (that lives in TorrentHealth), perform any
// I/O, or pretend a condition is known when no monitor reported it (the
// default is .unknown/.nominal/.normal — honest, not optimistic).
// Invariants: all types Codable + Sendable + Equatable + immutable; merge()
// is pure so tests can pin the aggregation semantics.

import Foundation

/// Effective network reachability (from NWPathMonitor status).
public enum NetworkReachability: String, Codable, Sendable, Equatable, CaseIterable {
    case unknown
    case satisfied
    case unsatisfied
    case requiresConnection

    public var isSatisfied: Bool { self == .satisfied }
}

/// Thermal state mapped from ProcessInfo.thermalState.
public enum ThermalCondition: String, Codable, Sendable, Equatable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    /// Serious/critical throttle engine work (plan §20.6: thermal → reduction).
    public var isConstrained: Bool { self == .serious || self == .critical }
}

/// Memory pressure from the DispatchSource.MemoryPressure source.
public enum MemoryPressureLevel: String, Codable, Sendable, Equatable, CaseIterable {
    case normal
    case warning
    case critical

    public var isConstrained: Bool { self != .normal }
}

/// The complete system condition snapshot the agent maintains.
public struct SystemConditions: Codable, Sendable, Equatable {
    public let network: NetworkReachability
    /// Bumped by the monitor whenever the network path changed (interface
    /// switch, VPN up/down) even when reachability stayed satisfied. The
    /// coordinator re-announces on a generation change.
    public let networkGeneration: UInt64
    public let thermal: ThermalCondition
    public let memoryPressure: MemoryPressureLevel
    public let lowPower: Bool
    public let sleeping: Bool

    public init(
        network: NetworkReachability,
        networkGeneration: UInt64,
        thermal: ThermalCondition,
        memoryPressure: MemoryPressureLevel,
        lowPower: Bool,
        sleeping: Bool
    ) {
        self.network = network
        self.networkGeneration = networkGeneration
        self.thermal = thermal
        self.memoryPressure = memoryPressure
        self.lowPower = lowPower
        self.sleeping = sleeping
    }

    /// The baseline: nothing reported yet, nothing constrained. Never used as
    /// a claim that the system is healthy — it is the "no evidence" default.
    public static let normal = SystemConditions(
        network: .unknown,
        networkGeneration: 0,
        thermal: .nominal,
        memoryPressure: .normal,
        lowPower: false,
        sleeping: false
    )

    /// True when engine work should be throttled (thermal/memory/Low Power).
    public var isResourceConstrained: Bool {
        thermal.isConstrained || memoryPressure.isConstrained || lowPower
    }

    /// True when the system is fully available for engine work.
    public var isFullyAvailable: Bool {
        !isResourceConstrained && !sleeping
    }

    /// Network work is suppressed for an unsatisfied path. `unknown` is
    /// intentionally allowed during bootstrap: no monitor result is not proof
    /// that the machine is offline, and the first path callback will settle it.
    public var canAttemptNetworkWork: Bool {
        network != .unsatisfied && network != .requiresConnection && !sleeping
    }

    /// Pure partial-update merge (the monitor calls this with only the fields
    /// its source just changed). Untouched fields keep their previous values.
    public func merged(
        network: NetworkReachability? = nil,
        networkGeneration: UInt64? = nil,
        thermal: ThermalCondition? = nil,
        memoryPressure: MemoryPressureLevel? = nil,
        lowPower: Bool? = nil,
        sleeping: Bool? = nil
    ) -> SystemConditions {
        SystemConditions(
            network: network ?? self.network,
            networkGeneration: networkGeneration ?? self.networkGeneration,
            thermal: thermal ?? self.thermal,
            memoryPressure: memoryPressure ?? self.memoryPressure,
            lowPower: lowPower ?? self.lowPower,
            sleeping: sleeping ?? self.sleeping
        )
    }
}

/// Bounded work profile selected from system pressure. These values are
/// policy, not an estimate of engine state; the agent still reports the
/// authoritative queue and torrent state separately.
public struct EngineResourceBudget: Codable, Sendable, Equatable {
    public let maxActiveDownloads: Int
    public let maxActiveSeeds: Int
    public let maxPeerConnections: Int
    public let maxConnectionAttempts: Int
    public let cacheBytes: Int64
    public let alertDrainBatch: Int
    public let maxReaddsPerPump: Int
    public let pumpIntervalNanoseconds: UInt64
    public let acceptsHeavyWork: Bool

    public init(
        maxActiveDownloads: Int,
        maxActiveSeeds: Int,
        maxPeerConnections: Int,
        maxConnectionAttempts: Int,
        cacheBytes: Int64,
        alertDrainBatch: Int,
        maxReaddsPerPump: Int,
        pumpIntervalNanoseconds: UInt64,
        acceptsHeavyWork: Bool
    ) {
        self.maxActiveDownloads = maxActiveDownloads
        self.maxActiveSeeds = maxActiveSeeds
        self.maxPeerConnections = maxPeerConnections
        self.maxConnectionAttempts = maxConnectionAttempts
        self.cacheBytes = cacheBytes
        self.alertDrainBatch = alertDrainBatch
        self.maxReaddsPerPump = maxReaddsPerPump
        self.pumpIntervalNanoseconds = pumpIntervalNanoseconds
        self.acceptsHeavyWork = acceptsHeavyWork
    }

    /// Balanced profile from plan §11.1. Every queue/attempt count is finite.
    public static let balanced = EngineResourceBudget(
        maxActiveDownloads: 4,
        maxActiveSeeds: 8,
        maxPeerConnections: 250,
        maxConnectionAttempts: 20,
        cacheBytes: 64 * 1024 * 1024,
        alertDrainBatch: 200,
        maxReaddsPerPump: 4,
        pumpIntervalNanoseconds: 500_000_000,
        acceptsHeavyWork: true
    )
}

/// Pure mapping from system observations to bounded work. Keeping this policy
/// in IPC makes the same behavior testable without starting Network.framework.
public enum SystemConditionPolicy {
    public static func budget(for conditions: SystemConditions) -> EngineResourceBudget {
        var budget = EngineResourceBudget.balanced
        if conditions.memoryPressure == .critical || conditions.thermal == .critical {
            budget = EngineResourceBudget(
                maxActiveDownloads: 1,
                maxActiveSeeds: 2,
                maxPeerConnections: 40,
                maxConnectionAttempts: 2,
                cacheBytes: 16 * 1024 * 1024,
                alertDrainBatch: 50,
                maxReaddsPerPump: 1,
                pumpIntervalNanoseconds: 2_000_000_000,
                acceptsHeavyWork: false
            )
        } else if conditions.isResourceConstrained {
            budget = EngineResourceBudget(
                maxActiveDownloads: 2,
                maxActiveSeeds: 4,
                maxPeerConnections: 100,
                maxConnectionAttempts: 5,
                cacheBytes: 32 * 1024 * 1024,
                alertDrainBatch: 100,
                maxReaddsPerPump: 2,
                pumpIntervalNanoseconds: 1_000_000_000,
                acceptsHeavyWork: false
            )
        }
        if conditions.network == .unsatisfied || conditions.network == .requiresConnection || conditions.sleeping {
            // Keep the profile finite while avoiding a timer that repeatedly
            // tries to reconnect an unavailable path.
            budget = EngineResourceBudget(
                maxActiveDownloads: budget.maxActiveDownloads,
                maxActiveSeeds: budget.maxActiveSeeds,
                maxPeerConnections: budget.maxPeerConnections,
                maxConnectionAttempts: 0,
                cacheBytes: budget.cacheBytes,
                alertDrainBatch: budget.alertDrainBatch,
                maxReaddsPerPump: 0,
                pumpIntervalNanoseconds: max(budget.pumpIntervalNanoseconds, 4_000_000_000),
                acceptsHeavyWork: false
            )
        }
        return budget
    }
}
