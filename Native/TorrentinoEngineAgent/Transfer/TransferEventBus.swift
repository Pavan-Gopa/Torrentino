// Layer: EngineAgent (Transfer).
// Role: coalesced publisher of EngineEventV1 pushes to registered sinks
// (the XPC event channel). Events are batched per flush interval so a burst
// of torrent updates lands as one delta; snapshotRequired events bypass the
// coalescing window and flush immediately.
// Must-not: block the coordinator, retain sinks forever (unregister on
// disconnect), or drop events silently after a failure (delivery is
// best-effort per sink, but the batch is still produced).
// Invariants: actor-confined; publish() is async and never throws.

import Foundation
import OSLog
import TorrentinoIPC

actor TransferEventBus {
    struct Sink: Sendable {
        let id: UUID
        let deliver: @Sendable ([EngineEventV1]) async -> Void
    }

    private var sinks: [UUID: Sink] = [:]
    private var pending: [EngineEventV1] = []
    private var flushTask: Task<Void, Never>?
    private var activeDeliveries: Set<UUID> = []
    /// At most one not-yet-started batch is retained per sink. A slow XPC
    /// consumer therefore coalesces to the newest authoritative batch instead
    /// of creating one Task and one retained array per update.
    private var queuedDeliveries: [UUID: [EngineEventV1]] = [:]
    /// Coalescing window; 0 disables batching (immediate flush).
    private let flushIntervalNanoseconds: UInt64
    private let maxPendingEvents: Int
    private var didOverflow = false
    private let healthReporter: (any EngineHealthReporter)?
    private let log = Logger(subsystem: "com.torrentino.app.engine-agent", category: "transfer")

    init(
        flushIntervalMilliseconds: Double = 50,
        maxPendingEvents: Int = 256,
        healthReporter: (any EngineHealthReporter)? = nil
    ) {
        self.flushIntervalNanoseconds = UInt64(max(0, flushIntervalMilliseconds) * 1_000_000)
        self.maxPendingEvents = max(1, maxPendingEvents)
        self.healthReporter = healthReporter
    }

    func register(_ sink: Sink) {
        sinks[sink.id] = sink
    }

    func unregister(id: UUID) {
        sinks.removeValue(forKey: id)
        queuedDeliveries.removeValue(forKey: id)
    }

    func sinkCount() -> Int {
        sinks.count
    }

    func pendingEventCount() -> Int {
        pending.count + queuedDeliveries.values.reduce(0) { $0 + $1.count }
    }

    func overflowed() -> Bool {
        didOverflow
    }

    /// Queues events for the next flush. `urgent` events (snapshotRequired,
    /// lifecycle) flush immediately.
    func publish(_ events: [EngineEventV1], urgent: Bool = false) {
        guard !events.isEmpty else { return }
        if pending.count + events.count > maxPendingEvents {
            // The queue no longer contains a complete delta. A full snapshot
            // is the only honest recovery; silently dropping arbitrary events
            // would make the UI look authoritative while being stale.
            pending.removeAll(keepingCapacity: true)
            pending.append(.snapshotRequired(SnapshotRequiredEvent(reason: .droppedDelta, afterRevision: 0)))
            didOverflow = true
        }
        let room = max(0, maxPendingEvents - pending.count)
        pending.append(contentsOf: events.prefix(room))
        healthReporter?.updateEventQueueDepth(pending.count)
        if urgent || flushIntervalNanoseconds == 0 {
            flushNow()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.flushIntervalNanoseconds ?? 50_000_000)
                guard let self else { return }
                await self.flushNow()
            }
        }
    }

    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        healthReporter?.updateEventQueueDepth(0)
        let sinkValues = Array(sinks.values)
        for sink in sinkValues {
            if activeDeliveries.contains(sink.id) {
                // Replace stale queued state with the newest batch. The batch
                // already contains a snapshotRequired marker after overflow.
                queuedDeliveries[sink.id] = batch
            } else {
                activeDeliveries.insert(sink.id)
                Task { [weak self] in
                    await sink.deliver(batch)
                    await self?.deliveryFinished(id: sink.id)
                }
            }
        }
        log.debug("published \(batch.count) events to \(sinkValues.count) sink(s)")
    }

    private func deliveryFinished(id: UUID) {
        guard activeDeliveries.contains(id) else { return }
        if let next = queuedDeliveries.removeValue(forKey: id), let sink = sinks[id] {
            Task { [weak self] in
                await sink.deliver(next)
                await self?.deliveryFinished(id: id)
            }
        } else {
            activeDeliveries.remove(id)
        }
    }
}
