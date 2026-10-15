import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import IslaKit

// MARK: - The visual lab
//
// A headless photographer for every surface Isla draws. Nothing here drives
// the desktop: no window is ever ordered on screen, no event is posted, no
// screen is captured, Isla is never launched and no DI_* hook is read. Views
// are hosted in an `NSHostingView` inside a borderless window that is created
// and never ordered in, and drawn into a bitmap with `cacheDisplay`; or drawn
// by `ImageRenderer`, which needs no window at all.
//
// Every case is gated on ISLA_VISUAL_OUT and skips without it, so the gate
// (`./scripts/check`) runs none of this. Run it with `Scripts/visual-lab.sh`.
//
// Isolation, because the owner's Mac is shared with other sessions:
// - Defaults: every key a view reads from `UserDefaults.standard` is answered
//   from the *argument domain*, a volatile in-memory domain that sits first in
//   the search list and is never written to disk. Nothing is `set` on the
//   standard defaults; stores that take a `UserDefaults` get a private suite
//   that is removed afterwards.
// - Pasteboard: the general pasteboard is never read or written. The
//   clipboard store is filled through its own `record` and handed a uniquely
//   named private pasteboard, which only a pressed row's copy ever writes.
// - Network: a URLProtocol registered for the process answers every request
//   itself, so nothing leaves the machine. It plays Spotify's Liked Songs
//   answer and refuses everything else as offline.
// - Players: every MediaController is cut from real players
//   (`isolateFromPlayers`), carries no player pid, and runs on a frozen clock.
// - Spotify: `SpotifyAccount.sharedOverride` stands an account in front of the
//   real one before anything asks, so the live account is never built.

enum VisualLab {
    static let envKey = "ISLA_VISUAL_OUT"

