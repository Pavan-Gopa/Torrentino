// Layer: WP-14 measurement-only XCTest.
// Role: Release-mode, in-process performance campaign over isolated state.
// Must-not: launch the live agent/app, touch production Application Support,
//           or use any non-loopback network resource.

import Darwin
import Foundation
import os
import XCTest
import TorrentinoDomain
import TorrentinoIPC
@testable import TorrentinoEngineAgent

final class WP14PerformanceMeasurements: TestProfileCase {
    private struct MetricRow {
        let name: String
        let value: Double
        let unit: String
        let target: String
        let result: String
        let basis: String
    }

    private struct ResourceSample {
        let footprintMiB: Double
        let fileDescriptors: Int
        let threads: Int
    }

    func testWP14InProcessPerformanceCampaign() async throws {
        var metrics: [MetricRow] = []
        try await Task.sleep(nanoseconds: 200_000_000)
        let baseline = try resourceSample()

        let dataDirectory = try profile.subdirectory("WP14Performance")
        var store: PersistenceStore? = PersistenceStore(dataDirectory: dataDirectory)
        _ = try await store!.open()

        for index in 0..<100 {
            let id = UUID().uuidString
            let metainfo = MetainfoBuilder.singleFile(
                name: "row-\(index).bin",
                size: Int64(1_048_576 + index),
                pieceLength: 1_048_576,
                piecesCount: 1
            )
            try await store!.addTorrent(StoredTorrent(
                id: id,
                infoHashV1: String(format: "%040x", index + 1),
                infoHashV2: nil,
                name: "row-\(index)",
                state: "paused",
                addedAt: Int64(index),
                quarantined: false
            ))
            _ = try await store!.storeMetainfo(torrentID: id, data: metainfo)
        }

        var bus: TransferEventBus? = TransferEventBus(flushIntervalMilliseconds: 0, maxPendingEvents: 256)
        let engine = StubTransferEngine()
        var coordinator: TransferCoordinator? = TransferCoordinator(
            engine: engine,
            persistence: store!,
            eventBus: bus!,
            agentVersion: "wp14-measurement",
            defaultSaveLocation: PersistedLocation(path: dataDirectory.path)
        )

        let restoreStart = DispatchTime.now().uptimeNanoseconds
        let restoreSummary = await coordinator!.restoreFromPersistence()
        let restoreMilliseconds = elapsedMilliseconds(since: restoreStart)
        metrics.append(row(
            "registry_restore_100",
            restoreMilliseconds,
            "ms",
            "<=5000",
            restoreMilliseconds <= 5_000 && restoreSummary.rebuilt == 100,
            "authoritative isolated SQLite restore"
        ))

        var snapshotDurations: [Double] = []
        var authoritativeSnapshot = try await fetchSnapshot(coordinator!)
        for iteration in 0..<60 {
            let start = DispatchTime.now().uptimeNanoseconds
            authoritativeSnapshot = try await fetchSnapshot(coordinator!)
            let duration = elapsedMilliseconds(since: start)
            if iteration >= 10 { snapshotDurations.append(duration) }
        }
        let snapshotP95 = percentile(snapshotDurations, 0.95)
        metrics.append(row(
            "registry_snapshot_100_p95",
            snapshotP95,
            "ms",
            "<=5000",
            snapshotP95 <= 5_000 && authoritativeSnapshot.torrents.count == 100,
            "50 measured in-process command-lane snapshots after 10 warmups"
        ))

        let idleHundred = try resourceSample()
        metrics.append(row(
            "phys_footprint_100_idle",
            idleHundred.footprintMiB,
            "MiB",
            "<=350",
            idleHundred.footprintMiB <= 350,
            "mach TASK_VM_INFO.phys_footprint; XCTest process includes framework overhead"
        ))

        let firstTen = Array(authoritativeSnapshot.torrents.prefix(10).map(\.id))
        for recordID in firstTen {
            try await store!.updateTorrentState(
                torrentID: recordID.rawValue.uuidString,
                state: DesiredTorrentState.running.rawValue
            )
        }
        // Reconstruct the app-engine state exactly as a restart would. Ten
        // running records enter authoritative checking state immediately; the
        // balanced admission budget then maps four at a time to the stub engine.
        coordinator = nil
        bus = TransferEventBus(flushIntervalMilliseconds: 0, maxPendingEvents: 256)
        coordinator = TransferCoordinator(
            engine: engine,
            persistence: store!,
            eventBus: bus!,
            agentVersion: "wp14-measurement-active",
            defaultSaveLocation: PersistedLocation(path: dataDirectory.path)
        )
        let activeRestore = await coordinator!.restoreFromPersistence()
        let activeStats = await coordinator!.aggregateStats()
        let activeTen = try resourceSample()
        metrics.append(row(
            "phys_footprint_10_active_of_100",
            activeTen.footprintMiB,
            "MiB",
            "<=750",
            activeTen.footprintMiB <= 750
                && activeRestore.rebuilt == 100
                && activeStats.activeCount == 10,
            "100 persisted records; 10 authoritative checking transfers in one coordinator"
        ))

        // Pause is admitted through the real coordinator even when the record
        // has not yet consumed a download slot. It yields one deterministic
        // engine-mapped record for recheck and mutation-lane timing without
        // weakening the ten-active footprint workload above.
        let liveRecordID = firstTen[0]
        _ = try await commandSuccess(.pause(PauseRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            recordID: liveRecordID
        )), coordinator: coordinator!)

