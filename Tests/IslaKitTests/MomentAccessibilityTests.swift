import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// What VoiceOver finds on the shut island for every moment it shows: the
/// volume and brightness pop-up, a confirmation, the charger, headphones, and
/// the update alert in each of its stages (maturity program Batch 1,
/// 2026-10-29).
///
/// The scorecard put the pop-up, the charger and updates at 1 for
/// accessibility: each moment was spoken by `Announcer` when it arrived, but
/// nothing held what a VoiceOver user finds when they go to the island while
/// it stands — the charger alone had a check, inside
/// `IslandAccessibilityTests`. An island that a sighted person reads as
/// "Volume 50%" and VoiceOver reads as the song underneath is the same
/// island telling two people two things. Each test here reads the tree the
/// way an assistive client does and holds the island to the moment on it, one
/// element, with no nameless control beside it.
@MainActor
final class MomentAccessibilityTests: XCTestCase {
    override func tearDown() async throws {
        UpdateInstaller.sharedOverride = nil
        try await super.tearDown()
    }

    private func islands(in root: AXNode) -> [AXNode] {
        root.all { $0.role == "AXButton" && $0.label == ProductIdentity.displayName }
    }

    /// The shut island with `moment` applied, over a song when `playing`, read
    /// whole: the window is the panel's full height, so an alert that grows
    /// below the notch is inside it.
    private func shutIsland(
        playing: Bool = false, file: StaticString = #filePath, line: UInt = #line,
        _ moment: (NotchViewModel) -> Void
    ) async throws -> (island: AXNode, root: AXNode) {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        if playing { await LabFixtures.play(LabFixtures.Track(), on: isolated.stores.media) }
        let vm = NotchViewModel(geometry: try LabGeometry.make(physical: true), stores: isolated.stores)
        moment(vm)
        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
        let root = await AXProbe.tree(of: NotchContentView(vm: vm), size: size)
        let found = islands(in: root)
        XCTAssertEqual(found.count, 1, "one island, not a second element for the moment\n\(root.dump)", file: file, line: line)
        XCTAssertEqual(
            AccessibilitySweepTests.unnamedControls(in: root).count, 0,
            "a control beside the moment with no name\n\(root.dump)", file: file, line: line
        )
        return (try XCTUnwrap(found.first, root.dump, file: file, line: line), root)
    }

    private func reading(_ kind: HUDKind, _ level: Float, muted: Bool = false) -> HUDMoment {
        HUDMoment(HUDReading(kind: kind, level: level, muted: muted, deviceSymbol: nil))
    }

    // MARK: - The pop-up

    func testThePopUpIsTheIslandsValueForEachLevelItMoves() async throws {
        let cases: [(HUDMoment, String)] = [
            (reading(.volume, 0.5), localized("Volume %@", localized("%d%%", 50))),
            (reading(.display, 0.3), localized("Brightness %@", localized("%d%%", 30))),
            (reading(.keyboard, 1), localized("Keyboard Brightness %@", localized("%d%%", 100))),
            (reading(.volume, 0.5, muted: true), localized("Muted")),
        ]
        for (moment, spoken) in cases {
            let (island, root) = try await shutIsland { $0.hud = moment }
            XCTAssertEqual(island.value, spoken, root.dump)
        }
    }

    /// Over a song the island is the pop-up's while it stands, as it is to the
    /// eye: VoiceOver used to be the one place a song could outrank it.
    func testThePopUpOutranksTheSongAndTheCharger() async throws {
        let moment = reading(.volume, 0.7)
        let (island, root) = try await shutIsland(playing: true) {
            $0.ambient = .charging(level: 80, isCharging: true, port: .magSafe)
            $0.hud = moment
        }
        XCTAssertEqual(island.value, moment.accessibilityLabel, root.dump)
    }

    // MARK: - Confirmations

    func testEachConfirmationIsTheIslandsValue() async throws {
        for kind in [IslandConfirmation.Kind.copied, .addedToShelf, .lyricsImported] {
            let confirmation = IslandConfirmation(kind)
            let (island, root) = try await shutIsland(playing: true) { $0.confirmation = confirmation }
            XCTAssertEqual(island.value, confirmation.title, root.dump)
            XCTAssertFalse(island.value.isEmpty)
        }
    }

    // MARK: - Charger and headphones

    func testEachChargerStateIsTheIslandsValue() async throws {
        let states: [AmbientActivity] = [
            .charging(level: 80, isCharging: true, port: .magSafe),
            .charging(level: 64, isCharging: true, port: .usbC, watts: 61),
            .charging(level: 41, isCharging: true),
            .charging(level: 80, isCharging: false, port: .usbC, watts: 61, hold: .onHold),
            .charging(level: 55, isCharging: false, hold: .notCharging),
            .charging(level: 100, isCharging: false, hold: .full),
            .charging(level: 12, isCharging: true, port: .magSafe),
        ]
        for state in states {
            let (island, root) = try await shutIsland(playing: true) { $0.ambient = state }
            XCTAssertEqual(island.value, state.accessibilityLabel, root.dump)
            // A level is said with it: the number is what a glance at the
            // battery gives a sighted person.
            if case .charging(let level?, _, _, _, _) = state {
                XCTAssertTrue(island.value.contains("\(level)"), "\(state) left its level out: \(island.value)")
            }
        }
    }

