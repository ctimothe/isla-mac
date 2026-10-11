import SwiftUI
import XCTest
@testable import IslaKit

/// Settings as VoiceOver reads it (H-009, H-024).
///
/// The 2026-10-11 dump of the pane's first viewport found a symbol's system
/// name before rows ("Rectangle With A Filled Top-Third Inset", "Skip Slide",
/// "Circle With The Left Half Filled"), slider values with no unit ("560",
/// "0"), section titles that were plain uppercase text with nothing for the
/// headings rotor to land on, and the lock card's Glass and Card Size choices
/// as loose buttons rather than one choice of several.
@MainActor
final class SettingsAccessibilityTests: XCTestCase {
    /// The nine section titles, in the order the pane draws them. Privacy
    /// second since SET-03 (H-003): see `SettingsWayfindingTests`.
    private static let sectionTitles = [
        "General", "Privacy", "Keyboard Shortcuts", "Music", "Lock Screen",
        "Translate", "Spotify", "Screenshots", "Application",
    ]

    private func probePane(height: CGFloat = 1400) async -> (AXNode, ProbeStores) {
        let isolated = ProbeFixtures.isolatedStores()
        let stores = isolated.stores
        let pane = SettingsPane(
            shelf: stores.shelf, screenshotVault: stores.screenshotVault, lyrics: stores.lyrics,
            media: stores.media, localLyrics: stores.localLyricsLibrary, privacy: stores.privacy,
            hotKeys: HotKeyCenter(defaults: isolated.suite, registrar: { _, _ in nil }),
            updates: UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) })
        )
        let root = await AXProbe.tree(of: pane, size: CGSize(width: 488, height: height))
        return (root, isolated)
    }

    /// Every row's glyph is decoration: the row's title already says what the
    /// row is, and the glyph's system name said something else ("Skip Slide"
    /// for Card Size, "Audiobook" for headphones), one extra stop per row.
    func testNoRowSpeaksASymbolName() async {
        let (root, isolated) = await probePane()
        defer { isolated.release() }
        XCTAssertEqual(root.all(role: "AXImage").map(\.label), [], root.dump)
    }

    /// Each section title is a heading named in title case, so the rotor can
    /// jump between the nine of them and VoiceOver does not spell out the
    /// drawn small caps.
    func testSectionTitlesAreHeadings() async {
        let (root, isolated) = await probePane()
        defer { isolated.release() }
        let headings = root.all { $0.role == "AXHeading" }
        XCTAssertEqual(headings.map(\.label), Self.sectionTitles.map { localized($0) }, root.dump)
        XCTAssertTrue(root.all { $0.value == "GENERAL" || $0.label == "GENERAL" }.isEmpty,
                      "the drawn uppercase is still what is read\n\(root.dump)")
    }

    /// A slider's value says what it counts. "560" alone is a number with no
    /// meaning; the drawn "560 pt" beside it was a second stop, read apart
    /// from the slider it describes.
    ///
    /// What VoiceOver speaks for a slider is its value description, when
    /// there is one, and the bare number otherwise; SwiftUI puts a declared
    /// `accessibilityValue` there and leaves AXValue numeric, as AppKit's own
    /// sliders do. The number itself staying a number is right: it is what
    /// increment and decrement move.
    func testSlidersCarryUnits() async {
        // The delay slider speaks why it is dimmed while Show Lyrics is off
        // (SET-08), so the value asserted below is only the bare direction
        // with the switch on. The test used to inherit the switch from
        // whatever the runner's defaults held — a test machine that had
        // ever turned lyrics on passed, a clean one failed — so it pins it.
        let defaults = UserDefaults.standard
        let had = defaults.object(forKey: NotchViewModel.showLyricsKey)
        defer {
            if let had { defaults.set(had, forKey: NotchViewModel.showLyricsKey) }
            else { defaults.removeObject(forKey: NotchViewModel.showLyricsKey) }
        }
        defaults.set(true, forKey: NotchViewModel.showLyricsKey)
        let (root, isolated) = await probePane()
        defer { isolated.release() }
        let sliders = root.all(role: "AXSlider")
        let width = sliders.first { $0.label == localized("Panel Width") }
        XCTAssertEqual(width.map(Self.spoken), localized("%d points", Int(NotchViewModel.bodyWidth)), root.dump)
        XCTAssertEqual(width.map(Self.spoken), "\(Int(NotchViewModel.bodyWidth)) points",
                       "the English table reads it in full")
        let delay = sliders.first { $0.label == localized("Lyric Delay") }
        // The delay speaks a direction rather than a sign (LY-16): see
        // `LyricDelayCopyTests`.
        XCTAssertEqual(delay.map(Self.spoken), LyricDelayCopy.value(isolated.stores.lyrics.userOffset), root.dump)
        // The drawn title and the drawn figure are not stops of their own:
        // the slider already speaks both.
        for drawn in [localized("Panel Width"), localized("Lyric Delay"),
                      localized("%d pt", Int(NotchViewModel.bodyWidth)),
                      localized("%+.2fs", isolated.stores.lyrics.userOffset)] {
            XCTAssertTrue(root.all { $0.role == "AXStaticText" && ($0.value == drawn || $0.label == drawn) }.isEmpty,
                          "\(drawn) is read twice\n\(root.dump)")
        }
    }

    /// The hover delay counts seconds, unsigned. Hosted on its own: the row
    /// is only in the pane while Open on Hover is on, and that switch lives
    /// in the test runner's own defaults.
    func testTheHoverDelaySaysSeconds() async {
        let root = await AXProbe.tree(
            of: SliderHarness(value: 0.25, title: "Hover Delay", spoken: { localized("%.2f seconds", $0) }),
            size: CGSize(width: 440, height: 26)
        )
        let slider = root.all(role: "AXSlider").first
        XCTAssertEqual(slider?.label, "Hover Delay", root.dump)
        XCTAssertEqual(slider.map(Self.spoken), "0.25 seconds", root.dump)
    }

    /// Glass and Card Size are each one choice of several: a radio group
    /// named by the row, one radio button per option, exactly one of them on,
    /// and a press on another moves the selection. They were loose buttons,
    /// with "selected" the only hint they belonged together (owner decision 4).
    /// The capsules stay drawn; only what an assistive client finds changed.
    func testCardStyleIsARadioGroup() async {
        var picked: [NotchViewModel.LockCardStyle] = []
        let root = await AXProbe.tree(
            of: ChoiceHarness(initial: .glass) { picked.append($0) },
            size: CGSize(width: 440, height: 26)
        )
        let groups = root.all(role: "AXRadioGroup")
        XCTAssertEqual(groups.count, 1, root.dump)
        guard let group = groups.first else { return }
        XCTAssertEqual(group.label, localized("Glass"), root.dump)
        let buttons = group.all(role: "AXRadioButton")
        XCTAssertEqual(buttons.map(Self.name),
                       NotchViewModel.LockCardStyle.allCases.map(\.title), root.dump)
        XCTAssertEqual(buttons.filter { $0.value == "1" }.count, 1, root.dump)
        XCTAssertEqual(buttons.first { $0.value == "1" }.map(Self.name),
                       NotchViewModel.LockCardStyle.glass.title, root.dump)
        XCTAssertTrue(root.all(role: "AXImage").isEmpty, root.dump)

        guard let solid = buttons.first(where: { Self.name($0) == NotchViewModel.LockCardStyle.solid.title }) else {
            return XCTFail("no Solid option\n\(root.dump)")
        }
        XCTAssertTrue(solid.press(), "Solid refused the press\n\(root.dump)")
        let after = await root.reread()
        XCTAssertEqual(picked, [.solid])
        let on = after.all(role: "AXRadioButton").filter { $0.value == "1" }
        XCTAssertEqual(on.map(Self.name), [NotchViewModel.LockCardStyle.solid.title], after.dump)
    }

    /// A VoiceOver step on Panel Width or Hover Delay commits, once per step.
    ///
    /// The width is applied only when the slider reports editing ended,
    /// because applying it rebuilds the panel (audit A7). The 2026-10-11
    /// exhaustion round read that as "a VoiceOver increment never commits":
    /// a step is not a drag. Driven through the slider's own accessibility
    /// increment here, SwiftUI brackets the step as editing began, one
    /// write, editing ended, so the step commits by itself, at once and
    /// once. This holds both halves: a SwiftUI that stopped bracketing would
    /// leave the step uncommitted, and one that reported the end twice would
    /// rebuild the panel twice.
    func testAVoiceOverStepCommitsTheWidth() async {
        var commits: [Double] = []
        let root = await AXProbe.tree(
            of: SliderHarness(value: 560, title: "Panel Width", range: 480...620,
                              spoken: { localized("%d points", Int($0)) }, onCommit: { commits.append($0) }),
            size: CGSize(width: 440, height: 26)
        )
        guard let slider = root.all(role: "AXSlider").first else {
            return XCTFail("no slider\n\(root.dump)")
        }
        XCTAssertTrue(Self.perform(slider.element, "accessibilityPerformIncrement"), root.dump)
        await AXProbe.wait(0.35)
        XCTAssertEqual(commits.count, 1, "the increment was not committed exactly once: \(commits)")
        XCTAssertGreaterThan(commits.first ?? 0, 560, "the commit saw the old width")

        let stepped = await root.reread(settle: 0.05)
        guard let again = stepped.all(role: "AXSlider").first else {
            return XCTFail("no slider\n\(stepped.dump)")
        }
        XCTAssertEqual(Self.spoken(again), "\(Int(commits.first ?? 0)) points", "the spoken value did not follow")
        XCTAssertTrue(Self.perform(again.element, "accessibilityPerformDecrement"), stepped.dump)
        await AXProbe.wait(0.35)
        XCTAssertEqual(commits.count, 2, "the decrement was not committed exactly once: \(commits)")
        XCTAssertEqual(commits.last ?? 0, 560, accuracy: 0.5)
    }

    /// With Show Lyrics off, Word Karaoke, Lyric Delay and Look Up Lyrics
    /// Online looked live and did nothing (M-34). They dim, and say why where
    /// a pointer or VoiceOver lands. The runner's own defaults hold the
    /// switch, as the neighbouring tests' do, and are put back.
    func testLyricsDependentsSayWhy() async {
        let defaults = UserDefaults.standard
        let had = defaults.object(forKey: NotchViewModel.showLyricsKey)
        defer {
            if let had { defaults.set(had, forKey: NotchViewModel.showLyricsKey) }
            else { defaults.removeObject(forKey: NotchViewModel.showLyricsKey) }
        }
        defaults.set(false, forKey: NotchViewModel.showLyricsKey)
        let (root, isolated) = await probePane()
        defer { isolated.release() }
        let reason = localized("Needs Show Lyrics")
        for title in ["Word Karaoke", "Look Up Lyrics Online"] {
            guard let row = root.first(label: localized(title)) else { return XCTFail("no \(title) row\n\(root.dump)") }
            XCTAssertFalse(row.enabled, "\(title) still looks live\n\(root.dump)")
            XCTAssertEqual(row.help, reason, "\(title) does not say why\n\(root.dump)")
        }
        let delay = root.all(role: "AXSlider").first { $0.label == localized("Lyric Delay") }
        XCTAssertEqual(delay?.enabled, false, root.dump)
        XCTAssertTrue(delay.map(Self.spoken)?.hasSuffix(reason) ?? false,
                      "VoiceOver hears why Lyric Delay is dimmed\n\(root.dump)")
        XCTAssertEqual(root.first(label: localized("Show Lyrics"))?.enabled, true, "the switch itself stays live")

        defaults.set(true, forKey: NotchViewModel.showLyricsKey)
        let (live, liveIsolated) = await probePane()
        defer { liveIsolated.release() }
        XCTAssertEqual(live.first(label: localized("Word Karaoke"))?.enabled, true, live.dump)
        XCTAssertEqual(live.first(label: localized("Word Karaoke"))?.help, "", "no reason when nothing is waiting")
    }

    /// Nothing in Isla said why the island moved or looked differently under
    /// Reduce Motion, Reduce Transparency or Increase Contrast.
    func testFollowingYourMacLine() async {
        let appearance = SystemAppearance.shared
        defer { appearance.resetForTests() }
        appearance.overrideForTests(reduceTransparency: false, increaseContrast: false, reduceMotion: false)
        let (none, noneIsolated) = await probePane()
        defer { noneIsolated.release() }
        XCTAssertTrue(none.all { $0.role == "AXStaticText" && $0.value.hasPrefix(localized("Following your Mac: %@", "")) }.isEmpty,
                      "the line is only there when a setting is on\n\(none.dump)")

        appearance.overrideForTests(reduceTransparency: false, increaseContrast: true, reduceMotion: true)
        let (root, isolated) = await probePane()
        defer { isolated.release() }
        let expected = localized("Following your Mac: %@",
                                 [localized("Reduce Motion"), localized("Increase Contrast")].joined(separator: ", "))
        XCTAssertEqual(expected, "Following your Mac: Reduce Motion, Increase Contrast")
        XCTAssertFalse(root.all { $0.role == "AXStaticText" && ($0.value == expected || $0.label == expected) }.isEmpty,
                       root.dump)
    }

    /// What a radio button is called: SwiftUI names a segment by its title
    /// on some releases and by its label on others.
    private static func name(_ node: AXNode) -> String {
        node.title.isEmpty ? node.label : node.title
    }

    /// What VoiceOver speaks as a node's value: the value description when
    /// the element has one, else the value. The probe's own walk reads only
    /// AXValue, which for a slider is always the bare number.
    private static func spoken(_ node: AXNode) -> String {
        let selector = NSSelectorFromString("accessibilityValueDescription")
        if node.element.responds(to: selector),
           let description = node.element.perform(selector)?.takeUnretainedValue() as? String,
           !description.isEmpty {
            return description
        }
        return node.value
    }

    private static func perform(_ element: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return false }
        typealias Perform = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(element.method(for: selector), to: Perform.self)(element, selector)
    }
}

