// swift-tools-version: 6.0
//
// TorrentinoHashing — WP-12 research module (RESEARCH TRACK).
//
// Role: isolated experimental Metal hashing backend plus an independent CPU
// reference. NOT linked into any product target: the production hashing path
// (TorrentinoDomain/CPUHasher) is untouched and remains the default. This
// package exists only to produce the measured evidence for the ADOPT_METAL /
// REJECT_METAL decision (plan §12).
//
// Invariants:
//   * Swift 6 language mode, warnings as errors (SPM-only, not in Xcode).
//   * No MainActor work: hashing is off-main-thread by construction.
//   * GPU execution is gated behind the TORRENTINO_METAL_EXPERIMENTAL flag;
//     without it the package behaves as a CPU reference implementation.
//   * All test corpora live in mktemp profiles; production Application
//     Support is never touched.

import PackageDescription

let package = Package(
    name: "TorrentinoHashing",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TorrentinoHashing", targets: ["TorrentinoHashing"]),
        .executable(name: "TorrentinoHashingBench", targets: ["TorrentinoHashingBench"])
    ],
    targets: [
        .target(
            name: "TorrentinoHashing",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-warnings-as-errors"])
            ]
        ),
        .testTarget(
            name: "TorrentinoHashingTests",
            dependencies: ["TorrentinoHashing"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-warnings-as-errors"])
            ]
        ),
        .executableTarget(
            name: "TorrentinoHashingBench",
            dependencies: ["TorrentinoHashing"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-warnings-as-errors"])
            ]
        )
    ]
)
