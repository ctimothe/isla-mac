import AppKit
import Combine

/// The three accessibility display settings that change how this app should be
/// drawn, and a notification when any of them changes.
///
/// An app built on a translucent material has to answer Reduce Transparency —
/// Apple's own surfaces go opaque when it is on, and one that stays translucent
/// is the only frosted thing left on the screen. Increase Contrast is the same
/// bargain for edges: the system draws a defined border round controls that
/// otherwise rely on a material to separate them from what is behind.
///
/// Read from `NSWorkspace` rather than from SwiftUI's environment because the
/// environment carries only Reduce Motion on macOS, and because the panel is
/// drawn from AppKit as much as from SwiftUI.
@MainActor
final class SystemAppearance: ObservableObject {
    static let shared = SystemAppearance()

    @Published private(set) var reduceTransparency: Bool
    @Published private(set) var increaseContrast: Bool
    @Published private(set) var reduceMotion: Bool

    private var observer: Any?

    private init() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion

        // One notification covers all three; the system does not say which
        // changed, so all three are re-read.
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// Pins the settings a test describes, instead of reading them from
    /// whichever Mac runs it. `resetForTests()` hands them back to the system.
    ///
    /// The glass routing tests asserted the Reduce-Transparency-*off* branch
    /// while reading the live setting, so they passed on a desk and failed on
    /// the CI image, which runs with Reduce Transparency on — the same host
    /// dependence `RecordingPickup.captureFolder(preferencesFile:)` was given a
    /// parameter to escape. A test that means "with the setting off" should say
    /// so, and then it also gets to say what happens with it on.
    func overrideForTests(
        reduceTransparency: Bool? = nil, increaseContrast: Bool? = nil, reduceMotion: Bool? = nil
    ) {
        if let reduceTransparency { self.reduceTransparency = reduceTransparency }
        if let increaseContrast { self.increaseContrast = increaseContrast }
        if let reduceMotion { self.reduceMotion = reduceMotion }
    }

    func resetForTests() { refresh() }

    private func refresh() {
        let workspace = NSWorkspace.shared
        // Assigned only when different: `@Published` never compares, and this
        // notification fires for changes to settings none of these track.
        let transparency = workspace.accessibilityDisplayShouldReduceTransparency
        let contrast = workspace.accessibilityDisplayShouldIncreaseContrast
        let motion = workspace.accessibilityDisplayShouldReduceMotion
        if reduceTransparency != transparency { reduceTransparency = transparency }
        if increaseContrast != contrast { increaseContrast = contrast }
        if reduceMotion != motion { reduceMotion = motion }
    }
}
