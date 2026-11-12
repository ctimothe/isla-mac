import SwiftUI
import XCTest
@testable import IslaKit

/// Every control on every surface has a name VoiceOver can read, under every
/// display setting Isla honours (maturity program B0.3, 2026-10-29).
///
/// The accessibility tests before this one each held a single control to its
/// label — the lock card's picker, a clipboard row, the Settings sidebar — so
/// a button added anywhere else could ship as "button" to a VoiceOver user,
/// and the gate had nothing to say. This walks the whole open island on each
/// surface, as an assistive client would find it, and fails on any control
/// that has neither a label nor a title. Increase Contrast and Reduce
/// Transparency swap whole views (`SystemAppearance`), and Reduce Motion swaps
/// transitions, so each surface is read under each.
@MainActor
final class AccessibilitySweepTests: XCTestCase {
    /// The roles a person acts on. A control with one of these and no name is
    /// read as its bare role: "button", "checkbox", "slider".
    static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXSlider", "AXPopUpButton", "AXRadioButton", "AXMenuButton",
        "AXTextField", "AXTextArea", "AXComboBox", "AXIncrementor", "AXLink", "AXDisclosureTriangle",
    ]

    /// The display settings each surface is read under: as shipped, and with
    /// each of the three switches that change what is drawn.
    private enum Setting: String, CaseIterable {
        case standard, reduceMotion, increaseContrast, reduceTransparency

        @MainActor func apply() {
            SystemAppearance.shared.overrideForTests(
                reduceTransparency: self == .reduceTransparency,
                increaseContrast: self == .increaseContrast,
                reduceMotion: self == .reduceMotion
            )
        }
    }

    override func tearDown() async throws {
        SystemAppearance.shared.resetForTests()
        try await super.tearDown()
    }

    /// The controls in `root` that a VoiceOver user would hear only as a role.
    static func unnamedControls(in root: AXNode) -> [AXNode] {
        root.all { node in
            controlRoles.contains(node.role)
                && node.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && node.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Opens a fresh island on `surface` under every setting and fails with the
    /// tree for each one that has a nameless control.
    private func sweep(_ surface: NotchViewModel.Surface, file: StaticString = #filePath, line: UInt = #line) async throws {
        for setting in Setting.allCases {
            let isolated = ProbeFixtures.isolatedStores()
            defer { isolated.release() }
            setting.apply()
            let vm = NotchViewModel(geometry: try LabGeometry.make(physical: true), stores: isolated.stores)
            let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
            let host = AXProbe.present(NotchContentView(vm: vm), size: size)
            vm.isOpen = true
            vm.surface = surface
            // Long enough for Settings' staged form and any swap to land on a
            // Mac that is busy with something else: an early read finds a
            // tree still being built and proves nothing either way.
            let root = await AXProbe.read(host, settle: Theme.swapOutDuration + 0.5, file: file, line: line)
            let unnamed = Self.unnamedControls(in: root)
            XCTAssertTrue(
                unnamed.isEmpty,
                "\(surface.rawValue), \(setting.rawValue): \(unnamed.count) control(s) with no name\n"
                    + unnamed.map { "  \($0.role)/\($0.subrole) value=\($0.value) help=\($0.help) frame=\(String(describing: $0.frame))" }
                    .joined(separator: "\n")
                    + "\n\(root.dump)",
                file: file, line: line
            )
        }
    }

    func testThePlayer() async throws { try await sweep(.player) }
    func testTheLyricStage() async throws { try await sweep(.stage) }
    func testTheShelf() async throws { try await sweep(.tray) }
    func testTheDropSurface() async throws { try await sweep(.drop) }
    func testClipboard() async throws { try await sweep(.clipboard) }
    func testTranslate() async throws { try await sweep(.translate) }
    func testSettings() async throws { try await sweep(.settings) }
    func testTheWelcome() async throws { try await sweep(.welcome) }

    /// Settings is ten sections, and `testSettings` reads whichever one was
    /// shown last — General, on a clean machine. So nine of them were never
    /// read: Translate To, in Lyrics, shipped as "Automatic, pop-up button"
    /// and the gate passed. Each section is opened here, once, as shipped.
    /// Its own defaults suite, so the section it leaves selected is not the
    /// one the next test — or the next run — opens on.
    func testEverySettingsSection() async throws {
        let suite = "AccessibilitySweepTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        Setting.standard.apply()
        for section in SettingsSection.allCases {
            let isolated = ProbeFixtures.isolatedStores()
            defer { isolated.release() }
            let vm = NotchViewModel(
                geometry: try LabGeometry.make(physical: true), stores: isolated.stores, defaults: defaults)
            vm.settingsSection = section
            let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
            let host = AXProbe.present(NotchContentView(vm: vm), size: size)
            vm.isOpen = true
            vm.surface = .settings
            let root = await AXProbe.read(host, settle: Theme.swapOutDuration + 0.5)
            let unnamed = Self.unnamedControls(in: root)
            XCTAssertTrue(
                unnamed.isEmpty,
                "settings, \(section.rawValue): \(unnamed.count) control(s) with no name\n"
                    + unnamed.map { "  \($0.role)/\($0.subrole) value=\($0.value) help=\($0.help) frame=\(String(describing: $0.frame))" }
                    .joined(separator: "\n")
            )
        }
    }

    /// The sweep is only as good as its reading of a name: a control labelled
    /// by either field passes, and one with neither fails. A symbol-only
    /// button is not nameless — SwiftUI reads the symbol's own label, "star"
    /// as "Favorite" — so the nameless one here is drawn with a plain shape.
    func testTheSweepFindsANamelessButtonAndPassesANamedOne() async throws {
        let root = await AXProbe.tree(
            of: HStack {
                Button(action: {}) { Rectangle().frame(width: 20, height: 20) }.buttonStyle(.plain)
                Button("Named") {}
                Button(action: {}) { Image(systemName: "heart") }.buttonStyle(.plain).accessibilityLabel("Favourite")
            },
            size: CGSize(width: 300, height: 60)
        )
        let unnamed = Self.unnamedControls(in: root)
        XCTAssertEqual(unnamed.count, 1, root.dump)
    }
}
