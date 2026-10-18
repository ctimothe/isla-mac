import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

// MARK: - The accessibility probe
//
// What an assistive client would find in a view, read in-process and offscreen
// so that it runs in the gate. The visual lab already walks the tree, but it is
// gated on ISLA_VISUAL_OUT, renders a bitmap for every case, and never read
// custom (named) actions — so no accessibility fix had a failing test that
// `./scripts/check` would run. This is the lab's hosting recipe without the
// bitmap and without `LabVariant`, which pairs with a session that skips
// without the environment variable.
//
// Nothing here drives the desktop: the window is created and never ordered
// in, no event is posted, VoiceOver is never involved, and a press is the
// element's own accessibility action performed in-process.

/// One element of the tree, as an assistive client sees it.
///
/// A snapshot: the values are read once, when the tree is walked. The element
/// itself is kept so that `press()` and `perform(named:)` act on the live
/// view, and every node keeps the hosting window alive — SwiftUI's elements
/// answer nothing once their hosting view is gone.
@MainActor
struct AXNode {
    var role: String
    var subrole: String
    var label: String
    var title: String
    var value: String
    var help: String
    var enabled: Bool
    var selected: Bool
    /// Points from the hosting window's top-left corner, top-down.
    var frame: CGRect?
    /// The standard actions (`AXPress`, `AXIncrement`, …), less the two every
    /// element carries and nobody looks for.
    var actionNames: [String]
    /// The names of the element's `NSAccessibilityCustomAction`s — what
    /// SwiftUI's `accessibilityAction(named:)` vends and VoiceOver lists under
    /// its Actions rotor.
    var customActions: [String]
    var children: [AXNode]

    let element: NSObject
    fileprivate let host: AXProbe.Host

    // MARK: Queries

    /// This node and every node under it, depth-first, parents first.
    var flattened: [AXNode] { [self] + children.flatMap(\.flattened) }

    func all(where match: (AXNode) -> Bool) -> [AXNode] { flattened.filter(match) }

    func all(role: String) -> [AXNode] { all { $0.role == role } }

    /// The first node, depth-first, whose label or title is `label`.
    func first(label: String) -> AXNode? {
        flattened.first { $0.label == label || $0.title == label }
    }

    // MARK: Actions

    /// Performs the element's standard press, as VoiceOver's VO-Space does.
    @discardableResult
    func press() -> Bool {
        AXProbe.flag(element, "accessibilityPerformPress") ?? false
    }

    /// Performs the first custom action called `name` on this node or under
    /// it. SwiftUI's actions carry a handler; an AppKit one may carry a target
    /// and selector instead, and both are honoured.
    @discardableResult
    func perform(named name: String) -> Bool {
        for node in flattened {
            guard let action = AXProbe.customActionObjects(node.element).first(where: { $0.name == name }) else { continue }
            if let handler = action.handler { return handler() }
            if let target = action.target as? NSObject, let selector = action.selector, target.responds(to: selector) {
                _ = target.perform(selector, with: action)
                return true
            }
            return false
        }
        return false
    }

    /// The same view walked again after `settle` — for reading what a press
    /// or a state change left behind, since a node is a snapshot.
    func reread(settle: TimeInterval = 0.15) async -> AXNode {
        await AXProbe.wait(settle)
        host.hosting.layoutSubtreeIfNeeded()
        _ = host.hosting.accessibilityChildren()
        await AXProbe.wait(0.02)
        return AXProbe.walk(host.hosting, host: host, depth: 0)
    }

    // MARK: Description

    /// The subtree as indented lines, for an assertion's message: a failing
    /// count is useless without the tree it was counted in.
    var dump: String { lines(depth: 0).joined(separator: "\n") }

    private func lines(depth: Int) -> [String] {
        var fields = ["[\(role.isEmpty ? "?" : role)\(subrole.isEmpty ? "" : "/\(subrole)")]"]
        if !label.isEmpty { fields.append("label=\"\(label)\"") }
        if !title.isEmpty { fields.append("title=\"\(title)\"") }
        if !value.isEmpty { fields.append("value=\"\(value)\"") }
        if !help.isEmpty { fields.append("help=\"\(help)\"") }
        if !enabled { fields.append("disabled") }
        if selected { fields.append("selected") }
        if !actionNames.isEmpty { fields.append("actions=\(actionNames.joined(separator: ","))") }
        if !customActions.isEmpty { fields.append("custom=\(customActions.joined(separator: ","))") }
        let line = String(repeating: "  ", count: depth) + fields.joined(separator: " ")
        return [line] + children.flatMap { $0.lines(depth: depth + 1) }
    }
}

@MainActor
enum AXProbe {
    /// What keeps a probed view alive: the never-ordered window and the
    /// hosting view inside it.
    final class Host {
        let window: NSWindow
        let hosting: NSView
        init(window: NSWindow, hosting: NSView) {
            self.window = window
            self.hosting = hosting
        }
    }

    private static var requestedEnhancedInterface = false

