import AppKit
import XCTest
@testable import IslaKit

/// The surfaces the island opens into (spec §19.1, §19.6–§19.8), and every
/// road to each. It replaces `TabContractTests`: the rail and its five tabs are
/// withdrawn (§19.11), and what a click opens is decided by what the island
/// shows, never by a tab left selected.
@MainActor
final class SurfaceContractTests: XCTestCase {
    typealias Surface = NotchViewModel.Surface

    private func geometry(notchWidth: CGFloat = 185, height: CGFloat = 38) throws -> NotchGeometry {
        let onscreen = try XCTUnwrap(NotchGeometry.current(), "a test host always has a screen")
        return NotchGeometry(
            screen: onscreen.screen,
            notchSize: CGSize(width: notchWidth, height: height),
            notchCenterX: onscreen.screen.frame.midX,
            isPhysical: true
        )
    }

    private func playing() -> NowPlayingFeed.Snapshot {
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Test Song"
        snapshot.artist = "Test Artist"
        snapshot.album = ""
        snapshot.duration = 180
        snapshot.elapsed = 9.2
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.takenAt = Date()
        snapshot.playerPID = 999
        return snapshot
    }

    // MARK: The list

    /// Nine surfaces: seven a person can be sent to, and two the island
    /// presents on its own — the drop surface while a file is dragged to the
    /// notch, and the welcome for one launch.
    func testTheSurfacesAreSpecNineteensAndNoTabs() {
        XCTAssertEqual(
            Surface.allCases,
            [.player, .stage, .tray, .drop, .tools, .clipboard, .translate, .settings, .welcome]
        )
        XCTAssertEqual(Surface.reachable, [.player, .stage, .tray, .tools, .clipboard, .translate, .settings])
        XCTAssertEqual(Surface.allCases.filter(\.takesKeyboard), [.clipboard, .translate], "§19.8")
        XCTAssertEqual(
            Surface.allCases.filter(\.hasToolsButton), [.stage, .clipboard, .translate, .settings],
            "the Tools button on Clipboard, Translate, Settings and the stage"
        )
    }

    /// Snippets, Calendar, Notes and the Teleprompter were dropped from the
    /// product deliberately, not hidden: no surface, no privacy section, no
    /// store, no strings. The rail went with R8; the absence is still asserted
    /// rather than assumed (§19.11).
    func testDroppedFeaturesAreAbsentEntirely() {
        let names = Surface.allCases.map(\.rawValue)
        for dropped in ["snippets", "calendar", "notes", "teleprompter", "prompter"] {
            XCTAssertFalse(names.contains(dropped), "\(dropped) came back as a surface")
        }
        XCTAssertEqual(PrivacyMode.Section.allCases.map(\.rawValue).sorted(), ["clipboard", "translate"])
    }

    /// Every glyph a surface's header draws resolves: a name macOS does not
    /// know draws nothing at all.
    func testEveryHeaderGlyphResolves() {
        for surface in Surface.allCases {
            guard let symbol = surface.symbol else { continue }
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(symbol) for \(surface)")
        }
        XCTAssertEqual(Surface.clipboard.symbol, "doc.on.clipboard")
        XCTAssertEqual(Surface.translate.symbol, "translate")
        XCTAssertEqual(Surface.settings.symbol, "gearshape")
    }

    // MARK: Sizes (§19.6–§19.8)

