import XCTest
@testable import IslaKit

/// Screen recordings the system saved to disk, picked up without any copy
/// step: the shelf scans Screenshot.app's save location when it opens and
/// imports what finished since the feature first ran.
@MainActor
final class RecordingPickupTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ name: String, in folder: URL, modified daysAgo: Double = 0) throws {
        let url = folder.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        if daysAgo > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-daysAgo * 86400)],
                ofItemAtPath: url.path
            )
        }
    }

    func testFreshRecordingIsOfferedOldestFirst() throws {
        let dir = try folder()
        try write("Screen Recording 2026-09-11 at 10.00.01.mov", in: dir)
        try write("Screen Recording 2026-09-11 at 10.00.02.mov", in: dir)

        let result = RecordingPickup.fresh(
            in: [dir], since: Date().addingTimeInterval(-3600), seen: []
        )

        XCTAssertEqual(result.urls.map(\.lastPathComponent), [
            "Screen Recording 2026-09-11 at 10.00.01.mov",
            "Screen Recording 2026-09-11 at 10.00.02.mov",
        ])
    }

    /// A recording from before the first run is never offered, on any open —
    /// and it is not remembered either. `since` never moves, so the date alone
    /// settles it; remembering it as well is what filled the 1,000-name memory
    /// with files from before the install on a Desktop full of old captures,
    /// and pushed out the names of cards a person had removed (K-012).
    func testOldRecordingIsNeverOfferedAndNeverRemembered() throws {
        let dir = try folder()
        try write("old.mov", in: dir, modified: 30)
        let since = Date()

        let first = RecordingPickup.fresh(in: [dir], since: since, seen: [])
        XCTAssertTrue(first.urls.isEmpty)
        XCTAssertTrue(first.seen.isEmpty, "a file from before the install takes no room in the memory")

        let second = RecordingPickup.fresh(in: [dir], since: since, seen: first.seen)
        XCTAssertTrue(second.urls.isEmpty, "the date settles it on every open")
    }

    /// Past the cap, the memory lets go of the oldest captures first, by the
    /// file's date. It used to keep an arbitrary 1,000 by `Set` order, which
    /// changes with every launch's hash seed, so a card removed yesterday came
    /// back on roughly one open in three (K-012).
    func testTheMemoryForgetsTheOldestCapturesFirst() throws {
        let dir = try folder()
        try write("Screen Recording old.mov", in: dir, modified: 3)
        try write("Screen Recording middle.mov", in: dir, modified: 2)
        try write("Screen Recording new.mov", in: dir, modified: 1)
        var seen: Set<String> = [
            "Screen Recording old.mov", "Screen Recording middle.mov",
            "Screen Recording new.mov", "Screen Recording trashed.mov",
        ]

        RecordingPickup.trimSeen(&seen, folders: [dir], limit: 2)

        XCTAssertEqual(seen, ["Screen Recording middle.mov", "Screen Recording new.mov"])
    }

    /// Anything that is not a capture is left where it is.
    ///
    /// A still now counts, so the rule that keeps a Desktop full of somebody's
    /// own pictures off the shelf is the capture *prefix* — `picture.png` is
    /// theirs, `Screenshot ….png` is the system's.
    func testOnlyCapturesAreOffered() throws {
        let dir = try folder()
        try write("notes.txt", in: dir)
        try write("picture.png", in: dir)
        try write("song.mp3", in: dir)
        try write("Screenshot 2026-09-21 at 10.00.01.png", in: dir)

        let result = RecordingPickup.fresh(in: [dir], since: .distantPast, seen: [])
        XCTAssertEqual(
            result.urls.map(\.lastPathComponent),
            ["Screenshot 2026-09-21 at 10.00.01.png"]
        )
    }

    /// A still saved to disk arrives on the shelf beside the recordings.
    ///
    /// Only clipboard images used to reach the shelf, so ⇧⌘4 to a file showed
    /// nothing at all while ⇧⌘5 did — one capture key working and its
    /// neighbour not, for no reason a person could see.
    func testStillsAndRecordingsArriveTogetherOldestFirst() throws {
        let dir = try folder()
        try write("Screenshot 2026-09-21 at 10.00.01.png", in: dir, modified: 2)
        try write("Screen Recording 2026-09-21 at 10.00.02.mov", in: dir, modified: 1)

        let result = RecordingPickup.fresh(in: [dir], since: .distantPast, seen: [])
        XCTAssertEqual(result.urls.map(\.lastPathComponent), [
            "Screenshot 2026-09-21 at 10.00.01.png",
            "Screen Recording 2026-09-21 at 10.00.02.mov",
        ])
    }

    /// A custom prefix set in Screenshot.app's options is honoured.
    func testACustomCaptureNameIsHonoured() throws {
        let dir = try folder()
        try write("Grab 2026-09-21 at 10.00.01.png", in: dir)
        let prefixes = RecordingPickup.capturePrefixes(customName: "Grab")
        let result = RecordingPickup.fresh(
            in: [dir], since: .distantPast, seen: [], prefixes: prefixes
        )
        XCTAssertEqual(result.urls.map(\.lastPathComponent), ["Grab 2026-09-21 at 10.00.01.png"])
    }

    /// Changing the save location must not orphan what is still in the old one.
    ///
    /// The scan used to look at the current folder and nowhere else, so a
    /// person who moved their captures mid-session lost everything already
    /// sitting where they used to go.
    func testCapturesInAPreviousFolderAreStillFound() throws {
        let old = try folder()
        let new = try folder()
        try write("Screen Recording 2026-09-21 at 09.00.00.mov", in: old, modified: 2)
        try write("Screenshot 2026-09-21 at 10.00.00.png", in: new, modified: 1)

        let result = RecordingPickup.fresh(in: [new, old], since: .distantPast, seen: [])
        XCTAssertEqual(Set(result.urls.map(\.lastPathComponent)), [
            "Screen Recording 2026-09-21 at 09.00.00.mov",
            "Screenshot 2026-09-21 at 10.00.00.png",
        ])
    }

    /// And the folder list remembers where captures have been sent, so the
    /// next scan still looks in the one that was just left behind.
    func testTheFolderListRemembersWhereCapturesHaveBeenSent() throws {
        let suite = "isla-capture-folders-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = try folder()
        let plist = dir.appendingPathComponent("com.apple.screencapture.plist")
        try (["showsCursor": true] as NSDictionary).write(to: plist)
        let earlier = try folder()
        defaults.set([earlier.path], forKey: RecordingPickup.knownFoldersKey)

        let folders = RecordingPickup.captureFolders(defaults: defaults, preferencesFile: plist)
        XCTAssertEqual(
            defaults.stringArray(forKey: RecordingPickup.knownFoldersKey), folders.map(\.path),
            "what was scanned is written back, so a later change keeps it in the list"
        )
        // With nothing configured the Desktop is the current folder, so it
        // leads the list; the folder left behind follows it.
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true).path
        XCTAssertEqual(folders.map(\.path), [desktop, earlier.path])
    }

    /// The Desktop is scanned only when captures go there. It used to be
    /// appended to every list, so a person whose screenshots go to ~/Pictures
    /// was still asked for the Desktop the first time the Shelf opened (J-021).
    func testDesktopIsNotAddedWhenALocationIsConfigured() throws {
        let suite = "isla-capture-folders-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = try folder()
        let plist = dir.appendingPathComponent("com.apple.screencapture.plist")
        try (["location": dir.path] as NSDictionary).write(to: plist)

        let folders = RecordingPickup.captureFolders(defaults: defaults, preferencesFile: plist)

        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true).path
        XCTAssertFalse(folders.map(\.path).contains(desktop))
        XCTAssertEqual(folders.map(\.path), [dir.path])
    }

    /// A remembered folder that no longer exists is dropped from the list, so
    /// a retired capture folder is not probed again on every Shelf open
    /// (J-021). Three kinds stay: the current folder (Screenshot.app may just
    /// not have made it yet), a folder under /Volumes (its disk is unplugged,
    /// not gone), and a folder that exists (refused or not).
    func testAFolderThatNoLongerExistsIsForgotten() throws {
        let suite = "isla-capture-folders-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let present = try folder()
        let gone = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-never-created-\(UUID())", isDirectory: true)
        let current = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-current-\(UUID())", isDirectory: true)
        let unplugged = URL(fileURLWithPath: "/Volumes/isla-unplugged-\(UUID())", isDirectory: true)
        defaults.set(
            [current.path, present.path, gone.path, unplugged.path],
            forKey: RecordingPickup.knownFoldersKey
        )

        let result = RecordingPickup.fresh(
            in: [current, present, gone, unplugged], since: .distantPast, seen: []
        )
        XCTAssertEqual(
            Set(result.missing.map(\.path)), [current.path, gone.path, unplugged.path],
            "missing is what the disk said, and nothing else"
        )

        RecordingPickup.forget(result.missing, defaults: defaults, current: current)

        XCTAssertEqual(
            defaults.stringArray(forKey: RecordingPickup.knownFoldersKey),
            [current.path, present.path, unplugged.path]
        )
    }

    func testMissingFolderIsEmptyNotAnError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-never-created-\(UUID())")
        let result = RecordingPickup.fresh(in: [missing], since: .distantPast, seen: [])
        XCTAssertTrue(result.urls.isEmpty)
    }

    func testConfiguredLocationWinsOverDesktop() throws {
        let dir = try folder()
        let plist = dir.appendingPathComponent("com.apple.screencapture.plist")
        let custom = dir.appendingPathComponent("Captures")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try (["location": "~/Captures-test-unused"] as NSDictionary).write(to: plist)

        let resolved = RecordingPickup.screencaptureLocation(preferencesFile: plist)
        XCTAssertEqual(resolved, "~/Captures-test-unused")
    }

    func testMissingLocationFallsBackToDesktop() throws {
        let dir = try folder()
        let plist = dir.appendingPathComponent("com.apple.screencapture.plist")
        try (["showsCursor": true] as NSDictionary).write(to: plist)

        XCTAssertNil(RecordingPickup.screencaptureLocation(preferencesFile: plist))
        XCTAssertEqual(
            RecordingPickup.captureFolder(preferencesFile: plist).lastPathComponent, "Desktop",
            "no configured location means where the system saves by default"
        )
    }

    /// A screenshot taken on the lock screen is named by the login window,
    /// "LWScreenShot …", whatever the capture name — and it is a capture.
    func testALockScreenScreenshotIsACapture() {
        XCTAssertTrue(RecordingPickup.isCapture(
            URL(fileURLWithPath: "/tmp/LWScreenShot 2026-09-21 at 19.25.00.png")))
    }

    // MARK: - Captures on any system language (G-001)

    /// A Russian Mac names its stills "Снимок экрана …", and none of them
    /// reached the Shelf: the localized word was asked of a framework table
    /// that has no such key, so only the English prefixes were ever tried.
    func testARussianScreenshotIsACapture() throws {
        let dir = try folder()
        try write("Снимок экрана 2026-10-11 в 15.04.05.png", in: dir)
        XCTAssertTrue(RecordingPickup.isCapture(
            dir.appendingPathComponent("Снимок экрана 2026-10-11 в 15.04.05.png")))
    }

    /// The system marks every capture it writes, whatever the file is called:
    /// a still carrying the mark is a capture even with a name no prefix
    /// knows, and one with neither the mark nor a prefix is somebody's own.
    func testTheCaptureAttributeAloneMakesACapture() throws {
        let dir = try folder()
        try write("IMG.png", in: dir)
        try write("IMG 2.png", in: dir)
        let marked = dir.appendingPathComponent("IMG.png")
        let plain = dir.appendingPathComponent("IMG 2.png")
        let value = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let status = value.withUnsafeBytes { bytes in
            setxattr(marked.path, CaptureMetadata.screenCaptureAttribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        XCTAssertEqual(status, 0, "the fixture needs the attribute set")

        XCTAssertTrue(CaptureMetadata.hasScreenCaptureAttribute(marked))
        XCTAssertFalse(CaptureMetadata.hasScreenCaptureAttribute(plain))
        XCTAssertTrue(RecordingPickup.isCapture(marked, prefixes: []))
        XCTAssertFalse(RecordingPickup.isCapture(plain, prefixes: []))
    }

    /// The words come from Screenshot's own table, every language in it, so
    /// a Mac whose language changed still recognises what it captured before.
    /// A word carrying a soft hyphen (Dutch) is matched without it as well:
    /// the table hyphenates for display, and a filename need not.
    func testPrefixesComeFromTheSystemTable() throws {
        let dir = try folder()
        let table = dir.appendingPathComponent("Localizable.loctable")
        let fixture: NSDictionary = [
            "LocProvenance": ["Screenshot": 1],
            "ru": ["Screenshot": "Снимок экрана", "Screen Recording": "Запись экрана", "Done": "Готово"],
            "de": ["Screenshot": "Bildschirmfoto", "Screen Recording": "Bildschirmaufnahme"],
            "nl": ["Screenshot": "Scherm\u{00AD}afbeelding"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
        try data.write(to: table)

        let words = RecordingPickup.captureWords(inTable: table)
        for word in ["Снимок экрана", "Запись экрана", "Bildschirmfoto", "Bildschirmaufnahme", "Schermafbeelding"] {
            XCTAssertTrue(words.contains(word), "\(word) is missing from \(words)")
        }
        XCTAssertFalse(words.contains("Готово"), "only the two capture words are taken")

        let prefixes = RecordingPickup.capturePrefixes(customName: nil, systemWords: words)
        XCTAssertTrue(prefixes.contains("Screenshot"), "the English defaults stay")
        XCTAssertTrue(prefixes.contains("Bildschirmfoto"))
        XCTAssertTrue(
            RecordingPickup.captureWords(inTable: dir.appendingPathComponent("absent.loctable")).isEmpty,
            "a macOS that moves the table yields no extra words, not a crash"
        )
    }
}