/// One slider row over state of its own, so the row re-renders as a pane
/// would when the value moves.
private struct SliderHarness: View {
    @State var value: Double
    let title: String
    var range: ClosedRange<Double> = 0.05...1.0
    let spoken: (Double) -> String
    var onCommit: ((Double) -> Void)? = nil

    var body: some View {
        SettingsSliderRow(
            symbol: SettingsIcon.panelWidth,
            title: title,
            value: $value,
            range: range,
            drawnValue: "\(value)",
            spokenValue: spoken(value),
            commit: onCommit.map { report in { report(value) } }
        )
        .frame(width: 440, height: 26)
    }
}

/// The Glass row over state of its own.
private struct ChoiceHarness: View {
    @State var selection: NotchViewModel.LockCardStyle
    let onPick: (NotchViewModel.LockCardStyle) -> Void

    init(initial: NotchViewModel.LockCardStyle, onPick: @escaping (NotchViewModel.LockCardStyle) -> Void) {
        _selection = State(initialValue: initial)
        self.onPick = onPick
    }

    var body: some View {
        SettingsChoiceRow(
            symbol: SettingsIcon.cardStyle,
            title: localized("Glass"),
            options: NotchViewModel.LockCardStyle.allCases,
            selection: Binding(get: { selection }, set: { selection = $0; onPick($0) }),
            optionTitle: { $0.title }
        )
        .frame(width: 440, height: 26)
    }
}
