import Foundation

extension UserDefaults {
    /// The defaults the lyric, shelf and privacy stores keep their state in
    /// when none is handed in: the standard defaults in the app, and in a test
    /// process a suite of that process's own, removed when it exits.
    ///
    /// A test process's standard defaults are not scratch space. They are the
    /// `com.apple.dt.xctest.tool` domain, one file every run of every test
    /// bundle on the Mac reads and writes, and what lands there stays. Every
    /// `NotchStores()` a test built wrote `lyrics.offsetSignVersion` into it,
    /// and `privacyKnownSections` with every `PrivacyMode()`; the rigs that
    /// zero the Lyric Delay wrote `lyrics.userOffset`, and the shelf's lists
    /// stayed under `shelf.urls*`. The next run's stores read them back as a
    /// listener's settings, and a gate run on the owner's Mac left the domain
    /// changed (2026-11-05, found when the domain had to be set aside before
    /// every gate). The tests that read one of these keys back read it here.
    static let stores: UserDefaults = {
        guard PlayerBridge.isRunningTests, let suite = UserDefaults(suiteName: TestStoreSuite.name) else {
            return .standard
        }
        atexit { TestStoreSuite.remove() }
        return suite
    }()
}

/// The suite a test process's stores write to (`UserDefaults.stores`).
enum TestStoreSuite {
    static let name = "com.ctimothe.isla.tests.\(UUID().uuidString)"

    /// Empties the suite and deletes its file. Removing the domain alone
    /// leaves an empty plist behind in `~/Library/Preferences`, one per
    /// suite, and the probe suites the tests make alone had left 77,775 of
    /// them there by 2026-11-05.
    static func remove() {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        UserDefaults.removeSuiteFile(named: name)
    }
}

extension UserDefaults {
    /// Deletes a removed suite's empty file from `~/Library/Preferences`. Only
    /// after `removePersistentDomain(forName:)`, so the preferences daemon has
    /// nothing left to write back.
    static func removeSuiteFile(named name: String) {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: file)
    }
}
