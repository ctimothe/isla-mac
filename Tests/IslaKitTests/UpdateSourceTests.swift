import Foundation
import XCTest
@testable import IslaKit

/// Where Update Now takes its releases from (`UpdateSource`): GitHub, a
/// rehearsal folder named at launch, or the local feed — a folder on this Mac
/// named by the `updates.localFeed` setting, which the owner's own Mac follows
/// so every change reaches it through Isla's updater rather than a reinstall
/// (plan 2026-10-19). Only the source changes; the signature, the validator,
/// the swap and the relaunch are the ones a GitHub release goes through, and
/// these hold that the setting can point the updater at nothing but a folder
/// that is the user's own and no one else's to write.
@MainActor
final class UpdateSourceTests: XCTestCase {
    private func folder(mode: Int = 0o700) throws -> URL {
        let url = try UpdateTestSupport.folder(self).resolvingSymlinksInPath()
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    private func resolve(rehearsal: URL? = nil, setting: String?, owner: ((URL) -> UInt32?)? = nil) -> UpdateSource {
        UpdateSource.resolve(rehearsal: rehearsal, setting: setting, owner: owner ?? UpdateInstaller.ownerID)
    }

    // MARK: Which source

    func testWithNothingSetTheReleasesComeFromGitHub() {
        XCTAssertEqual(resolve(setting: nil), .github)
        XCTAssertEqual(resolve(setting: ""), .github)
        XCTAssertNil(UpdateSource.github.folder)
    }

    func testTheSettingNamesTheLocalFeed() throws {
        let feed = try folder()
        XCTAssertEqual(resolve(setting: feed.path), .localFeed(feed))
        XCTAssertEqual(UpdateSource.localFeed(feed).folder, feed)
    }

    /// The rehearsal is a launch-time act of the owner's for one run; it wins
    /// over a standing setting, so a rehearsal is always what it says.
    func testARehearsalNamedAtLaunchWinsOverTheSetting() throws {
        let feed = try folder()
        let rehearsal = try folder()
        XCTAssertEqual(resolve(rehearsal: rehearsal, setting: feed.path), .rehearsal(rehearsal))
        XCTAssertEqual(UpdateSource.rehearsal(rehearsal).folder, rehearsal)
    }

    func testLinksInTheSettingAreResolved() throws {
        let feed = try folder()
        let link = feed.deletingLastPathComponent().appendingPathComponent("feed-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: feed)
        addTeardownBlock { try? FileManager.default.removeItem(at: link) }
        XCTAssertEqual(resolve(setting: link.path), .localFeed(feed))
    }

    // MARK: What the setting may name

    func testASettingThatIsNotAnAbsoluteFolderIsIgnored() throws {
        let feed = try folder()
        let file = feed.appendingPathComponent("release.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertEqual(resolve(setting: "relative/feed"), .github)
        XCTAssertEqual(resolve(setting: "~/feed"), .github, "no tilde expansion: a path is absolute or it is nothing")
        XCTAssertEqual(resolve(setting: feed.appendingPathComponent("missing").path), .github)
        XCTAssertEqual(resolve(setting: file.path), .github, "a file is not a folder")
    }

    /// A folder another account owns could be filled by that account; the
    /// signature would still refuse what it put there, but a feed nobody else
    /// can fill is the rule, not the hope.
    func testAFolderSomeoneElseOwnsIsIgnored() throws {
        let feed = try folder()
        XCTAssertEqual(resolve(setting: feed.path, owner: { _ in 0 }), .github, "root's folder")
        XCTAssertEqual(resolve(setting: feed.path, owner: { _ in getuid() + 1 }), .github, "another user's")
        XCTAssertEqual(resolve(setting: feed.path, owner: { _ in nil }), .github, "an owner that cannot be read")
    }

    func testAFolderOthersCanWriteIsIgnored() throws {
        XCTAssertEqual(resolve(setting: try folder(mode: 0o770).path), .github, "group-writable")
        XCTAssertEqual(resolve(setting: try folder(mode: 0o707).path), .github, "world-writable")
        XCTAssertEqual(resolve(setting: try folder(mode: 0o1777).path), .github, "sticky does not make it ours")
        let readable = try folder(mode: 0o755)
        XCTAssertEqual(resolve(setting: readable.path), .localFeed(readable), "others may read it; only writing is refused")
    }

    // MARK: Read once, from one place

    /// A test run follows GitHub: no rehearsal variable, and the test host's
    /// defaults carry no feed. Read once, at first use, like the rehearsal.
    func testATestRunFollowsGitHub() {
        XCTAssertEqual(UpdateSource.current, .github)
    }

    /// The setting's key is spelled in one source file; everything else asks
    /// `UpdateSource`. (Comments may name it.)
    func testNoSourceButUpdateSourceReadsTheSetting() throws {
        let sources = VisualLab.repositoryRoot.appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var readers: Set<String> = []
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines) {
                let code = line.trimmingCharacters(in: .whitespaces)
                if !code.hasPrefix("//"), code.contains("updates.localFeed") { readers.insert(file.lastPathComponent) }
            }
        }
        XCTAssertEqual(readers, ["UpdateSource.swift"])
    }

    // MARK: The check follows the source

    private func release(in folder: URL, version: String = "0.3.0.1") -> Data {
        let object: [String: Any] = [
            "tag_name": "v\(version)",
            "html_url": "https://github.com/ctimothe/isla-mac/releases/tag/v\(version)",
            "body": "fix: the island stays at the notch while locked", "draft": false, "prerelease": false,
            "assets": [
                ["name": "Isla-\(version).dmg", "size": 1234, "browser_download_url": "file://\(folder.path)/Isla-\(version).dmg"],
                ["name": "Isla-\(version).dmg.sig", "size": 88, "browser_download_url": "file://\(folder.path)/Isla-\(version).dmg.sig"],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// On the local feed the check reads the folder's `release.json` and asks
    /// nothing of the network, and a dev build's four-part version is newer
    /// than the release it was cut from.
    func testOnTheLocalFeedTheCheckReadsTheFolderAndNotTheNetwork() async throws {
        let feed = try folder()
        try release(in: feed).write(to: feed.appendingPathComponent("release.json"))
        let asked = Counter()
        let check = UpdateCheck(
            fetch: { _ in asked.bump(); throw URLError(.notConnectedToInternet) },
            currentVersion: { "0.3.0" }, source: .localFeed(feed)
        )
        XCTAssertTrue(check.isLocalFeed)
        XCTAssertFalse(check.isRehearsal)
        check.check()
        for _ in 0..<200 where check.state == .checking { try await Task.sleep(for: .milliseconds(10)) }
        guard case .available(let found) = check.state else { return XCTFail("found \(check.state)") }
        XCTAssertEqual(found.version, "0.3.0.1")
        XCTAssertTrue(found.isInstallable, "both files, confined to the feed")
        XCTAssertEqual(asked.value, 0)
    }

    /// The release `Scripts/publish-dev-update.sh` writes, through the very
    /// writer it calls, is one the check offers and the installer can install.
    /// The first version of the script named the commit's page as the
    /// release's, which the page rule refuses (G-027), so the feed never
    /// offered anything; the hand-built answer above did not catch it because
    /// it was not the script's.
    func testTheReleaseThePublishScriptWritesIsOffered() throws {
        let feed = try folder()
        let out = feed.appendingPathComponent("release.json")
        let writer = VisualLab.repositoryRoot.appendingPathComponent("Scripts/dev-feed-release.py")
        let (status, output) = UpdateTestSupport.run("/usr/bin/python3", [
            "-I", writer.path, out.path, feed.path, "0.3.0.4", "57", String(repeating: "a", count: 40), "5242880", "88",
            "- The island stays at the notch while locked\n- Lyrics follow the voice",
        ])
        XCTAssertEqual(status, 0, output)
        let data = try Data(contentsOf: out)
        guard case .available(let found) = UpdateCheck.state(forRelease: data, localVersion: "0.3.0.3", rehearsal: feed)
        else { return XCTFail("the check refused the script's release: \(UpdateCheck.state(forRelease: data, localVersion: "0.3.0.3", rehearsal: feed))") }
        XCTAssertEqual(found.version, "0.3.0.4")
        XCTAssertTrue(found.isInstallable, "both files, confined to the feed")
        XCTAssertEqual(found.dmg?.size, 5_242_880)
        XCTAssertEqual(UpdateOffer(release: found).summary, "The island stays at the notch while locked")
        // The fields only the script reads back are where it looks for them.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["isla_build"] as? Int, 57)
        XCTAssertEqual(object["isla_commit"] as? String, String(repeating: "a", count: 40))
    }

    /// A dev build is offered over the build it replaces, and the next real
    /// release is offered over every dev build of the one before it.
    func testDevVersionsSortBetweenReleases() {
        XCTAssertTrue(UpdateCheck.isNewer("0.3.0.1", than: "0.3.0"))
        XCTAssertTrue(UpdateCheck.isNewer("0.3.0.12", than: "0.3.0.9"))
        XCTAssertTrue(UpdateCheck.isNewer("0.3.1", than: "0.3.0.40"))
        XCTAssertFalse(UpdateCheck.isNewer("0.3.0", than: "0.3.0.1"))
    }

    /// The installer and the downloader take the same folder the check does,
    /// so the three cannot follow different sources.
    func testTheInstallerAndTheDownloaderFollowTheSameFolder() throws {
        let feed = try folder()
        XCTAssertEqual(URLSessionUpdateDownloader(source: .localFeed(feed)).rehearsal, feed)
        XCTAssertNil(URLSessionUpdateDownloader(source: .github).rehearsal)
        XCTAssertNil(UpdateEnvironment.live().rehearsal, "a test run follows GitHub")
    }

    /// The local feed is signed with a key of its own (`IslaDevUpdatePublicKey`,
    /// the keychain's "Isla Dev Update Signing"), so a day of dev builds never
    /// reads the release key, and a dev build's signature installs nowhere but
    /// from the feed. GitHub and a rehearsal keep the release key; the feed
    /// never falls back to it, so a build without the dev key offers only its
    /// page there.
    func testTheLocalFeedTrustsTheDevKeyAndNothingElse() throws {
        let feed = try folder()
        func key(_ source: UpdateSource, dev: String? = "DEV") -> String? {
            UpdateSignature.trustedKey(for: source, release: "RELEASE", dev: dev)
        }
        XCTAssertEqual(key(.github), "RELEASE")
        XCTAssertEqual(key(.rehearsal(feed)), "RELEASE", "rehearse-update.sh signs with the release key")
        XCTAssertEqual(key(.localFeed(feed)), "DEV")
        XCTAssertNil(key(.localFeed(feed), dev: nil), "never the release key on the feed")
        XCTAssertNil(UpdateSignature.bundledDevPublicKey, "the test host carries no key")
    }

    /// The card says where its updates come from whenever it is not GitHub.
    func testTheCardSaysWhenUpdatesComeFromTheLocalFeed() {
        func note(rehearsal: Bool = false, localFeed: Bool = false) -> String? {
            UpdatePresentation.make(
                check: .idle, known: nil, phase: .idle, installerRelease: nil, manualReason: nil,
                runningVersion: "0.3.0", rehearsal: rehearsal, localFeed: localFeed
            ).sourceNote
        }
        XCTAssertNil(note())
        XCTAssertEqual(note(localFeed: true), "Updates come from a folder on this Mac.")
        XCTAssertEqual(note(rehearsal: true, localFeed: true), "Rehearsal: update from a local folder", "a rehearsal says it is one")
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
