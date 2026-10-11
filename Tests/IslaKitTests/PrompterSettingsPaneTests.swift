import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

// The Prompter's Settings section (plan T9, spec 4, 5.3, 5.4, 11.7, 12.2, 15).
// Nothing here touches `UserDefaults.standard`, Application Support, a real
// timer, the microphone or a registered hot key: the settings live in an
// `InMemoryDefaults`, the library writes to nowhere, the session runs on a
// scheduler nobody advances, and the hot keys go to a registrar that registers
// nothing. The pane is read the way VoiceOver reads it (`AXProbe`).

/// Everything one pane needs, with the calls it makes recorded.
@MainActor
private final class PaneRig {
    let isolated = ProbeFixtures.isolatedStores()
    let defaults = InMemoryDefaults()
    let time = StageTime()
    lazy var scheduler = StageScheduler(time: time)
    let settings: PrompterSettings
    let library: PrompterLibrary
    let session: PrompterSession
    let center: HotKeyCenter
    private(set) var parts: PrompterParts!
    var switchCalls: [Bool] = []
    var quits = 0

    init() {
        settings = PrompterSettings(defaults: defaults)
        library = PrompterLibrary(io: StageFileIO(), scheduler: StageScheduler(time: StageTime()))
        let time = self.time
        session = PrompterSession(
            now: { time.now }, scheduler: StageScheduler(time: time), keepAwake: StageLease()
        )
        center = HotKeyCenter(defaults: isolated.suite, registrar: { _, _ in nil })
        center.refuseSound = {}
        parts = PrompterParts(settings: settings, library: library, session: session)
        library.load()
    }

    func release() { isolated.release() }

    func pane(
        enabled: Bool,
        fontInstalled: @escaping (PrompterFontFamily) -> Bool = { _ in true }
    ) -> SettingsPane {
        let stores = isolated.stores
        return SettingsPane(
            shelf: stores.shelf, screenshotVault: stores.screenshotVault, lyrics: stores.lyrics,
            media: stores.media, localLyrics: stores.localLyricsLibrary, privacy: stores.privacy,
            prompterEnabled: enabled,
            prompterParts: enabled ? parts : nil,
            setPrompterEnabled: { [unowned self] in self.switchCalls.append($0) },
            prompterFontInstalled: fontInstalled,
            quit: { [unowned self] in self.quits += 1 },
            hotKeys: center,
            updates: UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) }),
            automation: AutomationAccess()
        )
    }

    func tree(enabled: Bool, fontInstalled: @escaping (PrompterFontFamily) -> Bool = { _ in true }) async -> AXNode {
        await AXProbe.tree(
            of: pane(enabled: enabled, fontInstalled: fontInstalled),
            size: CGSize(width: 488, height: 3600)
        )
    }
}

@MainActor
final class PrompterSettingsPaneTests: XCTestCase {
    private var rig: PaneRig!

    override func setUp() async throws {
        rig = PaneRig()
    }

    override func tearDown() async throws {
        rig.release()
        rig = nil
    }

    // MARK: Helpers

    /// The nodes drawn between the Prompter heading and the next one.
    private func prompterSection(_ root: AXNode) -> [AXNode] {
        let all = root.flattened
        guard let start = all.firstIndex(where: { $0.role == "AXHeading" && $0.label == localized("Prompter") }) else {
            return []
        }
        let rest = all[(start + 1)...]
        let end = rest.firstIndex { $0.role == "AXHeading" } ?? rest.endIndex
        return Array(rest[..<end])
    }

    private func group(_ root: AXNode, _ title: String) -> AXNode? {
        root.all(role: "AXRadioGroup").first { $0.label == localized(title) }
    }

    private func name(_ node: AXNode) -> String { node.title.isEmpty ? node.label : node.title }

    // MARK: The switch (spec 4)