    static var outputRoot: URL? {
        guard let path = ProcessInfo.processInfo.environment[envKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func requireOutput() throws -> URL {
        guard let root = outputRoot else { throw XCTSkip("set \(envKey) to run the visual lab") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The repository root, found from this file so the lab can read the
    /// `.lproj` tables SwiftPM does not bundle into the test runner.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Window size the panel is cut to. Every panel and pill render uses it,
    /// so a reviewer sees the island where it really sits in its window.
    static let windowSize = NotchMetrics.maximumWindow
}

func labTrace(_ message: String) {
    guard ProcessInfo.processInfo.environment["ISLA_VISUAL_TRACE"] != nil else { return }
    FileHandle.standardError.write(Data(("LAB " + message + "\n").utf8))
}

// MARK: - Variants

enum LabBackend: String, Codable {
    /// NSHostingView in a never-ordered window, drawn with `cacheDisplay`.
    /// Draws AppKit-backed controls (Toggle, Slider, TextEditor, menus,
    /// ScrollView) and yields an accessibility tree. Does **not** draw Core
    /// Animation filters: SwiftUI `.blur` and `NSVisualEffectView` come out
    /// sharp or flat grey.
    case host
    /// SwiftUI `ImageRenderer`. Draws blur and every SwiftUI effect, but
    /// replaces any AppKit-backed view with a yellow "unavailable" plate and
    /// draws ScrollView content as nothing.
    case imageRenderer = "ir"
}

struct LabVariant: Hashable {
    var name: String
    /// A pale wallpaper and a light menu bar. Isla's own windows are forced
    /// to dark Aqua (`NotchPanel` sets `.darkAqua`), so this changes only what
    /// is behind the island, which is exactly what a light desktop changes.
    var lightDesktop = false
    var increaseContrast = false
    var reduceTransparency = false
    var reduceMotion = false
    var width: CGFloat = NotchMetrics.defaultBodyWidth
    var language = "en"
    var backend: LabBackend = .host

    static let base = LabVariant(name: "dark")
    static let light = LabVariant(name: "light", lightDesktop: true)
    static let contrast = LabVariant(name: "increase-contrast", increaseContrast: true)
    static let transparency = LabVariant(name: "reduce-transparency", reduceTransparency: true)
    static let motion = LabVariant(name: "reduce-motion", reduceMotion: true)
    static let w480 = LabVariant(name: "w480", width: 480)
    static let w620 = LabVariant(name: "w620", width: 620)
    static let russian = LabVariant(name: "ru", language: "ru")
    static let baseIR = LabVariant(name: "dark-ir", backend: .imageRenderer)

    static let panel: [LabVariant] = [base, light, contrast, transparency, w480, w620, russian, baseIR]
    static let pill: [LabVariant] = [base, light, contrast, w480, russian, baseIR]
    static let card: [LabVariant] = [
        base, light, contrast, transparency, russian,
        LabVariant(name: "dark-ir", backend: .imageRenderer),
        LabVariant(name: "light-ir", lightDesktop: true, backend: .imageRenderer),
        LabVariant(name: "increase-contrast-ir", increaseContrast: true, backend: .imageRenderer),
        LabVariant(name: "reduce-transparency-ir", reduceTransparency: true, backend: .imageRenderer),
        LabVariant(name: "ru-ir", language: "ru", backend: .imageRenderer),
    ]
}

// MARK: - Manifest

struct LabRecord: Codable {
    var surface: String
    var state: String
    var variant: String
    var backend: String
    var width: Int
    var height: Int
    var scale: Int
    var path: String
    var a11y: String?
    var notes: String?
}

/// Each case writes its own fragment, then rebuilds `manifest.json` and the
/// contact sheets of the surfaces it touched from every fragment present. A
/// case run on its own therefore still leaves a valid manifest behind.
@MainActor
final class LabManifest {
    let root: URL
    let caseName: String
    private(set) var records: [LabRecord] = []

    init(root: URL, caseName: String) {
        self.root = root
        self.caseName = caseName
    }

    func add(_ record: LabRecord) { records.append(record) }

    func flush() throws {
        let fragments = root.appendingPathComponent(".records", isDirectory: true)
        try FileManager.default.createDirectory(at: fragments, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: fragments.appendingPathComponent("\(caseName).json"))

        var all: [LabRecord] = []
        for file in (try? FileManager.default.contentsOfDirectory(at: fragments, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let some = try? JSONDecoder().decode([LabRecord].self, from: data) {
                all += some
            }
        }
        all.sort { $0.path < $1.path }
        let manifest = LabManifestFile(
            generated: "Isla visual lab",
            imageCount: all.count,
            surfaces: Array(Set(all.map(\.surface))).sorted(),
            records: all
        )
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"))

        for surface in Set(records.map(\.surface)) {
            try LabContactSheet.write(surface: surface, records: all.filter { $0.surface == surface }, root: root)
        }
    }
}

struct LabManifestFile: Codable {
    var generated: String
    var imageCount: Int
    var surfaces: [String]
    var records: [LabRecord]
}

// MARK: - Session: everything global, set and put back

/// Answers every request the process makes, so a render can never reach the
/// network. Spotify's Liked Songs check gets the answer the case asked for;
/// everything else is told the Mac is offline.
final class LabNetworkGuard: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var likedSongs = false
    nonisolated(unsafe) static var slowSpotify = false
    nonisolated(unsafe) static var seen: [String] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url
        Self.lock.withLock { Self.seen.append(url?.absoluteString ?? "?") }
        if let url, url.host == "api.spotify.com", url.path.hasSuffix("/me/library/contains"),
           let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) {
            let body = Data((Self.likedSongs ? "[true]" : "[false]").utf8)
            let answer = { [self] in
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
            // Held back to draw the heart while it is still asking.
            if Self.slowSpotify {
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: answer)
            } else {
                answer()
            }
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

/// Swaps the strings the app looks up for a language's table, read straight
/// from `Resources/<lang>.lproj` — the test runner's main bundle is the xctest
/// tool, which carries none. Two lookups are answered: `localized(_:)` goes
/// through `localizedString(forKey:value:table:)`, and SwiftUI's `Text` with a
/// literal goes through `localizedAttributedStringForKey:value:table:`.
final class LabBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static var table: [String: String]?
    nonisolated(unsafe) static var language = "en"

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let table = Self.table, let hit = table[key] { return hit }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }

    override var preferredLocalizations: [String] { [Self.language] }
}

@MainActor
enum LabLocalization {
    private static var installed = false
    private static var originalClass: AnyClass?
    private static var tables: [String: [String: String]] = [:]

    static func use(_ language: String) {
        install()
        LabBundle.language = language
        LabBundle.table = language == "en" ? nil : table(for: language)
    }

    static func table(for language: String) -> [String: String]? {
        if let cached = tables[language] { return cached }
        let url = VisualLab.repositoryRoot.appendingPathComponent("Resources/\(language).lproj/Localizable.strings")
        let table = NSDictionary(contentsOf: url) as? [String: String]
        tables[language] = table
        return table
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        let selector = NSSelectorFromString("localizedAttributedStringForKey:value:table:")
        if let method = class_getInstanceMethod(Bundle.self, selector) {
            typealias Original = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?) -> NSAttributedString
            let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
            let block: @convention(block) (AnyObject, NSString, NSString?, NSString?) -> NSAttributedString = { this, key, value, table in
                if let hit = LabBundle.table?[key as String] { return NSAttributedString(string: hit) }
                return original(this, selector, key, value, table)
            }
            class_addMethod(LabBundle.self, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
        originalClass = object_getClass(Bundle.main)
        object_setClass(Bundle.main, LabBundle.self)
    }

    static func uninstall() {
        guard installed, let originalClass else { return }
        LabBundle.table = nil
        LabBundle.language = "en"
        object_setClass(Bundle.main, originalClass)
        installed = false
    }
}

/// Per-case state: a temporary directory, a private defaults suite, an
/// isolated Spotify account, and the global switches the views read.
@MainActor
final class LabSession {
    let root: URL
    let manifest: LabManifest
    let temp: URL
    let suiteName: String
    let suite: UserDefaults
    let paths: AppPaths
    let pasteboard: NSPasteboard
    let spotify: SpotifyAccount
    let credentials: CredentialStore
    private var savedArgumentDomain: [String: Any]?
    private let savedLinger: TimeInterval
    /// Keys every view reads from the standard defaults, answered from the
    /// argument domain. The case adds or overrides its own on top.
    private(set) var defaults: [String: Any] = [:]

    init(caseName: String) throws {
        root = try VisualLab.requireOutput()
        manifest = LabManifest(root: root, caseName: caseName)
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-visual-lab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        suiteName = "com.ctimothe.isla.visuallab.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        paths = AppPaths(
            supportDirectory: temp.appendingPathComponent("support", isDirectory: true),
            screenshotDirectory: temp.appendingPathComponent("pictures", isDirectory: true)
        )
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.ctimothe.isla.visuallab.\(UUID().uuidString)"))

        labTrace("session init")
        _ = NSApplication.shared
        // SwiftUI builds its accessibility tree only once an assistive client
        // has asked for it. Raising the application's enhanced-UI attribute is
        // that request, made in-process; nothing outside the test sees it.
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:"),
                          with: NSNumber(value: true))

        URLProtocol.registerClass(LabNetworkGuard.self)
        LabNetworkGuard.likedSongs = false

        credentials = CredentialStore(service: "com.ctimothe.isla.visuallab.\(UUID().uuidString)", paths: paths)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LabNetworkGuard.self]
        spotify = SpotifyAccount(credentials: credentials, session: URLSession(configuration: configuration))
        SpotifyAccount.sharedOverride = spotify

        savedArgumentDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        savedLinger = NotchMetrics.pausedLinger
        // A paused pill lingers for this long before folding. Long enough
        // here that the paused state is still on screen when it is drawn.
        NotchMetrics.pausedLinger = 600
        setDefaults([:])
    }

    /// The argument-domain answers for this render.
    func setDefaults(_ overrides: [String: Any], width: CGFloat = NotchMetrics.defaultBodyWidth) {
        var values: [String: Any] = [
            NotchViewModel.bodyWidthKey: Double(width),
            // The drawn glass recipe everywhere: neither renderer can sample
            // the system material's backdrop.
            NotchViewModel.drawnGlassKey: true,
            NotchViewModel.showLyricsKey: true,
            NotchViewModel.onlineLyricsKey: false,
            NotchViewModel.onlineTranslationKey: false,
            NotchViewModel.clipboardHistoryKey: true,
            NotchViewModel.saveClipboardImagesKey: false,
            // Off, so opening the Shelf never scans a real captures folder.
            NotchViewModel.importRecordingsKey: false,
            NotchViewModel.opensOnHoverKey: false,
            NotchViewModel.newTracksKey: true,
            NotchViewModel.showOnLockScreenKey: true,
            NotchViewModel.lockCardStyleKey: NotchViewModel.LockCardStyle.glass.rawValue,
            NotchViewModel.lockCardSizeKey: NotchViewModel.LockCardSize.standard.rawValue,
            NotchViewModel.chargingKey: true,
            NotchViewModel.headphonesKey: true,
            NotchViewModel.musicOnlyKey: true,
            NotchViewModel.hideFromCaptureKey: true,
            NotchViewModel.hasCompletedFirstRunKey: true,
            NotchViewModel.hoverDelayKey: 0.0,
            UpdateCheck.automaticKey: false,
            LyricsStore.wordKaraokeEnabledKey: false,
            LyricsStore.offsetKey: 0.0,
        ]
        for (key, value) in overrides { values[key] = value }
        defaults = values
        UserDefaults.standard.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
    }

    /// Puts the variant's accessibility settings and language in place.
    func apply(_ variant: LabVariant, defaults overrides: [String: Any] = [:]) {
        setDefaults(overrides, width: variant.width)
        SystemAppearance.shared.overrideForTests(
            reduceTransparency: variant.reduceTransparency,
            increaseContrast: variant.increaseContrast,
            reduceMotion: variant.reduceMotion
        )
        LabLocalization.use(variant.language)
    }

    func finish() async throws {
        try manifest.flush()
        if let savedArgumentDomain {
            UserDefaults.standard.setVolatileDomain(savedArgumentDomain, forName: UserDefaults.argumentDomain)
        } else {
            UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        }
        NotchMetrics.pausedLinger = savedLinger
        SystemAppearance.shared.resetForTests()
        LabLocalization.uninstall()
        SpotifyAccount.sharedOverride = nil
        URLProtocol.unregisterClass(LabNetworkGuard.self)
        await credentials.clear()
        pasteboard.releaseGlobally()
        suite.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeSuite(named: suiteName)
        try? FileManager.default.removeItem(at: temp)
    }

    /// A connected Spotify account: tokens written to the lab's own throwaway
    /// credential store, then a fresh account that reads them, standing in for
    /// `shared` from here on. Its Liked Songs answer comes from the network
    /// guard, so `liked` decides the heart.
    @discardableResult
    func connectSpotify(liked: Bool) async -> SpotifyAccount {
        LabNetworkGuard.likedSongs = liked
        await credentials.storeTokens(access: "lab-access", refresh: "lab-refresh",
                                      expiresAt: String(Date().timeIntervalSince1970 + 3600))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LabNetworkGuard.self]
        let account = SpotifyAccount(credentials: credentials, session: URLSession(configuration: configuration))
        for _ in 0..<200 where !account.isConnected {
            try? await Task.sleep(for: .milliseconds(10))
        }
        SpotifyAccount.sharedOverride = account
        return account
    }

