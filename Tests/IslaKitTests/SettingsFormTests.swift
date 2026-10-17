import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// The Settings form as it is drawn (redesign 2026-10-15, spec §10, §13): the
/// sidebar's place, the form's width at 480, 560 and 620 in English and Russian,
/// the failure groups in Music alone, the style previews and the destructive
/// push button.
///
/// Every pane is built over `SettingsFixture`: a private defaults suite, a fresh
/// Automation record, a hot-key centre that registers nothing and an update check
/// that cannot reach the network.
@MainActor
final class SettingsFormTests: XCTestCase {
    private let widths: [CGFloat] = [480, 560, 620]

    override func tearDown() {
        LabLocalization.use("en")
        SystemAppearance.shared.resetForTests()
        super.tearDown()
    }

    /// Where the sidebar and the form sit in the pane, which is the board's
    /// (16, 46) and (150, 46) less the pane's own origin (0, 38) — §19.8 moved
    /// every x that was placed for the rail.
    func testTheSidebarAndTheFormAreWhereTheBoardPutsThem() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        for width in widths {
            let root = await SettingsFixture.tree(isolated, section: .general, bodyWidth: width, height: 362)
            let formWidth = SettingsLayout.formWidth(bodyWidth: width)

            let sidebar = root.all(where: { $0.label == localized("Settings sections") }).first
            let buttons = sidebar?.all(role: "AXButton") ?? []
            XCTAssertEqual(buttons.count, 10, root.dump)
            for (index, button) in buttons.enumerated() {
                let frame = button.frame ?? .zero
                XCTAssertEqual(frame.minX, 16, accuracy: 0.5, "row \(index) at \(width)")
                XCTAssertEqual(frame.width, 122, accuracy: 0.5, "row \(index) at \(width)")
                XCTAssertEqual(frame.minY, 8 + CGFloat(index) * 26, accuracy: 0.5, "row \(index) at \(width)")
                XCTAssertEqual(frame.height, 24, accuracy: 0.5, "row \(index) at \(width)")
            }

            guard let launch = root.all(role: "AXCheckBox").first(where: { $0.label == localized("Launch at Login") })?.frame else {
                return XCTFail("no Launch at Login switch at \(width)\n\(root.dump)")
            }
            XCTAssertEqual(launch.minX, 150, accuracy: 0.5, "the form starts at body x 150 at \(width)")
            XCTAssertEqual(launch.width, formWidth, accuracy: 0.5, "the row is the form's width at \(width)")
            XCTAssertEqual(launch.height, 28, accuracy: 0.5, "rows are 28 tall at \(width)")
        }
        XCTAssertEqual(SettingsLayout.formWidth(bodyWidth: 560), 396)
    }

    /// The pane starts under the header row, so the sidebar and the form begin
    /// at the board's y 46 less the 38 reference row on any Mac: the pane has no
    /// header height of its own to follow (the shell's body moves with the
    /// notch instead, `SurfaceLayout.y`).
    func testThePaneStartsUnderTheHeaderRow() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await AXProbe.tree(
            of: SettingsFixture.pane(isolated, section: .general),
            size: SettingsFixture.paneSize()
        )
        let first = root.all(where: { $0.label == localized("Settings sections") }).first?.all(role: "AXButton").first
        XCTAssertEqual(first?.frame?.minY ?? -1, 46 - 38, accuracy: 0.5, "sidebar")
        let launch = root.all(role: "AXCheckBox").first { $0.label == localized("Launch at Login") }
        XCTAssertEqual((launch?.frame?.minY ?? -1), 46 - 38 + 19, accuracy: 1.5, "form's first row")
    }

    /// The section holds at both ends of the width range and in Russian: every
    /// control sits inside the form, none is cut to a stub, and the sliders keep
    /// the width a knob needs (spec §13, `Stress-Settings-RU-480`).
    func testEverySectionHoldsAtFourEightyAndSixTwentyInEnglishAndRussian() async {
        for language in ["en", "ru"] {
            LabLocalization.use(language)
            let pushTitles = Set(SettingsRowID.allCases.filter { $0.kind == .push }.map(\.title) + [
                localized("Try Again"), localized("Open Automation Settings…"), localized("Connect Spotify Account…"),
                localized("Import Account from Keychain…"), localized("Disconnect Spotify Account"), localized("Remove"),
            ])
            for width in [CGFloat(480), 620] {
                let isolated = ProbeFixtures.isolatedStores()
                defer { isolated.release() }
                let formLeading = SettingsLayout.formLeading
                let formWidth = SettingsLayout.formWidth(bodyWidth: width)
                for section in SettingsSection.allCases {
                    let root = await SettingsFixture.tree(isolated, section: section, bodyWidth: width, height: 1600)
                    let controls = root.all { node in
                        ["AXCheckBox", "AXSlider"].contains(node.role)
                            || (node.role == "AXButton" && (node.frame?.minX ?? 0) >= formLeading - 1)
                    }
                    XCTAssertFalse(controls.isEmpty, "\(section) has controls to hold")
                    for control in controls {
                        guard let frame = control.frame else { continue }
                        let name = "\(section) \(control.role) \"\(control.label)\" \(frame) at \(width) in \(language)"
                        XCTAssertGreaterThanOrEqual(frame.minX, formLeading - 1, name)
                        XCTAssertLessThanOrEqual(frame.maxX, formLeading + formWidth + 1, name)
                        if control.role == "AXSlider" {
                            XCTAssertGreaterThanOrEqual(frame.width, SettingsSliderRow.minimumSliderWidth - 1, name)
                        }
                        if control.role == "AXCheckBox" {
                            XCTAssertEqual(frame.width, formWidth, accuracy: 1, "a switch is the whole row: \(name)")
                        }
                    }
                    // A push button is as wide as its word and the padding round
                    // it: a plate narrower than that has cut the label. Only the
                    // push buttons are measured — a shortcut's well and a stepper
                    // are named for what they do, and draw a key and a glyph.
                    for button in controls where button.role == "AXButton" && pushTitles.contains(button.label) {
                        guard let frame = button.frame else { continue }
                        let word = (button.label as NSString).size(
                            withAttributes: [.font: NSFont.systemFont(ofSize: Theme.TypeRole.body.size)]
                        ).width
                        XCTAssertGreaterThanOrEqual(
                            frame.width, word * 0.95, "\"\(button.label)\" is cut in \(section) at \(width) in \(language)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - One failure surface

    /// Try Again and Open Automation Settings… are drawn in the Music section,
    /// once each, while their condition holds — and in no other section, however
    /// long the section.
    func testTheFailureGroupsAreDrawnInMusicAndNowhereElse() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.stores.media.switchToScriptingFallback(.keptStopping)
        defer { isolated.stores.media.stop() }
        let access = AutomationAccess()
        access.learn(.spotify, outcome: AutomationAccess.refused)

        let tryAgain = localized("Try Again")
        let openAutomation = localized("Open Automation Settings…")
        for section in SettingsSection.allCases {
            let root = await SettingsFixture.tree(isolated, section: section, height: 1600, automation: access)
            let buttons = root.all(role: "AXButton").map(\.label)
            let wanted = section == .music ? 1 : 0
            XCTAssertEqual(buttons.filter { $0 == tryAgain }.count, wanted, "Try Again in \(section)\n\(root.dump)")
            XCTAssertEqual(buttons.filter { $0 == openAutomation }.count, wanted, "Open Automation Settings… in \(section)\n\(root.dump)")
            let headings = root.all(role: "AXHeading").map(\.label)
            XCTAssertEqual(headings.contains(localized("Now Playing")), section == .music, "\(section)")
            XCTAssertEqual(headings.contains(localized("Automation")), section == .music, "\(section)")
        }
    }

    /// With the reader up and every player allowed, Music has neither group.
    func testMusicHasNoFailureGroupsWhileNothingFails() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let access = AutomationAccess()
        access.learn(.spotify, outcome: noErr)
        let root = await SettingsFixture.tree(isolated, section: .music, height: 1000, automation: access)
        XCTAssertTrue(root.all(role: "AXButton").filter {
            [localized("Try Again"), localized("Open Automation Settings…")].contains($0.label)
        }.isEmpty, root.dump)
        XCTAssertEqual(root.all(role: "AXHeading").map(\.label), ["Music", "In the player"].map { localized($0) }, root.dump)
    }

    // MARK: - Lock Screen: four real previews

    /// The previews ask the card's own function for their material: what
    /// `LockCardMaterial.decision` says, for a song with a cover over the
    /// wallpaper the card assumes when it cannot measure one.
    func testThePreviewsAskTheCardsOwnMaterialDecision() {
        let unknown = LockCardMaterial.unknownLuminance
        for style in NotchViewModel.LockCardStyle.allCases {
            for (reduce, contrast) in [(false, false), (true, false), (false, true), (true, true)] {
                XCTAssertEqual(
                    LockStylePreview.decision(style: style, reduceTransparency: reduce, increaseContrast: contrast),
                    LockCardMaterial.decision(
                        style: style, hasArtwork: true, luminance: unknown,
                        reduceTransparency: reduce, increaseContrast: contrast
                    ),
                    "\(style) reduce \(reduce) contrast \(contrast)"
                )
            }
        }
        // Spec §7.2's four, as the previews show them.
        let automatic = LockStylePreview.decision(style: .automatic, reduceTransparency: false, increaseContrast: false)
        XCTAssertEqual(automatic.layer, .coverLight)
        XCTAssertEqual(automatic.alpha, LockCardMaterial.floorAlpha, accuracy: 0.001, "Automatic at its 0.84 floor over Sonoma")
        let tinted = LockStylePreview.decision(style: .glass, reduceTransparency: false, increaseContrast: false)
        XCTAssertEqual(tinted, LockCardMaterial.Decision(layer: .coverLight, alpha: 0.88))
        XCTAssertEqual(LockStylePreview.decision(style: .clear, reduceTransparency: false, increaseContrast: false).layer, .blackWash)
        XCTAssertEqual(
            LockStylePreview.decision(style: .solid, reduceTransparency: false, increaseContrast: false),
            LockCardMaterial.Decision(layer: .solid, alpha: 1)
        )
        // Reduce Transparency: the card is Solid in every style, so the previews are.
        for style in NotchViewModel.LockCardStyle.allCases {
            XCTAssertEqual(
                LockStylePreview.decision(style: style, reduceTransparency: true, increaseContrast: false).layer, .solid, "\(style)"
            )
        }
    }

    /// The four previews are one radio group named Card Style, Automatic chosen
    /// until the person chooses, and a press moves the choice and stores it.
    func testCardStyleIsFourPreviewsAndAPressStoresTheChoice() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let root = await SettingsFixture.tree(isolated, section: .lockScreen)
        guard let group = root.all(role: "AXRadioGroup").first(where: { $0.label == localized("Card Style") }) else {
            return XCTFail("no Card Style group\n\(root.dump)")
        }
        let name = { (node: AXNode) in node.title.isEmpty ? node.label : node.title }
        let radios = group.all(role: "AXRadioButton")
        XCTAssertEqual(radios.map(name), ["Automatic", "Transparent", "Tinted", "Solid"].map { localized($0) }, root.dump)
        XCTAssertEqual(radios.filter { $0.value == "1" }.map(name), [localized("Automatic")], "Automatic until chosen\n\(root.dump)")
        XCTAssertNil(isolated.suite.object(forKey: NotchViewModel.lockCardStyleKey), "looking stores nothing")

        guard let solid = radios.first(where: { name($0) == localized("Solid") }) else { return XCTFail(root.dump) }
        XCTAssertTrue(solid.press(), "Solid refused the press\n\(root.dump)")
        let after = await root.reread()
        XCTAssertEqual(isolated.suite.string(forKey: NotchViewModel.lockCardStyleKey), "solid")
        let on = after.all(role: "AXRadioGroup").first { $0.label == localized("Card Style") }?
            .all(role: "AXRadioButton").filter { $0.value == "1" }
        XCTAssertEqual(on?.map(name), [localized("Solid")], after.dump)
        // Rest as Banner and Card Size are under them, in one group.
        XCTAssertNotNil(root.all(role: "AXRadioGroup").first { $0.label == localized("Card Size") }, root.dump)
        XCTAssertEqual(root.all(role: "AXCheckBox").filter { $0.label == localized("Rest as Banner") }.count, 1, root.dump)
    }

    /// A stored choice is what the previews show chosen.
    func testAStoredStyleIsTheOneRingedOnOpening() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        isolated.suite.set(NotchViewModel.LockCardStyle.clear.rawValue, forKey: NotchViewModel.lockCardStyleKey)
        let root = await SettingsFixture.tree(isolated, section: .lockScreen)
        let on = root.all(role: "AXRadioGroup").first { $0.label == localized("Card Style") }?
            .all(role: "AXRadioButton").filter { $0.value == "1" }
        XCTAssertEqual(on?.map { $0.title.isEmpty ? $0.label : $0.title }, [localized("Transparent")], root.dump)
    }

    // MARK: - The sidebar

    func testPressingASidebarRowSelectsItsSection() async {
        var picked: [SettingsSection] = []
        let root = await AXProbe.tree(
            of: SidebarHarness { picked.append($0) }.frame(width: 122, height: 260),
            size: CGSize(width: 122, height: 260)
        )
        guard let lyrics = root.all(role: "AXButton").first(where: { $0.label == localized("Lyrics") }) else {
            return XCTFail(root.dump)
        }
        XCTAssertTrue(lyrics.press())
        let after = await root.reread()
        XCTAssertEqual(picked, [.lyrics])
        XCTAssertEqual(after.all(role: "AXButton").filter(\.selected).map(\.label), [localized("Lyrics")], after.dump)
    }

    /// A long name truncates at its tail and says all of itself where a pointer
    /// rests: the label is cut to its own width, and the row's tooltip is the name.
    func testALongNameIsCutToItsLabelAndHelpsWithTheWhole() async {
        LabLocalization.use("ru")
        let root = await AXProbe.tree(
            of: SidebarHarness { _ in }.frame(width: 122, height: 260), size: CGSize(width: 122, height: 260)
        )
        guard let privacy = root.all(role: "AXButton").first(where: { $0.label == "Конфиденциальность" }) else {
            return XCTFail(root.dump)
        }
        XCTAssertEqual(privacy.help, "Конфиденциальность")
        XCTAssertLessThanOrEqual(privacy.frame?.maxX ?? 0, 122.5, "the row never runs under the form")
    }

    // MARK: - A destructive action is a push button that asks

    func testAConfirmPushButtonAsksOnItsOwnPlateAndActsOnTheSecondPress() async {
        ArmedConfirmations.shared.disarmAll()
        var acted = 0
        let root = await AXProbe.tree(
            of: ConfirmPushButton(title: "Disconnect Spotify Account", armedTitle: "Disconnect") { acted += 1 }
                .padding(20).frame(width: 300, height: 60),
            size: CGSize(width: 300, height: 60)
        )
        guard let button = root.all(role: "AXButton").first else { return XCTFail(root.dump) }
        XCTAssertEqual(button.label, "Disconnect Spotify Account")
        XCTAssertTrue(button.press())
        let armed = await root.reread()
        XCTAssertEqual(acted, 0, "the first press only asks")
        XCTAssertEqual(armed.all(role: "AXButton").first?.label, "Disconnect", armed.dump)
        XCTAssertTrue(ArmedConfirmations.shared.disarmAll(), "an armed question is something Escape takes back")
        let calm = await root.reread()
        XCTAssertEqual(calm.all(role: "AXButton").first?.label, "Disconnect Spotify Account", calm.dump)

        XCTAssertTrue(calm.all(role: "AXButton").first?.press() ?? false)
        let again = await root.reread()
        XCTAssertTrue(again.all(role: "AXButton").first?.press() ?? false)
        XCTAssertEqual(acted, 1, "the second press, while armed, does it")
        ArmedConfirmations.shared.disarmAll()
    }

    /// No row in Settings is a red text row: the only destructive style is a push
    /// button's plate while it asks (`ToolbarPushButtonStyle.Kind.danger`).
    func testNoSectionDrawsAnArmedStateAtRest() async {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        for section in [SettingsSection.lyrics, .spotify, .screenshots, .about] {
            let root = await SettingsFixture.tree(isolated, section: section, height: 1400)
            XCTAssertTrue(
                root.all(role: "AXButton").filter { [localized("Delete These Files"), localized("Disconnect")].contains($0.label) }.isEmpty,
                "\(section) rests unarmed\n\(root.dump)"
            )
        }
    }
}

/// The sidebar over state of its own, so the selection a press makes is the one
/// it then draws.
private struct SidebarHarness: View {
    @State private var selection: SettingsSection = .general
    let onPick: (SettingsSection) -> Void

    var body: some View {
        SettingsSidebar(selection: Binding(get: { selection }, set: { selection = $0; onPick($0) }))
    }
}