    /// The switch is how the feature is turned on, so it is always drawn, with
    /// the spec's sentence under it, and nothing else of the section is: absent,
    /// not hidden. Drawing the pane wrote no default (spec 4: no `prompter.*`
    /// key but the switch itself is ever written).
    func testTheSwitchIsAlwaysShownAndNothingElseOfTheSectionWhileOff() async {
        let root = await rig.tree(enabled: false)
        let section = prompterSection(root)
        XCTAssertFalse(section.isEmpty, "no Prompter heading\n\(root.dump)")

        let switches = section.filter { $0.role == "AXCheckBox" }
        XCTAssertEqual(switches.map(\.label), [localized("Show Prompter")], root.dump)
        XCTAssertEqual(switches.first?.value, "0", "off by default")
        XCTAssertFalse(root.all { $0.label == "Show a script in the island and move it along as you read."
            || $0.value == "Show a script in the island and move it along as you read." }.isEmpty,
            "the switch's one-sentence note is missing\n\(root.dump)")

        XCTAssertTrue(section.filter { $0.role == "AXRadioGroup" || $0.role == "AXSlider" }.isEmpty, root.dump)
        XCTAssertTrue(root.all { $0.label == localized("Reset Prompter Settings") }.isEmpty, root.dump)
        XCTAssertTrue(root.all { $0.label == localized("Cover Prompter Text") }.isEmpty, "the cover row is absent too")
        XCTAssertTrue(root.all { $0.label == HotKeyAction.prompterToggle.title }.isEmpty, "no Prompter shortcut while off")
        XCTAssertTrue(rig.defaults.writes.isEmpty, "drawing wrote \(rig.defaults.writes)")
    }

    func testThePaneNeverReadsTheSwitchItselfFromTheSettings() {
        XCTAssertEqual(PrompterSettings.Key.enabled, "prompter.enabled")
        XCTAssertFalse(PrompterSettings.Key.settings.contains(PrompterSettings.Key.enabled),
                       "Reset must not be able to turn the feature off")
        XCTAssertFalse(PrompterFeature.storedEnabled(in: InMemoryDefaults()), "off by default")
    }

    /// The row reports the state it is given and asks for the change; it does
    /// not flip anything itself (the feature owns the order of a change).
    func testPressingTheSwitchAsksForTheChange() async {
        let root = await rig.tree(enabled: false)
        guard let row = root.all(role: "AXCheckBox").first(where: { $0.label == localized("Show Prompter") }) else {
            return XCTFail("no switch\n\(root.dump)")
        }
        XCTAssertTrue(row.press())
        _ = await root.reread()
        XCTAssertEqual(rig.switchCalls, [true])
        XCTAssertTrue(rig.defaults.writes.isEmpty, "the pane does not write the switch; the feature does")

        let on = await rig.tree(enabled: true)
        XCTAssertEqual(on.all(role: "AXCheckBox").first { $0.label == localized("Show Prompter") }?.value, "1")
    }

    // MARK: The rows (spec 5.3, 12.2)

    func testWhileOnTheSectionHoldsExactlyTheReleaseOneRows() async {
        let root = await rig.tree(enabled: true)
        let section = prompterSection(root)
        let controls = section.filter {
            ["AXCheckBox", "AXRadioGroup", "AXSlider", "AXButton"].contains($0.role)
        }.map(\.label)

        let expected = [
            "Show Prompter",
            "Slower", "Faster",
            "Text Size", "Font", "Highlight Color", "Cue Color", "Cue Brightness", "Reading Position",
            "Column Width",
            "Paragraph Dividers", "Last Spoken Words", "Elapsed Time", "Keep Display Awake",
            "Auto-Next Page", "Auto-Next Delay",
            "Reset Prompter Settings",
        ].map { localized($0) }
        XCTAssertEqual(controls.sorted(), expected.sorted(), root.dump)

        // Releases 2 and 3 are not here: a control for something that does not
        // work yet is worse than no control (`PrompterSettingsValues`).
        for absent in ["Microphone", "Speech Language", "Apple Speech", "Guidance Mode"] {
            XCTAssertTrue(root.all { $0.label.localizedCaseInsensitiveContains(absent) }.isEmpty, "\(absent)\n\(root.dump)")
        }
    }

    func testEveryChoiceRowOffersItsOptionsWithTheStoredOneSelected() async throws {
        rig.settings.fontSize = .xl
        rig.settings.cueBrightness = .bright
        let root = await rig.tree(enabled: true)

        let expected: [(String, [String], String)] = [
            ("Text Size", ["Extra Small", "Small", "Large", "Extra Large"], "Extra Large"),
            ("Font", ["Sans", "Serif", "Mono", "OpenDyslexic"], "Sans"),
            ("Highlight Color", ["White", "Yellow", "Green", "Blue", "Pink", "Orange"], "White"),
            ("Cue Color", ["White", "Yellow", "Green", "Blue", "Pink", "Orange"], "White"),
            ("Cue Brightness", ["Dim", "Low", "Medium", "Bright"], "Bright"),
            ("Reading Position", ["Centered", "Near Top"], "Centered"),
            ("Auto-Next Delay", ["At Once", "1 s", "3 s", "5 s"], "3 s"),
        ]
        for (title, options, selected) in expected {
            let node = try XCTUnwrap(group(root, title), "no \(title)\n\(root.dump)")
            let buttons = node.all(role: "AXRadioButton")
            XCTAssertEqual(buttons.map(name), options.map { localized($0) }, title)
            XCTAssertEqual(buttons.filter { $0.value == "1" }.map(name), [localized(selected)], title)
        }
    }