    func disconnectSpotify() async {
        await credentials.clear()
        SpotifyAccount.sharedOverride = spotify
    }

    // MARK: Stores

    /// A fresh set of session stores, every one pointed at the lab's own
    /// suite, pasteboard and temporary folder.
    func makeStores() -> NotchStores {
        labTrace("makeStores")
        // Each state starts from an empty suite: a privacy switch or a
        // translation target set for one state must not leak into the next.
        suite.removePersistentDomain(forName: suiteName)
        let clipboard = ClipboardStore(pasteboard: pasteboard)
        clipboard.wantsImages = { false }
        labTrace("NotchStores")
        let stores = NotchStores(
            lyricsEnabled: { true },
            localLyricsDirectory: temp.appendingPathComponent("lyrics", isDirectory: true),
            shelf: ShelfStore(defaults: suite),
            clipboard: clipboard,
            screenshotVault: ScreenshotVault(paths: paths),
            translator: Translator(defaults: suite, preferredLanguages: ["ru"]),
            privacy: PrivacyMode(defaults: suite)
        )
        labTrace("isolate")
        stores.media.isolateFromPlayers()
        stores.media.monotonicNow = { 50_000 }
        stores.media.lyricsShown = { false }
        stores.media.precisionPositionFetcher = { reply in reply(nil) }
        stores.translator.capabilitiesOverride = { _ in Translator.Capabilities() }
        return stores
    }