    func testHeadphonesAreNamedOnTheIsland() async throws {
        let headphones = AmbientActivity.headphones(name: "AirPods Pro", symbol: "airpodspro")
        let (island, root) = try await shutIsland(playing: true) { $0.ambient = headphones }
        XCTAssertEqual(island.value, localized("%@ connected", "AirPods Pro"), root.dump)
    }

    // MARK: - The update alert, stage by stage

    private func release(_ version: String = "0.4.0.11") -> UpdateCheck.Release {
        UpdateCheck.Release(version: version, page: URL(string: "https://github.com/ctimothe/isla-mac/releases/tag/v\(version)")!)
    }

    /// The alert while the installer is at `phase`: the tree, and the actions
    /// its buttons sent.
    private func updateAlert(
        _ phase: UpdateInstaller.Phase, press: [String] = []
    ) async throws -> (root: AXNode, actions: [UpdateAlertAction]) {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let installer = UpdateInstaller(environment: .neverInstalls)
        installer.presentForTests(phase, release: release())
        UpdateInstaller.sharedOverride = installer
        let vm = NotchViewModel(geometry: try LabGeometry.make(physical: true), stores: isolated.stores)
        vm.updateOffer = UpdateOffer(release: release())
        var actions: [UpdateAlertAction] = []
        vm.onUpdateAction = { actions.append($0) }
        let size = CGSize(width: VisualLab.windowSize.width, height: vm.geometry.windowSize.height)
        let root = await AXProbe.tree(of: NotchContentView(vm: vm), size: size)
        XCTAssertEqual(
            AccessibilitySweepTests.unnamedControls(in: root).count, 0, "\(phase): a nameless control\n\(root.dump)"
        )
        XCTAssertEqual(
            root.all { $0.label == localized("Isla %@ is ready", "0.4.0.11") }.count, 1,
            "\(phase): the alert is named once by its title\n\(root.dump)"
        )
        for title in press {
            let button = try XCTUnwrap(root.all(role: "AXButton").first { $0.label == title }, "\(phase): no \(title)\n\(root.dump)")
            XCTAssertTrue(button.press(), root.dump)
        }
        return (root, actions)
    }

    /// While it works there is nothing to press, and what VoiceOver finds is
    /// the step and how far it has got — not a bar with no name.
    func testAnInstallUnderWayReadsItsStepAndHowFarItHasGot() async throws {
        let (root, _) = try await updateAlert(.downloading(received: 4_000_000, total: 10_000_000))
        // A progress indicator, named by the step, whose value VoiceOver says
        // as a percent ("40 percent"), the way it reads macOS's own.
        let bars = root.all(role: "AXProgressIndicator")
        XCTAssertEqual(bars.count, 1, root.dump)
        let progress = try XCTUnwrap(bars.first, root.dump)
        XCTAssertEqual(progress.label, localized("Downloading Isla %@…", "0.4.0.11"), root.dump)
        XCTAssertEqual(Double(progress.value) ?? -1, 0.4, accuracy: 0.001, root.dump)
        XCTAssertEqual(
            root.all { $0.label == progress.label || $0.value == progress.label }.count, 1,
            "the step is said once, by the bar\n\(root.dump)"
        )
        XCTAssertTrue(root.all(role: "AXButton").allSatisfy { $0.label != localized("Install") }, root.dump)

        for (phase, step) in [
            (UpdateInstaller.Phase.verifying, localized("Verifying…")),
            (.installing, localized("Installing…")),
            (.relaunching, localized("Restarting Isla…")),
        ] {
            let (root, _) = try await updateAlert(phase)
            XCTAssertEqual(root.all(role: "AXProgressIndicator").first?.label, step, "\(phase): the step is not said\n\(root.dump)")
        }
    }

    /// A failure says why and offers Try Again and Later, and both answer.
    func testAFailedInstallSaysWhyAndBothButtonsAnswer() async throws {
        let (root, actions) = try await updateAlert(
            .failed(.offline), press: [localized("Try Again"), localized("Later")]
        )
        XCTAssertEqual(actions, [.tryAgain, .later])
        let reason = UpdatePresentation.reason(.offline)
        XCTAssertFalse(root.all { $0.label == reason || $0.value == reason }.isEmpty, "the reason is not said\n\(root.dump)")
    }

    /// An update this copy cannot install itself sends the person to
    /// Settings; one in place asks for a quit. Each is a named button.
    func testAManualUpdateAndARestartEachOfferTheirButton() async throws {
        let manual = try await updateAlert(.manualOnly(.translocated), press: [localized("Settings")])
        XCTAssertEqual(manual.actions, [.settings])
        let restart = try await updateAlert(.restartNeeded, press: [localized("Quit Isla")])
        XCTAssertEqual(restart.actions, [.quit])
    }
}