        var recheckDurations: [Double] = []
        for _ in 0..<50 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await commandSuccess(.requestRecheck(RequestRecheckRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: liveRecordID
            )), coordinator: coordinator!)
            recheckDurations.append(elapsedMilliseconds(since: start))
        }
        let recheckDispatchP95 = percentile(recheckDurations, 0.95)
        metrics.append(row(
            "recheck_dispatch_p95",
            recheckDispatchP95,
            "ms",
            "<=200",
            recheckDispatchP95 <= 200,
            "50 in-process mutation acknowledgements; completion hashing is not represented by StubTransferEngine"
        ))

        // Multi-GiB sparse creator input: scan the real production source path,
        // start real CPU hashing, then request cancellation after hashing is in
        // flight. Runtime is capped without allocating or writing 2 GiB.
        let creatorDirectory = try profile.subdirectory("WP14LargeCreator")
        let sparseURL = creatorDirectory.appendingPathComponent("sparse-2g.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparseURL.path, contents: nil))
        let sparseHandle = try FileHandle(forWritingTo: sparseURL)
        try sparseHandle.truncate(atOffset: 2 * 1_024 * 1_024 * 1_024)
        try sparseHandle.close()

        let scanStart = DispatchTime.now().uptimeNanoseconds
        let scan = try SourceScanner.scan(sourcePath: creatorDirectory.path, manualPieceSizeKiB: 16_384)
        let scanMilliseconds = elapsedMilliseconds(since: scanStart)
        metrics.append(row(
            "large_creator_sparse_scan",
            scanMilliseconds,
            "ms",
            "observational",
            scan.totalSizeBytes == 2 * 1_024 * 1_024 * 1_024,
            "production SourceScanner over a 2 GiB sparse file"
        ))

        let cancellationRequested = OSAllocatedUnfairLock(initialState: false)
        let hasherTask = Task {
            try await CPUHasher().hash(
                scannedFiles: scan.files,
                pieceSizeBytes: scan.pieceSizeBytes,
                format: .hybrid,
                cancelCheck: {
                    if cancellationRequested.withLock({ $0 }) {
                        throw HasherError.cancelled
                    }
                },
                onProgress: { _, _, _, _ in }
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let cancellationStart = DispatchTime.now().uptimeNanoseconds
        cancellationRequested.withLock { $0 = true }
        var creatorCancelled = false
        do {
            _ = try await hasherTask.value
        } catch let error as HasherError {
            creatorCancelled = error == .cancelled
        }
        let cancellationMilliseconds = elapsedMilliseconds(since: cancellationStart)
        metrics.append(row(
            "large_creator_cancel_reaction",
            cancellationMilliseconds,
            "ms",
            "<=1000",
            creatorCancelled && cancellationMilliseconds <= 1_000,
            "CPUHasher 64 KiB cancellation checkpoints on 2 GiB sparse input"
        ))

        // Slow-consumer overload. Mutations happen while the consumer owns its
        // first delivery, followed by one 100k mixed-event burst and a health
        // update. A recovery marker must not be replaced before it is observed.
        let slowCollector = SlowEventCollector(delayNanoseconds: 2_000_000_000)
        let slowSinkID = UUID()
        await bus!.register(TransferEventBus.Sink(id: slowSinkID) { events in
            await slowCollector.receive(events)
        })
        await bus!.publish([
            .engineHealthChanged(EngineHealthChangedEvent(healthy: true, reason: nil, engineRevision: 0))
        ], urgent: true)
        try await Task.sleep(nanoseconds: 20_000_000)

        var mutationDurations: [Double] = []
        for iteration in 0..<50 {
            let start = DispatchTime.now().uptimeNanoseconds
            if iteration.isMultiple(of: 2) {
                _ = try await commandSuccess(.pause(PauseRequest(
                    requestID: RequestID(),
                    idempotencyKey: IdempotencyKey(),
                    recordID: liveRecordID
                )), coordinator: coordinator!)
            } else {
                _ = try await commandSuccess(.resume(ResumeRequest(
                    requestID: RequestID(),
                    idempotencyKey: IdempotencyKey(),
                    recordID: liveRecordID
                )), coordinator: coordinator!)
            }
            mutationDurations.append(elapsedMilliseconds(since: start))
        }
        let mutationP95 = percentile(mutationDurations, 0.95)
        metrics.append(row(
            "mutation_ack_during_slow_consumer_p95",
            mutationP95,
            "ms",
            "<=200",
            mutationP95 <= 200,
            "50 in-process pause/resume acknowledgements while event delivery is stalled"
        ))

        let operationID = OperationID()
        let timestamp = Date()
        var storm: [EngineEventV1]? = []
        storm!.reserveCapacity(100_000)
        for revision in 1...100_000 {
            switch revision % 3 {
            case 0:
                storm!.append(.engineHealthChanged(EngineHealthChangedEvent(
                    healthy: true,
                    reason: nil,
                    engineRevision: UInt64(revision)
                )))
            case 1:
                storm!.append(.operationProgress(OperationProgressEvent(
                    operationID: operationID,
                    phase: .running,
                    fraction: Double(revision % 1000) / 1000,
                    timestamp: timestamp
                )))
            default:
                storm!.append(.torrentDelta(TorrentDeltaEvent(delta: TorrentDelta(
                    added: [],
                    updated: [],
                    removed: [],
                    engineRevision: UInt64(revision)
                ))))
            }
        }
        let burstStart = DispatchTime.now().uptimeNanoseconds
        await bus!.publish(storm!, urgent: true)
        let burstMilliseconds = elapsedMilliseconds(since: burstStart)
        // This tail update exercises the one-queued-batch replacement path.
        await bus!.publish([
            .engineHealthChanged(EngineHealthChangedEvent(
                healthy: true,
                reason: "tail",
                engineRevision: 100_001
            ))
        ], urgent: true)
        let queueDepth = await bus!.pendingEventCount()
        let overflowed = await bus!.overflowed()
        metrics.append(row(
            "event_burst_100k_enqueue",
            burstMilliseconds,
            "ms",
            "observational",
            overflowed,
            "100000 mixed torrent/progress/health events in one bounded publish"
        ))
        metrics.append(row(
            "event_queue_depth_after_100k",
            Double(queueDepth),
            "events",
            "<=256",
            queueDepth <= 256,
            "TransferEventBus pending plus one queued slow-consumer batch"
        ))

        let healthLane = AgentHealthLane()
        var healthDurations: [Double] = []
        for counter in 0..<100 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = healthLane.snapshot(counter: Int64(counter), counterFormat: "wp14")
            healthDurations.append(elapsedMilliseconds(since: start))
        }
        let healthP95 = percentile(healthDurations, 0.95)
        metrics.append(row(
            "health_lane_overload_p95",
            healthP95,
            "ms",
            "<=200",
            healthP95 <= 200,
            "100 lock-backed health snapshots with telemetry queue occupied"
        ))

        // First delivery completes at ~2s; the replacement delivery completes
        // at ~4s. Inspect only after both deterministic deliveries settle.
        try await Task.sleep(nanoseconds: 4_500_000_000)
        let delivered = await slowCollector.allEvents()
        let sawRecoveryMarker = delivered.contains { event in
            if case .snapshotRequired(let payload) = event {
                return payload.reason == .droppedDelta
            }
            return false
        }
        metrics.append(row(
            "slow_consumer_overflow_resync_marker",
            sawRecoveryMarker ? 1 : 0,
            "boolean",
            "1",
            sawRecoveryMarker,
            "overflow recovery marker must survive queued-batch replacement"
        ))

        // Disconnect the slow sink and exercise the transport-seam recovery
        // invariant without launching the Human's live XPC identity: reconnect
        // starts from an unknown revision and fetches the authoritative snapshot.
        await bus!.unregister(id: slowSinkID)
        let resyncedSnapshot = try await fetchSnapshot(coordinator!)
        let reconnectNeedsSnapshot = SnapshotReconciliation.needsFullSnapshot(
            afterRevision: nil,
            latestEngineRevision: resyncedSnapshot.engineRevision
        )
        let resyncPassed = reconnectNeedsSnapshot
            && resyncedSnapshot.torrents.count == 100
            && resyncedSnapshot.torrents.first(where: { $0.id == liveRecordID })?.desiredState == .running
        metrics.append(row(
            "disconnect_burst_resync_seam",
            resyncPassed ? 1 : 0,
            "boolean",
            "1",
            resyncPassed,
            "in-process sink disconnect plus unknown-revision authoritative snapshot"
        ))

        let duringLoad = try resourceSample()
        storm = nil
        coordinator = nil
        bus = nil
        try await store!.close(clean: true)
        store = nil
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let quiescent = try resourceSample()
        let footprintReturned = quiescent.footprintMiB <= 350
            && quiescent.footprintMiB <= baseline.footprintMiB + 64
            && quiescent.footprintMiB <= duringLoad.footprintMiB
        let fdReturned = quiescent.fileDescriptors <= baseline.fileDescriptors + 4
            && quiescent.fileDescriptors <= duringLoad.fileDescriptors
        let threadsReturned = quiescent.threads <= baseline.threads + 8
            && quiescent.threads <= duringLoad.threads
        metrics.append(row(
            "phys_footprint_quiescent_after",
            quiescent.footprintMiB,
            "MiB",
            "<=350 and <=baseline+64",
            footprintReturned,
            "one second after isolated store close and workload release"
        ))
        metrics.append(row(
            "fd_count_baseline",
            Double(baseline.fileDescriptors),
            "count",
            "observational",
            true,
            "proc_pidinfo PROC_PIDLISTFDS"
        ))
        metrics.append(row(
            "fd_count_during",
            Double(duringLoad.fileDescriptors),
            "count",
            "observational",
            true,
            "after active records and overload"
        ))
        metrics.append(row(
            "fd_count_quiescent_after",
            Double(quiescent.fileDescriptors),
            "count",
            "<=baseline+4 and <=during",
            fdReturned,
            "predefined small quiescence tolerance"
        ))
        metrics.append(row(
            "thread_count_baseline",
            Double(baseline.threads),
            "count",
            "observational",
            true,
            "proc_pidinfo PROC_PIDTASKINFO"
        ))
        metrics.append(row(
            "thread_count_during",
            Double(duringLoad.threads),
            "count",
            "observational",
            true,
            "after active records and overload"
        ))
        metrics.append(row(
            "thread_count_quiescent_after",
            Double(quiescent.threads),
            "count",
            "<=baseline+8 and <=during",
            threadsReturned,
            "predefined small quiescence tolerance"
        ))

        let idleCPU = await idleCPUPercentages(sampleCount: 30, intervalNanoseconds: 100_000_000)
        let idleCPUMedian = percentile(idleCPU, 0.50)
        let idleCPUP95 = percentile(idleCPU, 0.95)
        metrics.append(row(
            "idle_cpu_inprocess_median",
            idleCPUMedian,
            "percent_of_one_core",
            "<=2",
            idleCPUMedian <= 2,
            "30 x 100ms quiescent XCTest-process samples"
        ))
        metrics.append(row(
            "idle_cpu_inprocess_p95",
            idleCPUP95,
            "percent_of_one_core",
            "<=5",
            idleCPUP95 <= 5,
            "30 x 100ms quiescent XCTest-process samples"
        ))

        try writeMetrics(metrics)

        XCTAssertEqual(restoreSummary.rebuilt, 100)
        XCTAssertEqual(authoritativeSnapshot.torrents.count, 100)
        XCTAssertEqual(activeStats.activeCount, 10)
        XCTAssertLessThanOrEqual(snapshotP95, 5_000)
        XCTAssertLessThanOrEqual(idleHundred.footprintMiB, 350)
        XCTAssertLessThanOrEqual(activeTen.footprintMiB, 750)
        XCTAssertTrue(creatorCancelled)
        XCTAssertLessThanOrEqual(cancellationMilliseconds, 1_000)
        XCTAssertLessThanOrEqual(mutationP95, 200)
        XCTAssertLessThanOrEqual(healthP95, 200)
        XCTAssertLessThanOrEqual(queueDepth, 256)
        XCTAssertTrue(overflowed)
        XCTAssertTrue(
            sawRecoveryMarker,
            "overflow recovery marker was replaced for a slow consumer; lost deltas can remain falsely authoritative"
        )
        XCTAssertTrue(resyncPassed)
        XCTAssertTrue(footprintReturned)
        XCTAssertTrue(fdReturned)
        XCTAssertTrue(threadsReturned)
        XCTAssertLessThanOrEqual(idleCPUMedian, 2)
        XCTAssertLessThanOrEqual(idleCPUP95, 5)
    }

    private func row(
        _ name: String,
        _ value: Double,
        _ unit: String,
        _ target: String,
        _ passed: Bool,
        _ basis: String
    ) -> MetricRow {
        MetricRow(name: name, value: value, unit: unit, target: target, result: passed ? "pass" : "fail", basis: basis)
    }

    private func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func percentile(_ values: [Double], _ quantile: Double) -> Double {
        let sorted = values.sorted()
        let rank = max(0, min(sorted.count - 1, Int(ceil(quantile * Double(sorted.count))) - 1))
        return sorted[rank]
    }

    private func encode(_ command: EngineCommandV1) throws -> Data {
        try JSONEncoder().encode(IPCEnvelope.request(command))
    }

    private func commandSuccess(
        _ command: EngineCommandV1,
        coordinator: TransferCoordinator
    ) async throws -> SuccessPayload {
        let reply = await coordinator.processCommand(try encode(command))
        let envelope = try JSONDecoder().decode(IPCEnvelope.self, from: reply)
        guard let result = envelope.result else {
            throw NSError(domain: "WP14Measurement", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing result"])
        }
        switch result {
        case .success(let payload): return payload
        case .failure(let fault): throw fault
        }
    }

    private func fetchSnapshot(_ coordinator: TransferCoordinator) async throws -> EngineSnapshot {
        let payload = try await commandSuccess(.fetchSnapshot(FetchSnapshotRequest(
            requestID: RequestID(),
            afterRevision: nil
        )), coordinator: coordinator)
        guard case .snapshot(let snapshot) = payload else {
            throw NSError(domain: "WP14Measurement", code: 2, userInfo: [NSLocalizedDescriptionKey: "unexpected snapshot payload"])
        }
        return snapshot
    }

    private func resourceSample() throws -> ResourceSample {
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let vmResult = withUnsafeMutablePointer(to: &vmInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &vmCount)
            }
        }
        guard vmResult == KERN_SUCCESS else {
            throw NSError(domain: "WP14Measurement", code: Int(vmResult), userInfo: [NSLocalizedDescriptionKey: "TASK_VM_INFO failed"])
        }

        var task = proc_taskinfo()
        let taskSize = MemoryLayout<proc_taskinfo>.size
        let taskResult = withUnsafeMutablePointer(to: &task) { pointer in
            proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, pointer, Int32(taskSize))
        }
        guard taskResult == Int32(taskSize) else {
            throw NSError(domain: "WP14Measurement", code: 3, userInfo: [NSLocalizedDescriptionKey: "PROC_PIDTASKINFO failed"])
        }

        let descriptorBytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard descriptorBytes >= 0 else {
            throw NSError(domain: "WP14Measurement", code: 4, userInfo: [NSLocalizedDescriptionKey: "PROC_PIDLISTFDS failed"])
        }
        return ResourceSample(
            footprintMiB: Double(vmInfo.phys_footprint) / 1_048_576,
            fileDescriptors: Int(descriptorBytes) / MemoryLayout<proc_fdinfo>.stride,
            threads: Int(task.pti_threadnum)
        )
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private func idleCPUPercentages(sampleCount: Int, intervalNanoseconds: UInt64) async -> [Double] {
        var samples: [Double] = []
        samples.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            let cpuStart = processCPUSeconds()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
            let cpuEnd = processCPUSeconds()
            let wallSeconds = Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000_000
            samples.append(max(0, (cpuEnd - cpuStart) / wallSeconds * 100))
        }
        return samples
    }

    private func csvField(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func writeMetrics(_ metrics: [MetricRow]) throws {
        let environment = ProcessInfo.processInfo.environment
        let outputDirectory: URL
        let runID: String
        if let directory = environment["WP14_MEASUREMENTS_DIR"],
           let environmentRunID = environment["WP14_RUN_ID"] {
            outputDirectory = URL(fileURLWithPath: directory, isDirectory: true)
            runID = environmentRunID
        } else {
            outputDirectory = Self.repositoryRoot
                .appendingPathComponent("Measurements", isDirectory: true)
                .appendingPathComponent("wp14", isDirectory: true)
            runID = "latest"
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let output = outputDirectory.appendingPathComponent("inprocess-\(runID).csv")
        var lines = ["metric,value,unit,target,result,basis"]
        lines.append(contentsOf: metrics.map {
            [csvField($0.name), String(format: "%.6f", $0.value), csvField($0.unit), csvField($0.target), csvField($0.result), csvField($0.basis)].joined(separator: ",")
        })
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: output, options: .atomic)
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private actor SlowEventCollector {
    private let delayNanoseconds: UInt64
    private var events: [EngineEventV1] = []

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func receive(_ batch: [EngineEventV1]) async {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        events.append(contentsOf: batch)
    }

    func allEvents() -> [EngineEventV1] {
        events
    }
}