    /// Puts entries in the clipboard history the way a poll would, oldest
    /// first, with fixed times, without any pasteboard involved.
    func record(_ payloads: [ClipItem.Payload], into clipboard: ClipboardStore) {
        let start = Date(timeIntervalSince1970: 1_791_712_800) // 2026-10-11 08:00 UTC
        for (index, payload) in payloads.enumerated() {
            clipboard.record(ClipItem(payload: payload, date: start.addingTimeInterval(Double(index) * 60)))
        }
    }
}

// MARK: - Geometry

@MainActor
enum LabGeometry {
    /// A 14-inch MacBook Pro's cutout. Any screen will do as the anchor: every
    /// rect the views read is relative to the window, which is centred on the
    /// notch, so the screen only has to exist.
    static let physicalNotch = CGSize(width: 185, height: 32)
    /// What `NotchGeometry.current()` draws on a display with no cutout: 200
    /// wide since the redesign (spec §3.8), it was 180.
    static let syntheticNotch = CGSize(width: NotchGeometry.syntheticNotchWidth, height: 24)

    static func make(physical: Bool = true) throws -> NotchGeometry {
        // A process with no window-server session (a sandbox, a CI runner)
        // sees no screens at all. Nothing the views draw reads the screen —
        // every rect they use is relative to the window — so a bare one
        // stands in, rather than skipping the whole lab there.
        // `NSScreen()` itself traps without a display, so the stand-in is
        // allocated and never initialised: an object of the right class whose
        // frame reads as zero, and which nothing here ever asks about.
        labTrace("screens")
        let real = NSScreen.screens.first
        labTrace("screens read: \(real == nil ? "none" : "one")")
        let screen = real
            ?? ((NSScreen.self as AnyObject).perform(NSSelectorFromString("alloc"))?.takeRetainedValue() as! NSScreen)
        labTrace("screen ready")
        return NotchGeometry(
            screen: screen,
            notchSize: physical ? physicalNotch : syntheticNotch,
            notchCenterX: real?.frame.midX ?? 0,
            isPhysical: physical
        )
    }
}

// MARK: - Fixtures

