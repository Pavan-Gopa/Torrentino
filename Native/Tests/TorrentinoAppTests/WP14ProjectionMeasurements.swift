// Layer: WP-14 measurement-only XCTest.
// Role: times the production 500-row table and row-projection path in Release.
// Must-not: touch XPC, production state, or external network.

import Foundation
import XCTest
import TorrentinoIPC

final class WP14ProjectionMeasurements: XCTestCase {
    func testFiveHundredRowProjectionP50P95() throws {
        let rows = FixtureLibrary.snapshot(count: 500)
        XCTAssertEqual(rows.count, 500)

        // Warm Foundation's localized comparison and formatter caches before
        // the measured repetitions. The SLO is steady table projection, not
        // one-time framework initialization.
        _ = projectAndFormat(rows)

        var durationsMilliseconds: [Double] = []
        durationsMilliseconds.reserveCapacity(200)
        var projectedCount = 0
        for iteration in 0..<200 {
            let start = DispatchTime.now().uptimeNanoseconds
            projectedCount = projectAndFormat(
                iteration.isMultiple(of: 2) ? rows : Array(rows.reversed())
            )
            let end = DispatchTime.now().uptimeNanoseconds
            durationsMilliseconds.append(Double(end - start) / 1_000_000)
        }

        let p50 = percentile(durationsMilliseconds, 0.50)
        let p95 = percentile(durationsMilliseconds, 0.95)
        let targetMilliseconds = 250.0
        let passed = p95 <= targetMilliseconds && projectedCount == 500
        try writeCSV(
            p50: p50,
            p95: p95,
            iterations: durationsMilliseconds.count,
            projectedCount: projectedCount,
            passed: passed
        )

        XCTAssertEqual(projectedCount, 500, "the measured path must project every authoritative row")
        XCTAssertLessThanOrEqual(
            p95,
            targetMilliseconds,
            "500-row production projection must not create a >250 ms main-thread stall"
        )
    }

    private func projectAndFormat(_ rows: [TorrentSnapshot]) -> Int {
        let projected = TorrentListProjection.project(
            rows,
            query: "",
            filter: .all,
            sortOrder: [KeyPathComparator(\.displayName)]
        )
        // TorrentListView constructs these values for visible rows. Construct
        // all 500 here to bound the complete presentation projection.
        let rowModels = projected.map(TorrentListRowProjection.init(torrent:))
        return rowModels.count
    }

    private func percentile(_ values: [Double], _ quantile: Double) -> Double {
        let sorted = values.sorted()
        let rank = max(0, min(sorted.count - 1, Int(ceil(quantile * Double(sorted.count))) - 1))
        return sorted[rank]
    }

    private func writeCSV(
        p50: Double,
        p95: Double,
        iterations: Int,
        projectedCount: Int,
        passed: Bool
    ) throws {
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
        let output = outputDirectory.appendingPathComponent("projection-\(runID).csv")
        let csv = "metric,value,unit,target,result,basis\n"
            + "ui_projection_500_p50,\(p50),ms,observational,pass,200 Release repetitions\n"
            + "ui_projection_500_p95,\(p95),ms,<=250,\(passed ? "pass" : "fail"),§11.3 no main-thread stall >250 ms\n"
            + "ui_projection_rows,\(projectedCount),rows,500,\(projectedCount == 500 ? "pass" : "fail"),TorrentListProjection plus TorrentListRowProjection\n"
        try Data(csv.utf8).write(to: output, options: .atomic)
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
