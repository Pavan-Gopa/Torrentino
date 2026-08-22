// Layer: UI preference persistence (WP-20 add-sheet memory).
// Role: remembers the add sheet's last destination and start-paused choice.
// Must-not: alter engine settings or create a stale destination directory.

import Foundation

struct AddSheetPreferences {
    private enum Key {
        static let destinationPath = "torrentino.addSheet.destinationPath"
        static let startPaused = "torrentino.addSheet.startPaused"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func seed() -> (destinationURL: URL?, startPaused: Bool) {
        let startPaused = defaults.object(forKey: Key.startPaused) == nil
            ? true
            : defaults.bool(forKey: Key.startPaused)

        guard let path = defaults.string(forKey: Key.destinationPath), !path.isEmpty else {
            return (nil, startPaused)
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return (nil, startPaused)
        }

        return (URL(fileURLWithPath: path, isDirectory: true), startPaused)
    }

    func recordSuccessfulAdd(destinationURL: URL?, startPaused: Bool) {
        if let destinationURL {
            defaults.set(destinationURL.path, forKey: Key.destinationPath)
        }
        defaults.set(startPaused, forKey: Key.startPaused)
    }
}