@MainActor
enum LabFixtures {
    /// A cover with structure in it — two colours, a disc and a band — so the
    /// blur, the palette and the crop all have something to show.
    static func cover(_ hueA: NSColor = NSColor(calibratedRed: 0.93, green: 0.42, blue: 0.27, alpha: 1),
                      _ hueB: NSColor = NSColor(calibratedRed: 0.16, green: 0.25, blue: 0.55, alpha: 1),
                      side: CGFloat = 600) -> Data {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSGradient(starting: hueA, ending: hueB)?.draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: 35)
        NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: side * 0.18, y: side * 0.40, width: side * 0.36, height: side * 0.36)).fill()
        NSColor(calibratedWhite: 0.05, alpha: 0.75).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: side * 0.10, width: side, height: side * 0.12)).fill()
        image.unlockFocus()
        return png(image)
    }

    /// A flat colour cover, used to find where a cover lands in a render.
    static func solidCover(_ color: NSColor, side: CGFloat = 200) -> Data {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()
        return png(image)
    }

    /// The same cover, already blurred: what the lyrics stage's ambience
    /// draws. The hosting renderer cannot draw SwiftUI's blur, so the stage is
    /// given a cover whose blur is in the pixels. The stage shows the cover
    /// only as that ambience, so nothing sharp is lost.
    static func preblurred(_ data: Data, side: CGFloat = 600) -> Data {
        // Down to a few pixels and back up with smooth interpolation: a wash
        // close enough to a 60 pt Gaussian for a background that is then
        // dimmed to 35 %. Core Image was the first choice; rendering through
        // it inside an async test tripped the task allocator on this toolchain.
        guard let source = NSImage(data: data) else { return data }
        let tiny = NSImage(size: NSSize(width: 6, height: 6))
        tiny.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: 6, height: 6))
        tiny.unlockFocus()
        let wash = NSImage(size: NSSize(width: side, height: side))
        wash.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        tiny.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        wash.unlockFocus()
        return png(wash)
    }

    static func png(_ image: NSImage) -> Data {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return Data() }
        return data
    }

    @MainActor
    struct Track {
        var title = "Waiting Room"
        var artist = "Halcyon Static"
        var album = "Low Light"
        var duration: TimeInterval = 238
        var elapsed: TimeInterval = 84
        var playing = true
        var cover: Data? = LabFixtures.cover()
        var source: String? = "Music"
    }

    static let longTitle = Track(
        title: "The Longest Song Title Anyone Has Ever Put On A Record (Extended Twelve-Inch Remix)",
        artist: "An Orchestra With An Unreasonably Long Name and Friends",
        album: "Compilation Volume Seventeen"
    )
    static let cjkTitle = Track(
        title: "夜に駆ける", artist: "YOASOBI", album: "THE BOOK",
        cover: LabFixtures.cover(NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.30, alpha: 1),
                                 NSColor(calibratedRed: 0.85, green: 0.30, blue: 0.45, alpha: 1))
    )

    /// Puts a track on a controller through the same `apply` the feed uses,
    /// then waits for the cover to decode — it is decoded off the main thread.
    static func play(_ track: Track, on media: MediaController) async {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = track.title
        snapshot.artist = track.artist
        snapshot.album = track.album
        snapshot.duration = track.duration
        snapshot.elapsed = track.elapsed
        snapshot.rate = track.playing ? 1 : 0
        snapshot.isPlaying = track.playing
        snapshot.takenAt = Date()
        snapshot.artwork = track.cover
        snapshot.source = track.source
        media.apply(snapshot)
        guard track.cover != nil else { return }
        for _ in 0..<150 where media.artwork == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The same track, now paused — as the feed reports a pause.
    static func pause(_ track: Track, on media: MediaController) {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = track.title
        snapshot.artist = track.artist
        snapshot.album = track.album
        snapshot.duration = track.duration
        snapshot.elapsed = track.elapsed
        snapshot.rate = 0
        snapshot.isPlaying = false
        snapshot.takenAt = Date()
        snapshot.source = track.source
        media.apply(snapshot)
    }

    /// Word-level timing switched on the way the app switches it: a word
    /// timeline, the karaoke preference, and a measured position.
    static func enablePrecision(on media: MediaController, lyrics: LyricsStore) {
        lyrics.wordKaraokeEnabled = true
        media.precisionPlayerForTests = .music
        media.lyricsShown = { true }
        media.precisionPositionFetcher = { reply in reply(nil) }
        media.setActive(true)
    }

    static func disablePrecision(on media: MediaController) {
        media.setActive(false)
    }

    // MARK: Lyrics

    static let lines: [LyricsStore.Line] = [
        .init(at: 4, text: "I get up, get dressed and get out"),
        .init(at: 14, text: "Walk the length of the block and back"),
        .init(at: 24, text: "Sit in the waiting room again"),
        .init(at: 34, text: "Wondering if it's all in my head"),
        .init(at: 44, text: "And the line that comes after that"),
        .init(at: 54, text: "Something further along the road"),
        .init(at: 64, text: "The last one on the page"),
    ]

    static func timeline(_ lines: [LyricsStore.Line] = lines, granularity: LyricTimeline.Granularity = .line) -> LyricsAvailability {
        .ready(LyricTimeline(lines: lines, granularity: granularity))
    }

    /// Word stamps on every line, so the sweep follows the voice word by word.
    static var wordLines: [LyricsStore.Line] {
        lines.map { line in
            let words = line.text.split(separator: " ").map(String.init)
            let step = 8.0 / Double(max(words.count, 1))
            let stamps = words.enumerated().map { index, word in
                LyricWord(at: line.at + Double(index) * step, text: word)
            }
            return LyricsStore.Line(at: line.at, text: line.text, words: stamps)
        }
    }

    /// An instrumental break as a real file writes it: an empty stamp where
    /// the voice stops. It used to be a line with empty text, which the parser
    /// never produces — since LY-05 it reads that stamp as the end of the
    /// line before — so the lab drew a blank row no listener could ever see
    /// instead of the interlude they do (LY-13).
    static let gapLRC = """
    [00:04.00]Hold the note until it breaks
    [00:12.00]
    [00:40.00]And come back in on the downbeat
    [00:48.00]Every word where it belongs
    """

    static func gapLines() throws -> [LyricsStore.Line] {
        try LocalLyricsDocument.parse(gapLRC).lines
    }

    static let longLines: [LyricsStore.Line] = [
        .init(at: 4, text: "A first line that is long enough to need the second row the stage allows it"),
        .init(at: 14, text: "And another that keeps going well past the point where a single line would have stopped and wrapped"),
        .init(at: 24, text: "Then one so long it runs past both of the rows the stage gives it before the ellipsis has to take over at the end of the second"),
        .init(at: 34, text: "Short again"),
    ]

    static let cjkLines: [LyricsStore.Line] = [
        .init(at: 4, text: "沈むように溶けてゆくように"),
        .init(at: 14, text: "二人だけの空が広がる夜に"),
        .init(at: 24, text: "「さよなら」だけだった"),
        .init(at: 34, text: "その一言で全てが分かった"),
    ]
}