    /// Hosts `view` offscreen and returns its accessibility tree, rooted at
    /// the hosting view.
    ///
    /// Fails the calling test — never skips it — when the tree comes back
    /// empty: if a future macOS stops building SwiftUI's tree for a window
    /// that is never ordered in, every accessibility test built on this would
    /// otherwise pass by finding nothing to complain about.
    static func tree<V: View>(
        of view: V, size: CGSize, settle: TimeInterval = 0.15,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> AXNode {
        let host = present(view, size: size)
        return await read(host, settle: settle, file: file, line: line)
    }

    /// Hosts `view` offscreen and lays it out, without reading it yet: for a
    /// test that changes what the view shows and reads the tree before and
    /// after (a surface swapped in an open island), which `tree` — one view,
    /// one reading — cannot.
    static func present<V: View>(_ view: V, size: CGSize) -> Host {
        requestEnhancedInterface()
        let window = NSWindow(
            contentRect: NSRect(x: -40_000, y: -40_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        // Every Isla window is a `NotchPanel`, which forces dark Aqua.
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return Host(window: window, hosting: hosting)
    }

    /// The tree of a view `present` hosts, as it is `settle` seconds from now.
    static func read(
        _ host: Host, settle: TimeInterval = 0.15,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> AXNode {
        let hosting = host.hosting
        // The first question is what makes SwiftUI build the tree, and custom
        // actions are vended only once it is built; the answer is there a
        // run-loop turn later. Asking once and reading at once found an empty
        // tree in the lab.
        _ = hosting.accessibilityChildren()
        await wait(settle)
        _ = hosting.accessibilityChildren()
        await wait(0.02)
        hosting.layoutSubtreeIfNeeded()

        let root = walk(hosting, host: host, depth: 0)
        if root.children.isEmpty {
            XCTFail("the accessibility tree came back empty; SwiftUI did not build it offscreen", file: file, line: line)
        }
        return root
    }

    /// SwiftUI builds its accessibility tree only once an assistive client has
    /// asked for it. Raising the application's enhanced-UI attribute is that
    /// request, made in-process; nothing outside the test process sees it.
    private static func requestEnhancedInterface() {
        guard !requestedEnhancedInterface else { return }
        requestedEnhancedInterface = true
        _ = NSApplication.shared
        _ = NSApp.perform(NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:"),
                          with: NSNumber(value: true))
    }

    /// Lets the main run loop turn without nesting one: the test awaits, and
    /// XCTest keeps the main run loop running underneath.
    static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    // MARK: Reading

    fileprivate static func walk(_ element: NSObject, host: Host, depth: Int) -> AXNode {
        let origin = host.window.frame
        var frame: CGRect?
        if let screen = rect(element, "accessibilityFrame") {
            // Screen coordinates, bottom-up; the tests read top-down from the
            // window's corner, as a layout is written.
            frame = CGRect(x: screen.minX - origin.minX, y: origin.maxY - screen.maxY,
                           width: screen.width, height: screen.height)
        }
        // Bounded like the lab's dump: a cycle in a broken tree must end the
        // walk, not the test run.
        let children = depth < 40
            ? (get(element, "accessibilityChildren") as? [Any] ?? [])
                .compactMap { $0 as? NSObject }
                .map { walk($0, host: host, depth: depth + 1) }
            : []
        return AXNode(
            role: text(get(element, "accessibilityRole")),
            subrole: text(get(element, "accessibilitySubrole")),
            label: text(get(element, "accessibilityLabel")),
            title: text(get(element, "accessibilityTitle")),
            value: text(get(element, "accessibilityValue")),
            help: text(get(element, "accessibilityHelp")),
            // Read only under the root, as the lab's dump does: the root is
            // the hosting view, not a control.
            enabled: depth == 0 ? true : (flag(element, "isAccessibilityEnabled") ?? true),
            selected: flag(element, "isAccessibilitySelected") ?? false,
            frame: frame,
            actionNames: actionNames(element, isRoot: depth == 0),
            customActions: customActionObjects(element).map(\.name),
            children: children,
            element: element,
            host: host
        )
    }

    /// The standard actions, keyed by the protocol method that performs each.
    private static let performers: [(selector: String, action: NSAccessibility.Action)] = [
        ("accessibilityPerformPress", .press),
        ("accessibilityPerformIncrement", .increment),
        ("accessibilityPerformDecrement", .decrement),
        ("accessibilityPerformConfirm", .confirm),
        ("accessibilityPerformCancel", .cancel),
        ("accessibilityPerformPick", .pick),
        ("accessibilityPerformRaise", .raise),
        ("accessibilityPerformDelete", .delete),
        ("accessibilityPerformShowAlternateUI", .showAlternateUI),
        ("accessibilityPerformShowDefaultUI", .showDefaultUI),
    ]

    /// The standard actions an assistive client would be offered.
    ///
    /// Asking the element for `accessibilityActionNames` is not enough:
    /// SwiftUI's nodes answer it with an empty array, a plain `Button`
    /// included, and the first run of this probe reported no AXPress on the
    /// Copy button. Under the NSAccessibility protocol an element's actions
    /// are the `accessibilityPerform…` methods it implements *and* allows
    /// through `isAccessibilitySelectorAllowed:` — SwiftUI's node implements
    /// every one of them and allows only what the view declared (a Button
    /// allows the press, a Text with a tap gesture allows nothing, a Slider
    /// allows increment and decrement). Both answers are merged here. The
    /// root is the hosting view, which allows every selector by default, so
    /// only its own list is read.
    private static func actionNames(_ element: NSObject, isRoot: Bool) -> [String] {
        var names = (get(element, "accessibilityActionNames") as? [Any] ?? []).map { text($0) }
        if !isRoot {
            for performer in performers where !names.contains(performer.action.rawValue) {
                let selector = NSSelectorFromString(performer.selector)
                guard element.responds(to: selector), allows(element, selector) else { continue }
                names.append(performer.action.rawValue)
            }
        }
        // Every element carries these two and no test looks for them; the
        // lab's dump drops them for the same reason.
        return names.filter { $0 != "AXScrollToVisible" && $0 != NSAccessibility.Action.showMenu.rawValue }
    }

    private static func allows(_ element: NSObject, _ selector: Selector) -> Bool {
        let query = NSSelectorFromString("isAccessibilitySelectorAllowed:")
        guard element.responds(to: query) else { return true }
        typealias Query = @convention(c) (AnyObject, Selector, Selector) -> Bool
        return unsafeBitCast(element.method(for: query), to: Query.self)(element, query, selector)
    }

    fileprivate static func customActionObjects(_ element: NSObject) -> [NSAccessibilityCustomAction] {
        (get(element, "accessibilityCustomActions") as? [Any] ?? []).compactMap { $0 as? NSAccessibilityCustomAction }
    }

    // SwiftUI's nodes answer the protocol's methods without declaring the
    // protocol, so every answer is read by sending the message itself, and
    // whatever type comes back is inspected rather than trusted: some of
    // these come back as numbers where Swift expects strings.

    fileprivate static func get(_ element: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    fileprivate static func flag(_ element: NSObject, _ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(element.method(for: selector), to: Getter.self)(element, selector)
    }

    private static func rect(_ element: NSObject, _ name: String) -> NSRect? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(element.method(for: selector), to: Getter.self)(element, selector)
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
}

// MARK: - Fixtures

/// Session stores cut off from everything of the person's, for a probed pane.
///
/// Mirrors the lab's `makeStores`: a private defaults suite named by a UUID,
/// a uniquely named private pasteboard, a temporary folder for every path,
/// and a media controller cut from real players. The xctest defaults domain
/// has leaked settings into the suite before, and a test that reaches a real
/// player or the general pasteboard reaches whatever the owner is doing.
@MainActor
final class ProbeStores {
    let stores: NotchStores
    let suiteName: String
    let suite: UserDefaults
    let pasteboard: NSPasteboard
    let temp: URL
    let paths: AppPaths

    fileprivate init() {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-ax-probe-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        suiteName = "com.ctimothe.isla.axprobe.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        paths = AppPaths(
            supportDirectory: temp.appendingPathComponent("support", isDirectory: true),
            screenshotDirectory: temp.appendingPathComponent("pictures", isDirectory: true)
        )
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.ctimothe.isla.axprobe.\(UUID().uuidString)"))

        let clipboard = ClipboardStore(pasteboard: pasteboard)
        clipboard.wantsImages = { false }
        stores = NotchStores(
            lyricsEnabled: { false },
            localLyricsDirectory: temp.appendingPathComponent("lyrics", isDirectory: true),
            shelf: ShelfStore(defaults: suite),
            clipboard: clipboard,
            screenshotVault: ScreenshotVault(paths: paths),
            translator: Translator(defaults: suite, preferredLanguages: ["ru"]),
            privacy: PrivacyMode(defaults: suite),
            // Reads the private suite and can translate nothing: a probe must
            // never reach the network or a real model.
            lyricTranslation: LyricTranslation(defaults: suite, backend: .inert, preferredLanguages: ["en"])
        )
        stores.media.isolateFromPlayers()
        stores.media.monotonicNow = { 50_000 }
        stores.media.lyricsShown = { false }
        stores.media.precisionPositionFetcher = { reply in reply(nil) }
        stores.translator.capabilitiesOverride = { _ in Translator.Capabilities() }
    }

    /// Puts entries in the clipboard history the way a poll would, newest
    /// last, with fixed times, without the pasteboard being involved.
    func record(_ payloads: [ClipItem.Payload], into clipboard: ClipboardStore) {
        let start = Date(timeIntervalSince1970: 1_791_712_800) // 2026-10-11 08:00 UTC
        for (index, payload) in payloads.enumerated() {
            clipboard.record(ClipItem(payload: payload, date: start.addingTimeInterval(Double(index) * 60)))
        }
    }

    /// Removes the suite, the pasteboard and the folder. Call it from a
    /// `defer` in the test that made the stores.
    func release() {
        stores.clipboard.stop()
        pasteboard.releaseGlobally()
        suite.removePersistentDomain(forName: suiteName)
        UserDefaults.standard.removeSuite(named: suiteName)
        try? FileManager.default.removeItem(at: temp)
    }
}

@MainActor
enum ProbeFixtures {
    static func isolatedStores() -> ProbeStores { ProbeStores() }
}
