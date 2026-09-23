import AppKit
import OSLog
import ServiceManagement

/// What someone can paste into a bug report without knowing what matters.
///
/// Before this there was no way for anyone but the owner to see why the app
/// misbehaved. There was no crash reporter and no log subsystem, and the
/// `DI_*` hooks only work for someone launching the binary from a terminal.
/// A report from a stranger said "the island is empty", and nothing in it
/// could be reproduced.
///
/// It holds the state that has decided every past bug: version, macOS, model,
/// displays and notches, how Now Playing is being read and why not, whether
/// the download quarantine or the signature could be refusing the helper, the
/// settings that change behaviour, the shortcuts, and Isla's own log for the
/// last half hour. It holds nothing the user played, copied or translated.
/// Settings reads no content, and the log redacts every value not marked
/// public (see `Log`).
enum Diagnostics {
    struct Display: Equatable {
        var name: String
        var points: CGSize
        var scale: CGFloat
        var hasNotch: Bool
    }

    struct Snapshot {
        var version: String
        var build: String
        var macOS: String
        var model: String
        var architecture: String
        var displays: [Display]
        var nowPlaying: String
        var helperPresent: Bool
        var appQuarantined: Bool
        var helperQuarantined: Bool
        var signature: String
        var lockScreenSPI: Bool
        var settings: [(String, String)]
        var shortcuts: [(String, String)]
        var log: [String]
    }

    /// The report as text. Pure, so a test can hold its shape.
    static func render(_ snapshot: Snapshot) -> String {
        var lines: [String] = []
        lines.append("Isla \(snapshot.version) (\(snapshot.build))")
        lines.append("macOS \(snapshot.macOS), \(snapshot.model), \(snapshot.architecture)")
        lines.append("")
        lines.append("Displays")
        if snapshot.displays.isEmpty { lines.append("  none") }
        for display in snapshot.displays {
            let size = "\(Int(display.points.width))×\(Int(display.points.height)) pt @\(Int(display.scale))x"
            lines.append("  \(display.name): \(size), \(display.hasNotch ? "notch" : "no notch")")
        }
        lines.append("")
        lines.append("Now Playing")
        lines.append("  route: \(snapshot.nowPlaying)")
        lines.append("  helper in bundle: \(yesNo(snapshot.helperPresent))")
        lines.append("  app quarantined: \(yesNo(snapshot.appQuarantined))")
        lines.append("  helper quarantined: \(yesNo(snapshot.helperQuarantined))")
        lines.append("  signature: \(snapshot.signature)")
        lines.append("  lock-screen SPI: \(snapshot.lockScreenSPI ? "available" : "missing")")
        lines.append("")
        lines.append("Settings")
        for (name, value) in snapshot.settings { lines.append("  \(name): \(value)") }
        lines.append("")
        lines.append("Shortcuts")
        for (name, value) in snapshot.shortcuts { lines.append("  \(name): \(value)") }
        lines.append("")
        lines.append("Log (last 30 minutes)")
        if snapshot.log.isEmpty { lines.append("  nothing logged") }
        lines.append(contentsOf: snapshot.log.map { "  " + $0 })
        return lines.joined(separator: "\n") + "\n"
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    // MARK: - Reading the live app

    @MainActor
    static func current(media: MediaController, hotKeys: HotKeyCenter? = nil, includeLog: Bool = true) -> Snapshot {
        let hotKeys = hotKeys ?? .shared
        let info = Bundle.main.infoDictionary ?? [:]
        let helper = Bundle.main.path(forResource: ProductIdentity.helperResourceName, ofType: "dylib")
        let nowPlaying = media.fallbackReason.map { "Music and Spotify only (\($0.rawValue))" } ?? "Now Playing"
        let defaults = UserDefaults.standard
        let settings: [(String, String)] = [
            ("Show Lyrics", onOff(NotchViewModel.showLyricsEnabled)),
            ("Look Up Lyrics Online", onOff(NotchViewModel.onlineLyricsEnabled)),
            ("Translate Online", onOff(NotchViewModel.onlineTranslationEnabled)),
            ("Music Only", onOff(NotchViewModel.musicOnlyEnabled)),
            ("Open on Hover", onOff(NotchViewModel.opensOnHoverEnabled)),
            ("Show on Lock Screen", onOff(NotchViewModel.showOnLockScreenEnabled)),
            ("Hide from Screen Recording", onOff(NotchViewModel.hideFromCaptureEnabled)),
            ("Check for Updates Automatically", onOff(UpdateCheck.automaticEnabled)),
            ("Launch at Login", SMAppService.mainApp.status == .enabled ? "on" : "off"),
            ("Panel Width", "\(Int(NotchViewModel.bodyWidth)) pt"),
            ("Drawn Glass", onOff(defaults.bool(forKey: "drawnGlass"))),
        ]
        let shortcuts = HotKeyAction.allCases.map { action -> (String, String) in
            var value = hotKeys.bindings[action]?.displayString ?? "none"
            if hotKeys.refused.contains(action) { value += " (refused)" }
            return (action.rawValue, value)
        }
        return Snapshot(
            version: (info["CFBundleShortVersionString"] as? String) ?? "dev",
            build: (info["CFBundleVersion"] as? String) ?? "dev",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            model: sysctlString("hw.model") ?? "unknown",
            architecture: architecture,
            displays: NSScreen.screens.map {
                Display(
                    name: $0.localizedName,
                    points: $0.frame.size,
                    scale: $0.backingScaleFactor,
                    hasNotch: $0.safeAreaInsets.top > 0
                )
            },
            nowPlaying: nowPlaying,
            helperPresent: helper != nil,
            appQuarantined: isQuarantined(Bundle.main.bundlePath),
            helperQuarantined: helper.map(isQuarantined) ?? false,
            signature: signature(of: Bundle.main.bundleURL),
            lockScreenSPI: SkyLight.shared != nil,
            settings: settings,
            shortcuts: shortcuts,
            log: includeLog ? recentLog() : []
        )
    }

    /// Copies the report, marked transient so Isla's own clipboard history and
    /// other clipboard managers leave it out. It is a few hundred lines meant
    /// for one paste, not something to keep.
    @MainActor
    static func copyToPasteboard(media: MediaController) {
        let text = render(current(media: media))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
    }

    /// The bug form on GitHub, which asks for this report.
    static let reportURL = URL(string: "\(ProductIdentity.homepage)/issues/new?template=bug_report.yml")!

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return sysctlInt("sysctl.proc_translated") == 1 ? "x86_64 (Rosetta)" : "x86_64"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// Whether macOS still holds the download quarantine on `path`. A
    /// quarantined helper dylib is the usual reason the reader is refused.
    static func isQuarantined(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    /// "ad-hoc", or the Developer ID team that signed the bundle.
    private static func signature(of url: URL) -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return "unsigned"
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any]
        else { return "unreadable" }
        if let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String { return "Developer ID (\(team))" }
        return "ad-hoc"
    }

    /// Isla's own entries for the last half hour, newest last, at most 300.
    /// Reading the current process's log needs no entitlement.
    static func recentLog(minutes: Double = 30, limit: Int = 300) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return [] }
        let start = store.position(date: Date().addingTimeInterval(-minutes * 60))
        let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
        guard let entries = try? store.getEntries(at: start, matching: predicate) else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)")
        }
        return Array(lines.suffix(limit))
    }
}