// MARK: - Backdrop

/// What sits behind the island: a stand-in wallpaper and a menu bar.
struct LabDesktop: View {
    var light: Bool
    var menuBarHeight: CGFloat
    var hardwareNotch: CGSize?

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: light
                    ? [Color(red: 0.80, green: 0.87, blue: 0.95), Color(red: 0.97, green: 0.90, blue: 0.80),
                       Color(red: 0.88, green: 0.92, blue: 0.86)]
                    : [Color(red: 0.11, green: 0.14, blue: 0.27), Color(red: 0.33, green: 0.20, blue: 0.36),
                       Color(red: 0.62, green: 0.38, blue: 0.30)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // A menu bar, translucent and empty: the 700 pt window is the
            // middle of the display, where macOS leaves the bar clear around
            // the notch, so items drawn here would only be invented clutter.
            Color.clear
                .frame(height: menuBarHeight)
            .background(light ? Color.white.opacity(0.55) : Color.black.opacity(0.28))
            if let hardwareNotch {
                // The cutout itself. The display has no pixels here; black is
                // what a person sees.
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                    .fill(Color.black)
                    .frame(width: hardwareNotch.width, height: hardwareNotch.height)
            }
        }
        // Scenery: kept out of the accessibility dump, which is about Isla.
        .accessibilityHidden(true)
    }
}