    /// Each surface has one size. The player and the tray keep their measured
    /// shapes, shoulders included; the summoned surfaces run the panel's
    /// width; Tools is 480. Every height is the reference's at a 38 pt notch
    /// and moves with the notch, as the expanded alerts' do.
    func testEachSurfaceHasOneSize() {
        let notch = CGSize(width: 185, height: 38)
        func size(_ surface: Surface, _ bw: CGFloat = 560, _ notch: CGSize = notch) -> CGSize {
            SurfaceLayout.bodySize(for: surface, bodyWidth: bw, notch: notch)
        }
        XCTAssertEqual(size(.player).width, 425.4 - 68, accuracy: 0.001, "425.4 with its 34 pt shoulders")
        XCTAssertEqual(size(.player).height, 198, accuracy: 0.001)
        XCTAssertEqual(size(.stage), CGSize(width: 560, height: 400))
        XCTAssertEqual(size(.tray).width, 433.3 - 48, accuracy: 0.001, "433.3 with its 24 pt shoulders")
        XCTAssertEqual(size(.tray).height, 158, accuracy: 0.001)
        XCTAssertEqual(size(.drop), CGSize(width: 560, height: 176))
        XCTAssertEqual(size(.tools), CGSize(width: 480, height: 204))
        XCTAssertEqual(size(.clipboard), CGSize(width: 560, height: 300))
        XCTAssertEqual(size(.translate), CGSize(width: 560, height: 268))
        XCTAssertEqual(size(.settings), CGSize(width: 560, height: 400))
        XCTAssertEqual(size(.welcome), CGSize(width: 560, height: NotchMetrics.standardBodyHeight))

        // The panel's width moves only the surfaces that run it.
        XCTAssertEqual(size(.stage, 480).width, 480)
        XCTAssertEqual(size(.settings, 620).width, 620)
        XCTAssertEqual(size(.player, 620).width, size(.player, 480).width, accuracy: 0.001)
        XCTAssertEqual(size(.tools, 620).width, 480)

        // A 32 pt notch takes six points off every height; the content keeps
        // its distance from the header row.
        let short = CGSize(width: 185, height: 32)
        XCTAssertEqual(size(.player, 560, short).height, 192, accuracy: 0.001)
        XCTAssertEqual(size(.stage, 560, short).height, 394, accuracy: 0.001)

        // Never narrower than the notch plus 20 (§19.2).
        XCTAssertGreaterThanOrEqual(size(.player, 560, CGSize(width: 400, height: 38)).width, 420)

        for surface in Surface.allCases {
            let shape = CGSize(width: size(surface, 620).width + 2 * surface.topRadius, height: size(surface, 620).height)
            XCTAssertLessThanOrEqual(shape.width, NotchMetrics.maximumWindow.width, "\(surface) fits the window's single cut")
            XCTAssertLessThanOrEqual(shape.height, NotchMetrics.maximumWindow.height, "\(surface)")
        }
    }

    func testRadii() {
        for surface in Surface.allCases {
            switch surface {
            case .tray, .drop:
                XCTAssertEqual(surface.topRadius, 24)
                XCTAssertEqual(surface.bottomRadius, 34)
            default:
                XCTAssertEqual(surface.topRadius, 34, "\(surface)")
                XCTAssertEqual(surface.bottomRadius, 44, "\(surface)")
            }
        }
    }

    // MARK: What a click opens (§19.1's first table)

