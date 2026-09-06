// Layer: Unit tests (WP-23 Add pipeline: confirm-before-download).
// Role: validate that sheet commit requires destination and selection items mapping is preserved.
// Must-not: start native engine or use XPC.

import Foundation
import XCTest
import TorrentinoIPC

final class WP23AddPipelineAppTests: XCTestCase {

    private func makePreview(name: String = "test") -> AddTorrentPreview {
        AddTorrentPreview(
            inspection: AddSourceInspection(
                operationID: AddOperationID(),
                contentIdentity: nil,
                displayName: name,
                sizeBytes: 300,
                warnings: []
            ),
            files: [
                FileEntry(
                    relativePath: "dir/a.txt",
                    name: "a.txt",
                    sizeBytes: 100,
                    kind: .file,
                    selection: .normal
                ),
                FileEntry(
                    relativePath: "dir/b.bin",
                    name: "b.bin",
                    sizeBytes: 200,
                    kind: .file,
                    selection: .normal
                )
            ]
        )
    }

    func testWP23CommitRequiresDestination() {
        var presentation = AddTorrentInspectionPresentation()
        presentation.preview = makePreview()
        presentation.inspecting = false
        presentation.selectedPaths = ["dir/a.txt"]

        // 1. Without destination, sheetCanCommit MUST be false
        presentation.destinationPath = nil
        XCTAssertFalse(presentation.sheetCanCommit, "sheetCanCommit must be false when destinationPath is nil")
        XCTAssertFalse(presentation.canCommit(destinationPath: nil), "canCommit(destinationPath: nil) must be false")

        // 2. With destination, sheetCanCommit is true
        presentation.destinationPath = "/Volumes/Downloads"
        XCTAssertTrue(presentation.sheetCanCommit, "sheetCanCommit must be true when destinationPath is set")
        XCTAssertTrue(presentation.canCommit(destinationPath: "/Volumes/Downloads"), "canCommit(destinationPath:) must be true")

        // 3. While inspecting, sheetCanCommit is false even with destination
        presentation.inspecting = true
        XCTAssertFalse(presentation.sheetCanCommit, "sheetCanCommit must be false while inspecting")
        presentation.inspecting = false

        // 4. Without preview, sheetCanCommit is false even with destination
        presentation.preview = nil
        XCTAssertFalse(presentation.sheetCanCommit, "sheetCanCommit must be false without preview")
    }

    func testWP23CommitRequiresSelectedFiles() {
        var presentation = AddTorrentInspectionPresentation()
        presentation.preview = makePreview()
        presentation.destinationPath = "/Volumes/Downloads"
        presentation.inspecting = false

        // 1. Empty selection -> sheetCanCommit and canCommit(destinationPath:) must be false
        presentation.selectedPaths = []
        XCTAssertTrue(presentation.canCommit, "inspection-level canCommit remains true when preview is loaded")
        XCTAssertFalse(presentation.sheetCanCommit, "sheetCanCommit must be false when selection is empty")
        XCTAssertFalse(presentation.canCommit(destinationPath: "/Volumes/Downloads"), "canCommit(destinationPath:) must be false when selection is empty")

        // 2. Non-empty selection -> sheetCanCommit and canCommit(destinationPath:) are true
        presentation.selectedPaths = ["dir/a.txt"]
        XCTAssertTrue(presentation.canCommit, "inspection-level canCommit is true")
        XCTAssertTrue(presentation.sheetCanCommit, "sheetCanCommit must be true when destination and selection are set")
        XCTAssertTrue(presentation.canCommit(destinationPath: "/Volumes/Downloads"), "canCommit(destinationPath:) must be true when destination and selection are set")
        // 3. Empty files in metainfo (rare) -> canCommit is true even with empty selection
        let emptyPreview = AddTorrentPreview(
            inspection: AddSourceInspection(
                operationID: AddOperationID(),
                contentIdentity: nil,
                displayName: "empty",
                sizeBytes: 0,
                warnings: []
            ),
            files: []
        )
        presentation.preview = emptyPreview
        presentation.selectedPaths = []
        XCTAssertTrue(presentation.canCommit, "canCommit is true when preview has zero files")
        XCTAssertTrue(presentation.sheetCanCommit, "sheetCanCommit is true when preview has zero files and destination is set")
    }

    func testWP23PreviewApplyDoesNotPreselectAllFiles() {
        var inspectionState = LatestInspectionState<AddTorrentPreview>()
        let generation = inspectionState.begin()
        var presentation = AddTorrentInspectionPresentation()
        presentation.destinationPath = "/Volumes/Downloads"

        let preview = makePreview()
        let applied = AddTorrentInspectionResultApplication.apply(
            .success(preview),
            for: generation,
            to: &inspectionState,
            presentation: &presentation
        )

        XCTAssertTrue(applied)
        XCTAssertNotNil(presentation.preview)
        XCTAssertTrue(presentation.selectedPaths.isEmpty, "Inspection apply must NOT preselect all files; user opts in")
        XCTAssertFalse(presentation.sheetCanCommit, "sheetCanCommit must be false until user selects at least one file")
    }

    func testWP23SelectionItemsMappingUnchanged() {
        let preview = makePreview()
        let selected: Set<String> = ["dir/a.txt"]

        let items = AddTorrentInspectionPresentation.selectionItems(for: preview, selectedPaths: selected)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].relativePath, "dir/a.txt")
        XCTAssertEqual(items[0].priority, .normal)
        XCTAssertEqual(items[1].relativePath, "dir/b.bin")
        XCTAssertEqual(items[1].priority, .skip)
    }
}