    /// Choosing an option writes that setting, to its own key.
    func testChoosingAnOptionWritesTheSetting() async throws {
        rig.settings.autoNext = true // the delay row is dimmed, and refuses a press, until it is on
        let root = await rig.tree(enabled: true)
        func choose(_ title: String, _ option: String) throws {
            let node = try XCTUnwrap(group(root, title), title)
            let button = try XCTUnwrap(node.all(role: "AXRadioButton").first { name($0) == localized(option) }, option)
            XCTAssertTrue(button.press(), "\(option) refused the press")
        }
        try choose("Text Size", "Extra Small")
        try choose("Font", "Mono")
        try choose("Highlight Color", "Yellow")
        try choose("Cue Color", "Pink")
        try choose("Cue Brightness", "Medium")
        try choose("Reading Position", "Near Top")
        try choose("Auto-Next Delay", "5 s")
        _ = await root.reread()
        XCTAssertEqual(rig.settings.fontSize, .xs)
        XCTAssertEqual(rig.settings.fontFamily, .mono)
        XCTAssertEqual(rig.settings.highlight, .yellow)
        XCTAssertEqual(rig.settings.cueColor, .pink)
        XCTAssertEqual(rig.settings.cueBrightness, .medium)
        XCTAssertEqual(rig.settings.readingPosition, .nearTop)
        XCTAssertEqual(rig.settings.autoNextDelay, 5)
        XCTAssertEqual(rig.defaults.storage[PrompterSettings.Key.fontSize] as? String, "xs")
    }

    func testTheSwitchesFlipTheirSettings() async throws {
        let root = await rig.tree(enabled: true)
        let defaults = PrompterSettingsValues.defaults
        func row(_ title: String) throws -> AXNode {
            try XCTUnwrap(root.all(role: "AXCheckBox").first { $0.label == localized(title) }, title)
        }
        XCTAssertEqual(try row("Paragraph Dividers").value, defaults.paragraphDividers ? "1" : "0")
        XCTAssertEqual(try row("Last Spoken Words").value, defaults.showLastSpoken ? "1" : "0")
        XCTAssertEqual(try row("Elapsed Time").value, defaults.showElapsed ? "1" : "0")
        XCTAssertEqual(try row("Keep Display Awake").value, defaults.keepAwake ? "1" : "0")
        XCTAssertEqual(try row("Auto-Next Page").value, defaults.autoNext ? "1" : "0")

        XCTAssertTrue(try row("Paragraph Dividers").press())
        XCTAssertTrue(try row("Elapsed Time").press())
        XCTAssertTrue(try row("Keep Display Awake").press())
        XCTAssertTrue(try row("Auto-Next Page").press())
        _ = await root.reread()
        XCTAssertEqual(rig.settings.paragraphDividers, !defaults.paragraphDividers)
        XCTAssertEqual(rig.settings.showElapsed, !defaults.showElapsed)
        XCTAssertEqual(rig.settings.keepAwake, !defaults.keepAwake)
        XCTAssertEqual(rig.settings.autoNext, !defaults.autoNext)
    }

    /// The stepper is the tab's (0.5 to 8 in halves), so the two cannot
    /// disagree, and it stops at the ends.
    func testTheSpeedStepperMovesInHalvesAndStopsAtTheEnds() async throws {
        let root = await rig.tree(enabled: true)
        let faster = try XCTUnwrap(root.all(role: "AXButton").first { $0.label == localized("Faster") })
        XCTAssertTrue(faster.press())
        _ = await root.reread()
        XCTAssertEqual(rig.settings.speed, PromptClock.defaultSpeed + PromptClock.speedStep)

        rig.settings.speed = PromptClock.speedRange.lowerBound
        let atFloor = await rig.tree(enabled: true)
        XCTAssertEqual(atFloor.all(role: "AXButton").first { $0.label == localized("Slower") }?.enabled, false, atFloor.dump)
        rig.settings.speed = PromptClock.speedRange.upperBound
        let atCeiling = await rig.tree(enabled: true)
        XCTAssertEqual(atCeiling.all(role: "AXButton").first { $0.label == localized("Faster") }?.enabled, false, atCeiling.dump)
    }

