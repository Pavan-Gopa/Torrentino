import Foundation
import Sparkle
import XCTest
@MainActor
final class WP19UpdateTests: XCTestCase {
    func testFeedURLIsSingleHTTPSGitHubSource() throws {
        let url = try XCTUnwrap(UpdateFeed.appcastURL)
        XCTAssertEqual(url.absoluteString, UpdateFeed.appcastURLString)
        XCTAssertEqual(url.scheme?.lowercased(), "https")
        XCTAssertEqual(url.host?.lowercased(), "github.com")
        XCTAssertTrue(UpdateFeed.isPlaceholder)
    }

    func testMenuActionRoutesThroughInjectedCheckerWithoutSparkle() {
        let mock = MockUpdateChecker()
        UpdateMenuAction(checker: mock).perform()
        XCTAssertEqual(mock.checkCount, 1)
    }

    func testSparkleAutomaticAndProfileChecksAreDisabled() {
        XCTAssertFalse(SparkleUpdateChecker.automaticallyChecksForUpdates)
        XCTAssertFalse(SparkleUpdateChecker.automaticallyDownloadsUpdates)
        XCTAssertFalse(SparkleUpdateChecker.sendsSystemProfile)

        let bundle = Bundle(for: WP19UpdateTests.self)
        let userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: userDriver,
            delegate: nil
        )
        SparkleUpdateChecker.applyManualOnlyConfiguration(to: updater)

        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.automaticallyDownloadsUpdates)
        XCTAssertFalse(updater.sendsSystemProfile)
    }


    func testInfoPlistDisablesAutomaticChecksAndKeepsSignatureKeyPlaceholder() throws {
        let infoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TorrentinoApp/Info.plist")
        let info = try XCTUnwrap(NSDictionary(contentsOf: infoURL) as? [String: Any])

        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertNil(info["SUFeedURL"], "UpdateFeed is the sole runtime feed source")
        XCTAssertEqual(info["SUPublicEDKey"] as? String, "")
    }
}

@MainActor
private final class MockUpdateChecker: UpdateChecking {
    private(set) var checkCount = 0

    func checkForUpdates() {
        checkCount += 1
    }
}