/// A lock screen's kind of wallpaper behind the lock card.
struct LabLockWallpaper: View {
    var light: Bool
    var body: some View {
        LinearGradient(
            colors: light
                ? [Color(red: 0.95, green: 0.93, blue: 0.88), Color(red: 0.74, green: 0.83, blue: 0.93)]
                : [Color(red: 0.20, green: 0.29, blue: 0.36), Color(red: 0.55, green: 0.62, blue: 0.66),
                   Color(red: 0.13, green: 0.17, blue: 0.22)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Rendering

struct LabShot {
    var rep: NSBitmapImageRep
    var accessibility: String?
}

@MainActor
enum LabRenderer {
    static let scale: CGFloat = 2

    /// Environment the variant asks for. The underscored keys are SwiftUI's
    /// own writable spellings of the accessibility settings it otherwise only
    /// reads from the system.
    static func environment<V: View>(_ view: V, _ variant: LabVariant) -> some View {
        view
            .environment(\._colorSchemeContrast, variant.increaseContrast ? .increased : .standard)
            .environment(\._accessibilityReduceTransparency, variant.reduceTransparency)
            // Not forced on for ImageRenderer, although it would swap the Core
            // Animation equalizer (drawn there as a placeholder plate) for
            // SwiftUI bars: Reduce Motion also fills the karaoke sweep and
            // changes transitions, and a render that changes the state to
            // look tidier is a render that lies.
            .environment(\._accessibilityReduceMotion, variant.reduceMotion)
            .environment(\.locale, Locale(identifier: variant.language))
    }

    static func render<V: View>(
        _ view: V, size: CGSize, variant: LabVariant, settle: TimeInterval = 0.15,
        interact: ((NSView) -> Void)? = nil
    ) async -> LabShot? {
        switch variant.backend {
        case .host: return await host(view, size: size, variant: variant, settle: settle, interact: interact)
        case .imageRenderer:
            await wait(settle)
            return imageRenderer(view, size: size, variant: variant)
        }
    }

    /// Lets the main run loop turn — SwiftUI applies state, `.task` and
    /// `onAppear` work on it — without nesting one: the test awaits, and
    /// XCTest keeps the main run loop running underneath.
    static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    static func imageRenderer<V: View>(_ view: V, size: CGSize, variant: LabVariant) -> LabShot? {
        let renderer = ImageRenderer(content: environment(view, variant).frame(width: size.width, height: size.height))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = size
        return LabShot(rep: rep, accessibility: nil)
    }

    /// Hosted in a borderless window that is created and never ordered in:
    /// it has no place on any screen, takes no events and is never seen.
    static func host<V: View>(
        _ view: V, size: CGSize, variant: LabVariant, settle: TimeInterval,
        interact: ((NSView) -> Void)? = nil
    ) async -> LabShot? {
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(x: -40_000, y: -40_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        // Every Isla window is a `NotchPanel`, which forces dark Aqua.
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: AnyView(environment(view, variant).frame(width: size.width, height: size.height)))
        hosting.sizingOptions = []
        hosting.frame = rect
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // The first question is what makes SwiftUI build the tree; the
        // answer is there a run-loop turn later.
        _ = hosting.accessibilityChildren()
        await wait(settle)
        _ = hosting.accessibilityChildren()
        await wait(0.02)
        if let interact {
            interact(hosting)
            hosting.layoutSubtreeIfNeeded()
            await wait(0.12)
        }
        hosting.layoutSubtreeIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        hosting.cacheDisplay(in: rect, to: rep)
        labTrace("cached; dumping ax")
        let tree = LabAccessibility.dump(hosting, window: window)
        labTrace("ax done")
        window.contentView = nil
        window.close()
        return LabShot(rep: rep, accessibility: tree)
    }

    static func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "VisualLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        try data.write(to: url)
    }
}

// MARK: - Accessibility

@MainActor
enum LabAccessibility {
    /// The tree an assistive client would walk: role, label, value, help and
    /// frame for every element under the hosting view, frames in points from
    /// the render's top-left corner.
    static func dump(_ root: NSView, window: NSWindow) -> String {
        var lines: [String] = []
        let origin = window.frame
        func walk(_ element: NSObject, depth: Int) {
            guard depth < 40, lines.count < 4000 else { return }
            let role = text(get(element, "accessibilityRole"))
            let subrole = text(get(element, "accessibilitySubrole"))
            let label = text(get(element, "accessibilityLabel"))
            let title = text(get(element, "accessibilityTitle"))
            let value = text(get(element, "accessibilityValue"))
            let help = text(get(element, "accessibilityHelp"))
            var fields = ["[\(role.isEmpty ? "?" : role)\(subrole.isEmpty ? "" : "/\(subrole)")]"]
            if !label.isEmpty { fields.append("label=\(quoted(label))") }
            if !title.isEmpty { fields.append("title=\(quoted(title))") }
            if !value.isEmpty { fields.append("value=\(quoted(value))") }
            if !help.isEmpty { fields.append("help=\(quoted(help))") }
            // SwiftUI's nodes answer the protocol's methods without declaring
            // the protocol, so the non-object answers are read through the
            // method itself.
            if depth > 0, flag(element, "isAccessibilityEnabled") == false { fields.append("disabled") }
            if flag(element, "isAccessibilitySelected") == true { fields.append("selected") }
            let actions = (get(element, "accessibilityActionNames") as? [Any] ?? [])
                .map { text($0) }
                .filter { $0 != "AXScrollToVisible" && $0 != "AXShowMenu" }
            if !actions.isEmpty { fields.append("actions=\(actions.joined(separator: ","))") }
            if let frame = rect(element, "accessibilityFrame") {
                // Screen coordinates, bottom-up; the render reads top-down.
                let x = frame.minX - origin.minX
                let y = origin.maxY - frame.maxY
                fields.append(String(format: "frame=(%.0f,%.0f %.0fx%.0f)", x, y, frame.width, frame.height))
            }
            lines.append(String(repeating: "  ", count: depth) + fields.joined(separator: " "))
            for child in children(of: element) { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func rect(_ element: NSObject, _ name: String) -> NSRect? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(element.method(for: selector), to: Getter.self)(element, selector)
    }

    private static func flag(_ element: NSObject, _ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(element.method(for: selector), to: Getter.self)(element, selector)
    }


    /// An object-returning accessibility getter, sent as a message so that
    /// whatever type comes back is inspected rather than trusted: SwiftUI's
    /// elements answer some of these with numbers where Swift expects strings.
    private static func get(_ element: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    private static func text(_ value: Any?) -> String {
        switch value {
        case nil: return ""
        case let string as String: return string
        case let attributed as NSAttributedString: return attributed.string
        case let number as NSNumber: return number.stringValue
        default: return String(describing: value!)
        }
    }

    private static func children(of element: NSObject) -> [NSObject] {
        (get(element, "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
    }

    private static func quoted(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Presses the first element whose label or title matches, the way an
    /// assistive client would: an accessibility action, in-process. No event
    /// is synthesized and nothing outside the test can see it.
    @discardableResult
    static func press(_ name: String, in root: NSView) -> Bool {
        func find(_ element: NSObject, depth: Int) -> NSObject? {
            guard depth < 40 else { return nil }
            let label = text(get(element, "accessibilityLabel"))
            let title = text(get(element, "accessibilityTitle"))
            if label == name || title == name,
               element.responds(to: NSSelectorFromString("accessibilityPerformPress")) { return element }
            for child in children(of: element) {
                if let hit = find(child, depth: depth + 1) { return hit }
            }
            return nil
        }
        guard let target = find(root, depth: 0) else {
            labTrace("press: nothing labelled \(name)")
            return false
        }
        return flag(target, "accessibilityPerformPress") ?? false
    }
}


// MARK: - Photographer

/// Renders one state across a set of variants and files every picture.
@MainActor
struct LabPhotographer {
    let session: LabSession
    let surface: String

    /// - Parameter build: builds the view *after* the variant is in place, so
    ///   width, language and accessibility settings are read as the app reads
    ///   them: at construction.
    func shoot(
        _ state: String,
        variants: [LabVariant],
        size: CGSize,
        settle: TimeInterval = 0.15,
        defaults: [String: Any] = [:],
        notes: String? = nil,
        interact: ((NSView) -> Void)? = nil,
        build: (LabVariant) async throws -> AnyView
    ) async throws {
        for variant in variants {
            labTrace("shoot \(surface)/\(state) \(variant.name): apply")
            session.apply(variant, defaults: defaults)
            labTrace("build")
            let view = try await build(variant)
            labTrace("render")
            guard let shot = await LabRenderer.render(view, size: size, variant: variant, settle: settle, interact: interact) else {
                XCTFail("\(surface)/\(state) \(variant.name) did not render")
                continue
            }
            let relative = "\(surface)/\(state)__\(variant.name).png"
            try LabRenderer.write(shot.rep, to: session.root.appendingPathComponent(relative))
            var a11y: String?
            if let tree = shot.accessibility {
                let path = "a11y/\(surface)/\(state)__\(variant.name).txt"
                let url = session.root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try tree.write(to: url, atomically: true, encoding: .utf8)
                a11y = path
            }
            session.manifest.add(LabRecord(
                surface: surface, state: state, variant: variant.name, backend: variant.backend.rawValue,
                width: Int(size.width), height: Int(size.height), scale: Int(LabRenderer.scale),
                path: relative, a11y: a11y, notes: notes
            ))
        }
    }
}

// MARK: - Contact sheets

@MainActor
enum LabContactSheet {
    static let columns = 4
    static let thumbWidth: CGFloat = 380
    static let perPage = 32

    static func write(surface: String, records: [LabRecord], root: URL) throws {
        let sorted = records.sorted { ($0.state, $0.variant) < ($1.state, $1.variant) }
        let pages = stride(from: 0, to: sorted.count, by: perPage).map { Array(sorted[$0..<min($0 + perPage, sorted.count)]) }
        for (index, page) in pages.enumerated() {
            let cells: [(String, NSImage)] = page.compactMap { record in
                guard let image = NSImage(contentsOf: root.appendingPathComponent(record.path)) else { return nil }
                return ("\(record.state) · \(record.variant)", image)
            }
            let sheet = Sheet(title: "\(surface) — \(index + 1)/\(pages.count)", cells: cells)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 1
            guard let cg = renderer.cgImage else { continue }
            let suffix = pages.count > 1 ? "-\(index + 1)" : ""
            try LabRenderer.write(NSBitmapImageRep(cgImage: cg),
                                  to: root.appendingPathComponent("contact-sheets/\(surface)\(suffix).png"))
        }
    }

    private struct Sheet: View {
        let title: String
        let cells: [(String, NSImage)]

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(LabContactSheet.thumbWidth), spacing: 16), count: LabContactSheet.columns),
                          alignment: .leading, spacing: 16) {
                    ForEach(cells.indices, id: \.self) { index in
                        let image = cells[index].1
                        let aspect = image.size.height / max(image.size.width, 1)
                        VStack(alignment: .leading, spacing: 4) {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: LabContactSheet.thumbWidth, height: LabContactSheet.thumbWidth * aspect)
                                .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                            Text(cells[index].0)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(20)
            .background(Color(white: 0.12))
        }
    }
}