    func testTheColumnWidthSliderReadsTheSettingInPoints() async throws {
        let root = await rig.tree(enabled: true)
        let slider = try XCTUnwrap(root.all(role: "AXSlider").first { $0.label == localized("Column Width") }, root.dump)
        XCTAssertTrue(slider.value.contains("360"), "reads \(slider.value)")
        XCTAssertEqual(PrompterSettingsRows.columnWidthRange, PrompterSettingsValues.columnWidthRange,
                       "the slider's ends are the settings' clamp, not a second copy")
        rig.settings.columnWidth = 9_999
        XCTAssertEqual(rig.settings.columnWidth, PrompterSettingsValues.columnWidthRange.upperBound)
    }

    // MARK: Dependent rows (plan T9: disabledReason)

    /// The delay only matters while pages advance by themselves.
    func testTheDelayRowSaysWhyItIsDimmedUntilAutoNextIsOn() async throws {
        let off = await rig.tree(enabled: true)
        let reason = localized("Needs Auto-Next Page")
        let dimmed = try XCTUnwrap(group(off, "Auto-Next Delay"), off.dump)
        XCTAssertFalse(dimmed.enabled && dimmed.all(role: "AXRadioButton").allSatisfy(\.enabled), "still looks live\n\(off.dump)")
        XCTAssertTrue(dimmed.flattened.contains { $0.help == reason }, "does not say why\n\(off.dump)")

        rig.settings.autoNext = true
        let on = await rig.tree(enabled: true)
        let live = try XCTUnwrap(group(on, "Auto-Next Delay"), on.dump)
        XCTAssertTrue(live.enabled)
        XCTAssertTrue(live.all(role: "AXRadioButton").allSatisfy(\.enabled), on.dump)
        XCTAssertFalse(live.flattened.contains { $0.help == reason }, on.dump)
    }

    /// Release 1 has no Word Tracking, which is the only thing that shows the
    /// last words heard. The row is in the spec's list, so it is drawn, dimmed,
    /// with the reason; a live control for nothing would be a lie.
    func testLastSpokenWordsIsDimmedWithItsReasonInReleaseOne() async throws {
        let root = await rig.tree(enabled: true)
        let row = try XCTUnwrap(root.all(role: "AXCheckBox").first { $0.label == localized("Last Spoken Words") }, root.dump)
        XCTAssertFalse(row.enabled, root.dump)
        XCTAssertEqual(row.help, localized("Needs Word Tracking, which is not available yet"))
    }

    // MARK: OpenDyslexic (design note, type)

    func testOpenDyslexicIsAnnotatedWhenItIsNotInstalled() async throws {
        let missing = await rig.tree(enabled: true, fontInstalled: { $0 != .dyslexia })
        let fonts = try XCTUnwrap(group(missing, "Font"), missing.dump)
        XCTAssertEqual(fonts.all(role: "AXRadioButton").map(name).last, localized("OpenDyslexic (not installed)"), missing.dump)
        // Still choosable: the stage falls back silently, the setting never fails.
        XCTAssertTrue(fonts.all(role: "AXRadioButton").allSatisfy(\.enabled), missing.dump)

        let present = await rig.tree(enabled: true, fontInstalled: { _ in true })
        let installed = try XCTUnwrap(group(present, "Font"), present.dump)
        XCTAssertEqual(installed.all(role: "AXRadioButton").map(name).last, localized("OpenDyslexic"), present.dump)
    }

    func testOnlyTheFaceThatIsMissingCarriesTheNote() {
        for family in PrompterFontFamily.allCases {
            let title = PrompterSettingsCopy.title(family, installed: false)
            XCTAssertEqual(title == localized("OpenDyslexic (not installed)"), family == .dyslexia, "\(family): \(title)")
            XCTAssertFalse(PrompterSettingsCopy.title(family, installed: true).contains("not installed"))
        }
        // The default question is the resolver's own, so Settings and the
        // stage cannot disagree about whether the face is there.
        XCTAssertEqual(PrompterFontResolver.isInstalled(.dyslexia),
                       !PrompterFontResolver.resolve(family: .dyslexia, size: 20).isFallback)
    }

    // MARK: Hot keys (spec 5.3, 5.4)

