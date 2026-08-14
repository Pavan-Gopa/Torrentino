// Layer: App policy.
// Role: deterministic release-curated public tracker composition for Creator.
// Must-not: perform I/O, networking, settings access, persistence, telemetry, or
// availability checks; this policy only builds the exact ordered topology.

import Foundation
import TorrentinoDomain

struct CreatorTrackerSharingPolicy {
    enum TierOrigin: String, Equatable, Sendable {
        case manual
        case recommendedPublic
    }

    struct EffectiveTier: Equatable, Sendable {
        let urls: [String]
        let origin: TierOrigin
    }

    struct EffectiveTopology: Equatable, Sendable {
        let tiers: [EffectiveTier]

        var trackerTiers: [[String]] {
            tiers.map(\.urls)
        }

        var origins: [TierOrigin] {
            tiers.map(\.origin)
        }
    }

    enum CompositionError: Error, Equatable, Sendable {
        case invalidRecommendedCatalog
        case capacityExceeded(actual: Int, maximum: Int)
    }

    /// Reviewed 2026-08-11 against each operator's published public-use page:
    /// - `udp://tracker.opentrackr.org:1337/announce` —
    ///   `https://opentrackr.org/`
    /// - `udp://open.stealth.si:80/announce` — `https://stealth.si/`
    /// - `udp://tracker.torrent.eu.org:451` — `https://torrent.eu.org/`
    /// Operator publication is the public-use basis only, not uptime,
    /// reachability, policy permanence, or SLA evidence. This catalog is
    /// static release data; no runtime checking is performed. Updates require
    /// an app release.
    static let recommendedPublicTrackerTiers: [[String]] = [
        ["udp://tracker.opentrackr.org:1337/announce"],
        ["udp://open.stealth.si:80/announce"],
        ["udp://tracker.torrent.eu.org:451"]
    ]

    static func validateRecommendedCatalog() throws {
        guard !recommendedPublicTrackerTiers.isEmpty else {
            throw CompositionError.invalidRecommendedCatalog
        }

        var totalURLCount = 0
        for tier in recommendedPublicTrackerTiers {
            guard !tier.isEmpty else {
                throw CompositionError.invalidRecommendedCatalog
            }
            totalURLCount += tier.count

            for url in tier {
                guard TrackerURLValidator.isSupported(url),
                      let components = URLComponents(string: url),
                      components.user == nil,
                      components.password == nil,
                      components.query == nil,
                      let host = components.host,
                      !isLocalOrPrivateLiteralHost(host) else {
                    throw CompositionError.invalidRecommendedCatalog
                }
            }
        }

        guard totalURLCount > 0, totalURLCount <= TransferLimits.maxTrackers else {
            throw CompositionError.invalidRecommendedCatalog
        }
    }

    static func effectiveTopology(
        manualTiers: [[String]],
        isPrivate: Bool,
        includeRecommendedPublicTrackers: Bool
    ) throws -> EffectiveTopology {
        try validateRecommendedCatalog()

        let includesRecommendations = !isPrivate && includeRecommendedPublicTrackers
        let recommendedTiers = includesRecommendations
            ? recommendedPublicTrackerTiers
            : []
        let totalURLCount = manualTiers.reduce(into: 0) { count, tier in
            count += tier.count
        } + recommendedTiers.reduce(into: 0) { count, tier in
            count += tier.count
        }
        guard totalURLCount <= TransferLimits.maxTrackers else {
            throw CompositionError.capacityExceeded(
                actual: totalURLCount,
                maximum: TransferLimits.maxTrackers
            )
        }

        var tiers: [EffectiveTier] = []
        tiers.reserveCapacity(manualTiers.count + recommendedTiers.count)
        tiers.append(contentsOf: manualTiers.map {
            EffectiveTier(urls: $0, origin: .manual)
        })
        tiers.append(contentsOf: recommendedTiers.map {
            EffectiveTier(urls: $0, origin: .recommendedPublic)
        })
        return EffectiveTopology(tiers: tiers)
    }

    private static func isLocalOrPrivateLiteralHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if normalized == "localhost"
            || normalized == "localhost."
            || normalized == "127.0.0.1"
            || normalized == "0.0.0.0"
            || normalized == "::1"
            || normalized.hasSuffix(".local")
            || normalized.hasPrefix("fe80:")
            || normalized.hasPrefix("fc")
            || normalized.hasPrefix("fd") {
            return true
        }

        let octets = normalized.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (169, 254), (192, 168), (172, 16...31):
            return true
        default:
            return false
        }
    }
}
