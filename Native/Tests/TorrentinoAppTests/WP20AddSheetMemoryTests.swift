// Layer: Unit tests (WP-20 add-sheet memory).
// Role: validate isolated UserDefaults seeding and successful-add persistence.
// Must-not: start the engine, use XPC, or write production preferences.

import Foundation
import XCTest

final class WP20AddSheetMemoryTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "WP20AddSheetMemoryTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
        super.tearDown()
    }

    func testFirstRunSeedsCurrentDefaults() {
        let seeded = AddSheetPreferences(defaults: defaults).seed()

        XCTAssertNil(seeded.destinationURL)
        XCTAssertTrue(seeded.startPaused)
    }

    func testExistingDirectoryAndStoredToggleSeedOnPresentation() throws {
        let directory = try makeTemporaryDirectory()
        AddSheetPreferences(defaults: defaults).recordSuccessfulAdd(
            destinationURL: directory,
            startPaused: false
        )

        let seeded = AddSheetPreferences(defaults: defaults).seed()

        XCTAssertEqual(seeded.destinationURL?.path, directory.path)
        XCTAssertFalse(seeded.startPaused)
    }

    func testMissingDestinationIsIgnoredWhileStoredToggleSeeds() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WP20-missing-\(UUID().uuidString)", isDirectory: true)
        AddSheetPreferences(defaults: defaults).recordSuccessfulAdd(
            destinationURL: missingDirectory,
            startPaused: false
        )

        let seeded = AddSheetPreferences(defaults: defaults).seed()

        XCTAssertNil(seeded.destinationURL)
        XCTAssertFalse(seeded.startPaused)
    }

    func testExistingFileIsNotUsedAsDestinationFolder() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WP20-file-\(UUID().uuidString)")
        try Data("not-a-folder".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        AddSheetPreferences(defaults: defaults).recordSuccessfulAdd(
            destinationURL: fileURL,
            startPaused: true
        )

        let seeded = AddSheetPreferences(defaults: defaults).seed()

        XCTAssertNil(seeded.destinationURL)
        XCTAssertTrue(seeded.startPaused)
    }

    func testSuccessfulAddStoresDestinationAndStartPaused() throws {
        let directory = try makeTemporaryDirectory()
        let preferences = AddSheetPreferences(defaults: defaults)

        preferences.recordSuccessfulAdd(destinationURL: directory, startPaused: false)

        let seeded = preferences.seed()
        XCTAssertEqual(seeded.destinationURL?.path, directory.path)
        XCTAssertFalse(seeded.startPaused)
    }

    func testSuccessfulMagnetWithoutDestinationPreservesStoredDestination() throws {
        let directory = try makeTemporaryDirectory()
        let preferences = AddSheetPreferences(defaults: defaults)
        preferences.recordSuccessfulAdd(destinationURL: directory, startPaused: false)

        // Magnet/URL additions have no destination selection, but still save
        // the latest start-paused choice after a successful add.
        preferences.recordSuccessfulAdd(destinationURL: nil, startPaused: true)

        let seeded = preferences.seed()
        XCTAssertEqual(seeded.destinationURL?.path, directory.path)
        XCTAssertTrue(seeded.startPaused)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WP20-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
