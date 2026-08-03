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
    /// Coalescing window; 0 disables batching (immediate flush).
    private let flushIntervalNanoseconds: UInt64
    private let log = Logger(subsystem: "com.torrentino.app.engine-agent", category: "transfer")

    init(flushIntervalMilliseconds: Double = 50) {
        self.flushIntervalNanoseconds = UInt64(max(0, flushIntervalMilliseconds) * 1_000_000)
    }

    func register(_ sink: Sink) {
        sinks[sink.id] = sink
    }

    func unregister(id: UUID) {
        sinks.removeValue(forKey: id)
    }

    func sinkCount() -> Int {
        sinks.count
    }

    /// Queues events for the next flush. `urgent` events (snapshotRequired,
    /// lifecycle) flush immediately.
    func publish(_ events: [EngineEventV1], urgent: Bool = false) {
        guard !events.isEmpty else { return }
        pending.append(contentsOf: events)
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
        let sinkValues = Array(sinks.values)
        for sink in sinkValues {
            Task {
                await sink.deliver(batch)
            }
        }
        log.debug("published \(batch.count) events to \(sinkValues.count) sink(s)")
    }
}
