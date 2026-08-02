// Layer: Test support (shared).
// Role: isolated temporary workspace for unit/integration tests.
// Must-not: touch production ~/Library/Application Support/com.torrentino.app/.
// Invariants: unique mktemp directory per profile; tearDown removes it.

import Foundation
import XCTest

/// Isolated temporary directory for tests. Never uses production App Support paths.
public final class TestProfile {
    public static let productionAppSupportMarker = "Application Support/com.torrentino.app"

    public let rootURL: URL
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        // mkdtemp requires a mutable C string with six trailing X characters.
        let template = fileManager.temporaryDirectory
            .appendingPathComponent("torrentino-test.XXXXXX", isDirectory: true)
            .path
        var buffer = Array(template.utf8CString)
        let result = buffer.withUnsafeMutableBufferPointer { ptr -> UnsafeMutablePointer<CChar>? in
            guard let base = ptr.baseAddress else { return nil }
            return mkdtemp(base)
        }
        guard let result else {
            throw NSError(
                domain: "TestProfile",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "mkdtemp failed for \(template)"]
            )
        }
        let path = String(cString: result)
        self.rootURL = URL(fileURLWithPath: path, isDirectory: true)

        // Hard guard: never land under production Application Support.
        let normalized = rootURL.path
        precondition(
            !normalized.contains(Self.productionAppSupportMarker),
            "TestProfile must not use production Application Support path: \(normalized)"
        )
    }

    /// Subdirectory under the isolated root (created if missing).
    public func subdirectory(_ name: String) throws -> URL {
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func tearDown() {
        try? fileManager.removeItem(at: rootURL)
    }
}

/// XCTestCase helpers that own a TestProfile for the test lifetime.
open class TestProfileCase: XCTestCase {
    public private(set) var profile: TestProfile!

    open override func setUpWithError() throws {
        try super.setUpWithError()
        profile = try TestProfile()
    }

    open override func tearDown() {
        profile?.tearDown()
        profile = nil
        super.tearDown()
    }
}