    /// A click opens what the island shows; an alert folds instead.
    func testAClickOpensWhatTheIslandShowsAndFoldsAnAlert() {
        let hud = HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil))
        XCTAssertEqual(NotchViewModel.click(on: .hud(hud), live: .music), .foldAlert)
        XCTAssertEqual(NotchViewModel.click(on: .ambient(.charging(level: 80, isCharging: true)), live: .none), .foldAlert)
        XCTAssertEqual(NotchViewModel.click(on: .ambient(.headphones(name: "AirPods", symbol: "airpods.pro")), live: .shelf(count: 2)), .foldAlert)
        XCTAssertEqual(NotchViewModel.click(on: .peek, live: .music), .open(.player), "the peek opens the player")
        XCTAssertEqual(NotchViewModel.click(on: .music, live: .music), .open(.player))
        XCTAssertEqual(NotchViewModel.click(on: .shelf(count: 3), live: .shelf(count: 3)), .open(.tray))
        XCTAssertEqual(NotchViewModel.click(on: .none, live: .none), .open(.tools), "the bare notch opens Tools")

        // ⌃⌥⌘I and Open on Hover open what a click would — and over an alert,
        // what the click would open once it folds: the live activity under it.
        XCTAssertEqual(NotchViewModel.openTarget(live: .music), .player)
        XCTAssertEqual(NotchViewModel.openTarget(live: .peek), .player)
        XCTAssertEqual(NotchViewModel.openTarget(live: .shelf(count: 1)), .tray)
        XCTAssertEqual(NotchViewModel.openTarget(live: .none), .tools)

        // A paused song whose island has folded is not live, but it is still a
        // song: the bare notch over it opens the player, not Tools.
        XCTAssertEqual(NotchViewModel.openTarget(live: .none, hasTrack: true), .player)
        XCTAssertEqual(NotchViewModel.click(on: .none, live: .none, hasTrack: true), .open(.player))
        XCTAssertEqual(NotchViewModel.openTarget(live: .shelf(count: 2), hasTrack: true), .tray, "a live Shelf outranks a folded song")
    }

    // MARK: Every road (§19.1's second table)

    func testEveryRoadToEverySurface() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)

        // Tools: a click on the bare notch, ⌃⌥⌘I with nothing live.
        XCTAssertEqual(vm.openTarget, .tools)
        vm.clickOpened(pointerIsOnPanel: true)
        XCTAssertEqual(vm.surface, .tools)

        // The player: a click on Music, ⌃⌥⌘I while it plays.
        isolated.stores.media.apply(playing())
        XCTAssertEqual(vm.openTarget, .player)
        vm.clickOpened(pointerIsOnPanel: true)
        XCTAssertEqual(vm.surface, .player)

        // The stage: a click on the player's cover or title, ⌃⌥⌘L, the menu's
        // Lyrics. Hide Lyrics turns it back into the player.
        vm.openStage()
        XCTAssertEqual(vm.surface, .stage)
        XCTAssertTrue(vm.isShowingLyrics)
        vm.hideLyrics()
        XCTAssertEqual(vm.surface, .player)

        // The tray: the bubble, the Shelf activity, the menu, the Tools card.
        vm.clickOpened(pointerIsOnPanel: true, opening: .tray)
        XCTAssertEqual(vm.surface, .tray)

        // Clipboard, Translate and Settings from the Tools cards, the menu and
        // the gear; each takes or gives back the keyboard as it should.
        vm.open(.clipboard)
        XCTAssertEqual(vm.surface, .clipboard)
        XCTAssertTrue(vm.wantsKeyboard, "Clipboard takes the keyboard when it opens (§19.8)")
        vm.open(.translate)
        XCTAssertTrue(vm.wantsKeyboard)
        vm.open(.settings)
        XCTAssertEqual(vm.surface, .settings)
        XCTAssertFalse(vm.wantsKeyboard, "Settings does not hold the keyboard on arrival")
        vm.open(.tools)
        XCTAssertEqual(vm.surface, .tools)

        // The Translate service and ⌃⌥⌘T land on Translate.
        vm.receiveCommandedTranslation(Translator.prepareCommandInput("bonjour"))
        XCTAssertEqual(vm.surface, .translate)
    }

    /// The drop surface and the welcome are presented, not chosen: the
    /// surface underneath stays what it was, and comes back when they end.
    func testTheDropSurfaceAndTheWelcomeArePresentedOverTheChoice() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)
        vm.open(.clipboard)
        vm.isDropTargeted = true
        XCTAssertEqual(vm.presented, .drop)
        XCTAssertEqual(vm.surface, .clipboard)
        vm.isDropTargeted = false
        XCTAssertEqual(vm.presented, .clipboard)

        vm.isShowingWelcome = true
        XCTAssertEqual(vm.presented, .welcome)
        vm.open(.drop)
        vm.open(.welcome)
        XCTAssertEqual(vm.surface, .clipboard, "neither can be chosen")
    }

    /// The stage with nothing playing is the empty player: there is no song
    /// to put words to, and an empty stage is 400 tall for nothing.
    func testTheStageWithNothingPlayingIsTheEmptyPlayer() throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try geometry(), stores: isolated.stores)
        vm.openStage()
        XCTAssertEqual(vm.surface, .stage, "asked for")
        XCTAssertEqual(vm.presented, .player, "shown as the empty player")
        isolated.stores.media.apply(playing())
        XCTAssertEqual(vm.presented, .stage)
    }
}