    func testThePrompterShortcutsAreListedOnlyWhileTheSwitchIsOn() async {
        let off = await rig.tree(enabled: false)
        for action in [HotKeyAction.prompterToggle, .prompterStop] {
            XCTAssertTrue(off.all { $0.label == action.title }.isEmpty, "\(action) while off\n\(off.dump)")
        }
        XCTAssertFalse(off.all { $0.label == HotKeyAction.openPanel.title }.isEmpty, "the core three stay")

        rig.center.setFeature(.prompter, enabled: true)
        let on = await rig.tree(enabled: true)
        for action in [HotKeyAction.prompterToggle, .prompterStop] {
            XCTAssertEqual(on.all(role: "AXButton").filter { $0.label == action.title }.count, 1, "\(action)\n\(on.dump)")
        }
    }

    /// With the switch on, a moved Prompter key raises the restore row; with it
    /// off the same row would have nothing visible to restore (T4).
    func testRestoreDefaultsFollowsTheShortcutsThatAreShown() async {
        let restore = localized("Restore Default Shortcuts")
        rig.center.setFeature(.prompter, enabled: true)
        rig.center.setBinding(HotKeyBinding(keyCode: 0x0B, modifiers: HotKeyBinding.defaultModifiers), for: .prompterToggle)
        let on = await rig.tree(enabled: true)
        XCTAssertEqual(on.all(role: "AXButton").filter { $0.label == restore }.count, 1, on.dump)

        rig.center.setFeature(.prompter, enabled: false)
        let off = await rig.tree(enabled: false)
        XCTAssertTrue(off.all { $0.label == restore }.isEmpty, off.dump)
    }

    // MARK: Privacy (spec 5.3)

    func testCoverPrompterTextTogglesItsSection() async throws {
        let privacy = rig.isolated.stores.privacy
        XCTAssertFalse(privacy.covers(.prompter))
        let root = await rig.tree(enabled: true)
        let row = try XCTUnwrap(
            root.all(role: "AXCheckBox").first { $0.label == localized("Cover Prompter Text") }, root.dump
        )
        XCTAssertTrue(row.press())
        _ = await root.reread()
        XCTAssertTrue(privacy.covers(.prompter))
    }

    // MARK: Reset (spec 5.3)

    /// Two presses, then every `prompter.*` setting is back to its default and
    /// nothing else moved: not the switch, not the scripts.
    func testResetAsksFirstThenRestoresOnlyTheSettings() async throws {
        rig.defaults.set(true, forKey: PrompterSettings.Key.enabled)
        rig.settings.fontSize = .xl
        rig.settings.speed = 6
        rig.settings.autoNext = true
        _ = try rig.library.addScript(title: "Keep me", pages: ["one two", "three"])
        let before = rig.library.scripts
        rig.defaults.resetWrites()

        let root = await rig.tree(enabled: true)
        let title = localized("Reset Prompter Settings")
        let button = try XCTUnwrap(root.all(role: "AXButton").first { $0.label == title }, root.dump)
        XCTAssertTrue(button.press())
        let armed = await root.reread()
        XCTAssertEqual(rig.settings.fontSize, .xl, "the first press only asks")
        XCTAssertTrue(rig.defaults.writes.isEmpty)
        let again = try XCTUnwrap(armed.all(role: "AXButton").first { $0.label == localized("Reset") }, armed.dump)
        XCTAssertTrue(again.press())
        _ = await armed.reread()

        XCTAssertEqual(rig.settings.values, .defaults)
        XCTAssertEqual(Set(rig.defaults.writes), Set(PrompterSettings.Key.settings), "only the settings' keys")
        XCTAssertEqual(rig.defaults.storage[PrompterSettings.Key.enabled] as? Bool, true, "the switch is not a setting")
        XCTAssertEqual(rig.library.scripts, before, "Reset does not touch scripts")
    }

    // MARK: Quit while a session holds the panel (spec 11.7)

    private func quitLabel(_ root: AXNode) -> AXNode? {
        root.all(role: "AXButton").first {
            [localized("Quit"), localized("Quit Isla"), localized("Stop Prompter and Quit")].contains($0.label)
        }
    }

    private func startSession() {
        rig.session.start(pages: [PromptScript("one two three four five six")])
    }

