// Layer: UI test fixture generation.
// Role: deterministic fallback rows used for degraded UI behavior and
// performance checks. It has no client or persistence dependencies.

import Foundation
import TorrentinoIPC

enum FixtureLibrary {
    static func snapshot(count: Int = 100) -> [TorrentSnapshot] {
        guard count > 0 else { return [] }
        return (1...count).map { index in
            let cycle = index % 8
            let activity: TorrentActivity
            let desired: DesiredTorrentState
            let fraction: Double
            switch cycle {
            case 0: activity = .downloading; desired = .running; fraction = 0.05 + 0.9 * Double(index) / Double(count)
            case 1: activity = .seeding; desired = .running; fraction = 1.0
            case 2: activity = .checking; desired = .running; fraction = 0.5
            case 3: activity = .idle; desired = .paused; fraction = Double(index % 90) / 100.0
            case 4: activity = .downloading; desired = .running; fraction = Double(index % 70) / 100.0
            case 5: activity = .fetchingMetadata; desired = .running; fraction = 0.0
            case 6: activity = .queued; desired = .running; fraction = 0.0
            default: activity = .seeding; desired = .running; fraction = 1.0
            }
            let totalBytes = Int64(1_500_000_000 + index * 37_000_000)
            let downloaded = Int64(Double(totalBytes) * fraction)
            let recordID = TorrentRecordID(rawValue: UUID())
            let name = String(format: "Demo Archive %03d - %@", index, Self.suffixes[index % Self.suffixes.count])
            return TorrentSnapshot(
                id: recordID,
                contentIdentity: ContentIdentity(infoHashV1: Data([UInt8(index & 0xFF)]), infoHashV2: nil),
                displayName: name,
                desiredState: desired,
                activity: activity,
                health: .healthy,
                progress: TransferProgress(
                    fraction: fraction,
                    totalBytes: totalBytes,
                    downloadedBytes: downloaded,
                    uploadedBytes: activity == .seeding ? downloaded / 2 : downloaded / 10
                ),
                rates: TransferRates(
                    downloadBytesPerSec: activity == .downloading ? Int64(400_000 + index * 7_000) : 0,
                    uploadBytesPerSec: activity == .seeding ? Int64(120_000 + index * 3_000) : 0
                ),
                peers: PeerSummary(
                    connected: activity == .downloading || activity == .seeding ? 4 + index % 40 : 0,
                    halfOpen: activity == .downloading ? index % 12 : 0,
                    total: activity == .downloading || activity == .seeding ? 20 + index % 200 : 0
                ),
                saveLocation: PersistedLocation(path: "/Users/Shared/Demo"),
                revision: UInt64(index)
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static let suffixes = [
        "Source", "Assets", "Backup", "Pack", "Bundle", "Collection",
        "Dataset", "Release", "Build", "Episode",
    ]
}