    /// Running or paused, the session holds the panel, so Quit names what it
    /// will do and asks first. Nothing quits on the first press.
    func testQuitAsksWhileASessionHoldsThePanel() async throws {
        for paused in [false, true] {
            startSession()
            if paused { rig.session.pause() }
            XCTAssertTrue(rig.session.holdsPanel)
            let before = rig.quits
            let root = await rig.tree(enabled: true)
            let quit = try XCTUnwrap(quitLabel(root), root.dump)
            XCTAssertEqual(quit.label, localized("Quit"))
            XCTAssertTrue(quit.press())
            let armed = await root.reread()
            XCTAssertEqual(rig.quits, before, "the first press quit")
            let confirm = try XCTUnwrap(
                armed.all(role: "AXButton").first { $0.label == localized("Stop Prompter and Quit") }, armed.dump
            )
            XCTAssertTrue(confirm.press())
            _ = await armed.reread()
            XCTAssertEqual(rig.quits, before + 1, "the second press quits once")
            rig.session.stop()
        }
    }

    /// With no session Quit keeps the two presses the footer has always had
    /// (a footer is where a stray click lands), and its armed word says nothing
    /// about a Prompter that is not there.
    func testQuitWithoutASessionKeepsItsOrdinaryConfirmation() async throws {
        for enabled in [false, true] {
            let before = rig.quits
            let root = await rig.tree(enabled: enabled)
            let quit = try XCTUnwrap(quitLabel(root), root.dump)
            XCTAssertTrue(quit.press())
            let armed = await root.reread()
            XCTAssertEqual(rig.quits, before)
            let confirm = try XCTUnwrap(armed.all(role: "AXButton").first { $0.label == localized("Quit Isla") }, armed.dump)
            XCTAssertTrue(confirm.press())
            _ = await armed.reread()
            XCTAssertEqual(rig.quits, before + 1)
        }
    }

    // MARK: Russian fits the row layout (spec 15)

    /// At the narrowest panel (480 pt) the pane is 408 pt wide and a row 396.
    /// A row that does not fit overflows rather than truncating (capsules are
    /// fixed-size on purpose), so the widest the Russian strings can make each
    /// row is measured against that. The negative control proves the
    /// measurement can see an overflow at all.
    func testRussianRowsFitTheNarrowestPane() async throws {
        let rowWidth = PrompterTabMetrics.paneSize(bodyWidth: 480, notchHeight: 0).width - 4 - 8
        XCTAssertEqual(rowWidth, 396)

        LabLocalization.use("ru")
        defer { LabLocalization.uninstall() }

        struct Long: Identifiable, Hashable { let id: Int }
        let control = SettingsChoiceRow(
            symbol: "textformat", title: "x", options: (0..<6).map(Long.init),
            selection: .constant(Long(id: 0)), optionTitle: { _ in "Очень длинное название" }
        )
        XCTAssertGreaterThan(Self.width(of: control, proposing: rowWidth), rowWidth, "the measurement cannot see an overflow")

        let rows = PrompterSettingsRows(settings: rig.settings, fontInstalled: { $0 != .dyslexia })
        XCTAssertLessThanOrEqual(Self.width(of: rows, proposing: rowWidth), rowWidth, "a Prompter row overflows in Russian")

        // Row by row, so a failure names the row. The words are the app's own
        // (`PrompterSettingsCopy`); only the container is rebuilt here.
        struct Word: Identifiable, Hashable { let id: String }
        let delays = PrompterSettingsValues.autoNextDelays.map(PrompterSettingsCopy.delayTitle)
        let rowsToMeasure: [(String, [String])] = [
            ("Text Size", PrompterFontSize.allCases.map(PrompterSettingsCopy.title)),
            ("Font", PrompterFontFamily.allCases.map { PrompterSettingsCopy.title($0, installed: false) }),
            ("Cue Brightness", PrompterCueBrightness.allCases.map(PrompterSettingsCopy.title)),
            ("Reading Position", PrompterReadingPosition.allCases.map(PrompterSettingsCopy.title)),
            ("Auto-Next Delay", delays),
        ]
        for (title, words) in rowsToMeasure {
            let options = words.map(Word.init(id:))
            let row = SettingsChoiceRow(
                symbol: "textformat", title: localized(title), options: options,
                selection: .constant(options[0]), optionTitle: { $0.id }
            )
            let measured = Self.width(of: row, proposing: rowWidth)
            XCTAssertLessThanOrEqual(measured, rowWidth, "\(title) is \(measured) pt wide in Russian: \(words)")
        }
    }

    private static func width<V: View>(of view: V, proposing width: CGFloat) -> CGFloat {
        let host = NSHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: width, height: 4_000)).width
    }
}
