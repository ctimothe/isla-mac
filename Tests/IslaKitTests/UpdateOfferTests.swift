import AppKit
import Combine
import XCTest
@testable import IslaKit

/// The island's update alert (spec §19.5 f; plan 2026-10-19): a release
/// offered once per version at the first idle moment, Later or Install, 20 s
/// at most unanswered, and after Install the install's own progress until Isla
/// restarts. These hold its words, its place in §19.1's ranks, where its parts
/// sit, what VoiceOver finds, and the controller's offer → show → answer path.
@MainActor
final class UpdateOfferTests: XCTestCase {
    private func release(_ version: String = "0.3.0.1", notes: String = "The island stays at the notch while locked.") -> UpdateCheck.Release {
        let folder = URL(fileURLWithPath: "/tmp/isla-feed")
        return UpdateCheck.Release(
            version: version,
            page: URL(string: "https://github.com/ctimothe/isla-mac/releases/tag/v\(version)")!,
            notes: notes,
            dmg: .init(name: "Isla-\(version).dmg", url: folder.appendingPathComponent("Isla-\(version).dmg"), size: 1000),
            signature: .init(name: "Isla-\(version).dmg.sig", url: folder.appendingPathComponent("Isla-\(version).dmg.sig"), size: 88)
        )
    }

    private func defaults() -> UserDefaults {
        let name = "isla-tests-update-offer-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return suite
    }

    // MARK: The summary

    func testTheSummaryIsTheFirstSentenceOfTheNotes() {
        XCTAssertEqual(UpdateOffer.summary(of: "Lyrics follow the song. The island is quieter."), "Lyrics follow the song.")
        XCTAssertEqual(UpdateOffer.summary(of: "Isla 0.3.1 fixes the lock card! More below."), "Isla 0.3.1 fixes the lock card!",
                       "a version's dots end no sentence")
        XCTAssertEqual(UpdateOffer.summary(of: "No full stop at all"), "No full stop at all")
    }

    /// The notes are Markdown — GitHub's, or the publish script's list of
    /// commit subjects: headings, rules, fences and quotes are not prose, a
    /// list marker comes off, and inline markup reads as its text.
    func testTheSummaryReadsPastMarkdown() {
        XCTAssertEqual(UpdateOffer.summary(of: "## What's new\n\n- The island stays at the notch.\n- More."), "The island stays at the notch.")
        XCTAssertEqual(UpdateOffer.summary(of: "---\n1. **Faster** lyrics with `LRCLIB`. Then more."), "Faster lyrics with LRCLIB.")
        XCTAssertEqual(UpdateOffer.summary(of: "```\ncode here.\n```\n> quoted.\nSee [the page](https://example.com) first."),
                       "See the page first.")
        XCTAssertNil(UpdateOffer.summary(of: ""))
        XCTAssertNil(UpdateOffer.summary(of: "# Only a heading\n\n***\n"))
        XCTAssertEqual(UpdateOffer(release: release(notes: "")).summary, nil, "no notes, no line: the spec omits it")
    }

    // MARK: Once per version

    func testAVersionIsOfferedUntilItIsAnswered() {
        let memory = UpdateOfferMemory(defaults: defaults())
        XCTAssertNil(memory.answered)
        XCTAssertTrue(memory.isUnanswered("0.3.0.1"))
        memory.remember("0.3.0.2")
        XCTAssertFalse(memory.isUnanswered("0.3.0.2"), "that version is not offered here again")
        XCTAssertFalse(memory.isUnanswered("0.3.0.1"), "nor an older one, after a feed is rolled back")
        XCTAssertTrue(memory.isUnanswered("0.3.0.3"), "a newer one is")
        XCTAssertTrue(memory.isUnanswered("0.3.1"))
        XCTAssertEqual(UpdateOfferMemory.key, "updates.offeredVersion")
    }

    // MARK: The stages

    func testTheStageFollowsTheInstaller() {
        let offer = UpdateOffer(release: release())
        func stage(_ phase: UpdateInstaller.Phase, for installing: UpdateCheck.Release? = nil) -> UpdateAlertStage {
            UpdateAlertStage.make(phase: phase, installerRelease: installing ?? offer.release, offer: offer)
        }
        XCTAssertEqual(UpdateAlertStage.make(phase: .idle, installerRelease: nil, offer: offer), .offer)
        XCTAssertEqual(stage(.downloading(received: 250, total: 1000)), .working(localized("Downloading Isla %@…", "0.3.0.1"), progress: 0.25))
        XCTAssertEqual(stage(.downloading(received: 5, total: 0)).progress, 0, "an unknown size is no progress, not a division by zero")
        XCTAssertEqual(stage(.verifying), .working(localized("Verifying…"), progress: 1))
        XCTAssertEqual(stage(.installing), .working(localized("Installing…"), progress: 1))
        XCTAssertEqual(stage(.relaunching), .working(localized("Restarting Isla…"), progress: 1))
        XCTAssertEqual(stage(.restartNeeded), .restartNeeded)
        XCTAssertEqual(stage(.failed(.signature)), .failed(UpdatePresentation.reason(.signature)), "the reason Settings gives")
        XCTAssertEqual(stage(.failed(.cancelled)), .offer, "a cancelled download is back to the offer")
        XCTAssertEqual(stage(.manualOnly(.translocated)), .manual(localized("Isla can't update itself from this location.")))
        XCTAssertEqual(stage(.manualOnly(.noSignature)), .manual(localized("This update can only be installed from its download page.")))

        let older = release("0.3.0.0")
        XCTAssertEqual(stage(.failed(.offline), for: older), .offer, "a failure left from another release is not this one's")
        XCTAssertEqual(stage(.installing, for: older), .working(localized("Installing…"), progress: 1),
                       "busy is busy: Install would be ignored")
        XCTAssertEqual(stage(.downloading(received: 1, total: 2), for: older),
                       .working(localized("Downloading Isla %@…", "0.3.0.0"), progress: 0.5),
                       "and says which version it is downloading, which is not the offer's")
    }

    /// The controller hears the installer's steps, not every byte of the
    /// download: a progress tick is the view's to draw.
    func testTheControllerHearsStepsNotProgress() {
        let step = NotchController.updateStep
        XCTAssertEqual(step(.downloading(received: 1, total: 100)), step(.downloading(received: 99, total: 100)))
        XCTAssertNotEqual(step(.downloading(received: 99, total: 100)), step(.verifying))
        XCTAssertEqual(step(.failed(.offline)), .failed(.offline))
        XCTAssertNotEqual(step(.failed(.offline)), step(.failed(.signature)))
    }

    func testEachStageHasItsButtonsAndItsLines() {
        let summary = "The island stays at the notch."
        XCTAssertEqual(UpdateAlertStage.offer.primary, .install)
        XCTAssertEqual(UpdateAlertStage.offer.detail(summary: summary), summary)
        XCTAssertTrue(UpdateAlertStage.offer.showsRestartNote)
        XCTAssertTrue(UpdateAlertStage.offer.isTimed, "only the offer folds by itself")

        let working = UpdateAlertStage.working("Installing…", progress: 1)
        XCTAssertNil(working.primary, "no buttons while it installs")
        XCTAssertEqual(working.detail(summary: summary), "Installing…")
        XCTAssertTrue(working.showsRestartNote)
        XCTAssertFalse(working.isTimed)

        XCTAssertEqual(UpdateAlertStage.failed("x").primary, .tryAgain)
        XCTAssertEqual(UpdateAlertStage.manual("x").primary, .settings)
        XCTAssertEqual(UpdateAlertStage.restartNeeded.primary, .quit)
        for stage in [UpdateAlertStage.failed("x"), .manual("x"), .restartNeeded] {
            XCTAssertFalse(stage.showsRestartNote, "\(stage) says what happened instead")
            XCTAssertFalse(stage.isTimed, "\(stage) waits for its answer")
            XCTAssertNil(stage.progress)
        }
        XCTAssertEqual(UpdateAlertStage.restartNeeded.detail(summary: summary),
                       localized("Isla has been updated. Quit Isla and open it again to finish."))
        XCTAssertEqual(UpdateAlertAction.later.title, localized("Later"))
        XCTAssertEqual(UpdateAlertAction.install.title, localized("Install"))
        XCTAssertEqual(UpdateAlertAction.quit.title, localized("Quit Isla"))
    }

    // MARK: Its rank (§19.1)

    func testItIsRankNineAnAlertThatQueues() {
        let update = IslandActivity.update(UpdateOffer(release: release()))
        XCTAssertEqual(update.rank, 9)
        XCTAssertTrue(update.isAlert)
        XCTAssertFalse(update.isLive)
        XCTAssertTrue(update.queues)

        let offer = UpdateOffer(release: release())
        let volume = HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil))
        let pods = AmbientActivity.headphones(name: "AirPods", symbol: "airpods")
        func current(hud: HUDMoment? = nil, ambient: AmbientActivity? = nil, peeking: Bool = false) -> IslandActivity {
            IslandActivity.current(hud: hud, ambient: ambient, update: offer, isPeeking: peeking, musicIsVisible: true, shelfCount: 2)
        }
        XCTAssertEqual(current(), .update(offer), "over the song and the Shelf")
        XCTAssertEqual(current(peeking: true), .update(offer), "over a peek")
        XCTAssertEqual(current(ambient: pods), .ambient(pods), "under headphones")
        XCTAssertEqual(current(hud: volume), .hud(volume), "under the pop-up")
        XCTAssertNil(IslandActivity.bubble(beside: .update(offer), shelfCount: 2, isOpen: false, isLocked: false),
                     "no bubble during an alert")
    }

    /// §19.1's two exceptions are the update choice's: it outlives the
    /// second, and a higher alert that replaces it sends it back to wait.
    func testItWaitsPastTheSecondAndReturnsWhenReplaced() {
        let update = IslandActivity.update(UpdateOffer(release: release()))
        let hud = IslandActivity.hud(HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil)))
        let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var queue = IslandAlertQueue()
        XCTAssertEqual(queue.post(update, showing: .none, blocked: true, at: t0), .wait)
        XCTAssertEqual(queue.next(at: t0.addingTimeInterval(600)), update, "a surface open for ten minutes")

        XCTAssertEqual(queue.post(hud, showing: update, blocked: false, at: t0), .show)
        XCTAssertEqual(queue.waiting.map(\.alert), [update], "replaced, it waits for the next idle moment")

        var other = IslandAlertQueue()
        XCTAssertEqual(other.post(.peek, showing: update, blocked: false, at: t0), .wait, "the peek is outranked")
        XCTAssertNil(other.next(at: t0.addingTimeInterval(2)), "and keeps the ordinary second")
    }

    /// Answered by its buttons alone: a click beside them does nothing, and
    /// ⌃⌥⌘I over it opens what the island holds underneath.
    func testAClickBesideItsButtonsIsNotAnAnswer() {
        let update = IslandActivity.update(UpdateOffer(release: release()))
        XCTAssertEqual(NotchViewModel.click(on: update, live: .music, hasTrack: true), .nothing)
        XCTAssertEqual(NotchViewModel.openTarget(live: update, hasTrack: true), .player)
    }

    // MARK: Where its parts sit (§19.5 f)

    private func shapeX(_ x: CGFloat) -> CGFloat { x + ExpandedAlertShape.update.topRadius }

    func testTheShapeIsTheReference() {
        let shape = ExpandedAlertShape.update
        XCTAssertEqual(shape.reference, CGSize(width: 335.4, height: 158))
        XCTAssertEqual(shape.topRadius, 24)
        XCTAssertEqual(shape.bottomRadius, 36)
        let update = IslandActivity.update(UpdateOffer(release: release()))
        XCTAssertEqual(IslandShapeRadii.closed(for: update).top, 24)
        XCTAssertEqual(IslandShapeRadii.closed(for: update).bottom, 36)
        let size = NotchViewModel.updateBodySize(notchSize: CGSize(width: 180, height: 38), bodyWidth: 560)
        XCTAssertEqual(size.width + 48, 335.4, accuracy: 0.001)
        XCTAssertEqual(size.height, 158)
        XCTAssertEqual(NotchViewModel.updateBodySize(notchSize: CGSize(width: 300, height: 32), bodyWidth: 560),
                       CGSize(width: 320, height: 152), "nw + 20 on a wide notch; the depth below a short one")
        XCTAssertTrue(IslandStroke.castsShadow(height: 158))
    }

    func testThePartsSitWhereTheReferenceDoes() {
        let L = UpdateAlertLayout.self
        let size = NotchViewModel.updateBodySize(notchSize: CGSize(width: 180, height: 38), bodyWidth: 560)
        let glyph = L.glyphFrame(notchHeight: 38)
        XCTAssertEqual(shapeX(glyph.minX), 45.5, accuracy: 0.001)
        XCTAssertEqual(glyph.minY, 56)
        XCTAssertEqual(glyph.size, CGSize(width: 38, height: 38))
        XCTAssertEqual(L.glyphSymbol, "arrow.down.circle.fill")
        XCTAssertEqual(shapeX(L.textLeading), 105, accuracy: 0.001)
        XCTAssertEqual(L.titleBaseline(notchHeight: 38), 64)
        XCTAssertEqual(L.titleSize, 14)
        XCTAssertEqual(L.detailBaseline(line: 0, notchHeight: 38), 81.5)
        XCTAssertEqual(L.detailBaseline(line: 1, notchHeight: 38), 95.5, "a line height of 14")
        XCTAssertEqual(L.detailSize, 11)
        XCTAssertEqual(L.detailOpacity, 0.55)

        let later = L.laterFrame(notchHeight: 38)
        XCTAssertEqual(shapeX(later.minX), 35, accuracy: 0.001)
        XCTAssertEqual(later.minY, 113)
        XCTAssertEqual(later.size, CGSize(width: 128, height: 35))
        let install = L.installFrame(islandWidth: size.width, notchHeight: 38)
        XCTAssertEqual(shapeX(install.minX), 173, accuracy: 0.001)
        XCTAssertEqual(install.minY, 113)
        XCTAssertEqual(install.width, 127.4, accuracy: 0.001)
        XCTAssertEqual(install.height, 35)
        XCTAssertEqual(L.textLeading + L.textWidth(islandWidth: size.width), install.maxX, accuracy: 0.001,
                       "the text ends where Install does")

        let progress = L.progressFrame(islandWidth: size.width, notchHeight: 38)
        XCTAssertEqual(progress.minX, later.minX)
        XCTAssertEqual(progress.maxX, install.maxX, accuracy: 0.001)
        XCTAssertEqual(progress.midY, later.midY)
    }

    /// A notch that needs a wider shape keeps the leading parts where they
    /// were and takes Install with the right edge; a shorter one moves
    /// everything up by the difference.
    func testOnAWiderOrShorterNotchThePartsFollow() {
        let L = UpdateAlertLayout.self
        let wide = NotchViewModel.updateBodySize(notchSize: CGSize(width: 300, height: 38), bodyWidth: 560)
        let install = L.installFrame(islandWidth: wide.width, notchHeight: 38)
        XCTAssertEqual(wide.width - install.maxX + 24, 35, accuracy: 0.001, "right 35 on any width")
        XCTAssertEqual(shapeX(L.laterFrame(notchHeight: 38).minX), 35, accuracy: 0.001)
        XCTAssertEqual(L.laterFrame(notchHeight: 32).minY, 113 - 6)
        XCTAssertEqual(L.titleBaseline(notchHeight: 32), 64 - 6)
    }

    // MARK: The pointer

    /// Open on Hover does not open the panel over it: the pointer is on its
    /// way to a button.
    func testThePointerArrivingDoesNotOpenThePanelOverIt() throws {
        let defaults = UserDefaults.standard
        let had = defaults.object(forKey: NotchViewModel.opensOnHoverKey)
        defaults.set(true, forKey: NotchViewModel.opensOnHoverKey)
        defer {
            if let had { defaults.set(had, forKey: NotchViewModel.opensOnHoverKey) }
            else { defaults.removeObject(forKey: NotchViewModel.opensOnHoverKey) }
        }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        XCTAssertEqual(vm.pointerCrossed(inside: true), .opens, "the setting is on")
        vm.updateOffer = UpdateOffer(release: release())
        XCTAssertEqual(vm.pointerCrossed(inside: true), .standsAsItIs)
    }

    func testWhenAnOwedOfferMayShow() {
        func timing(pointer: Bool = false, asleep: Bool = false, locked: Bool = false, quiet: Bool = false)
            -> NotchController.UpdateOfferTiming {
            NotchController.updateOfferTiming(pointerUnderAlert: pointer, screensAsleep: asleep, locked: locked, quiet: quiet)
        }
        XCTAssertEqual(timing(), .now)
        XCTAssertEqual(timing(pointer: true), .retry(2), "not grown under a still pointer; it moves on in a moment")
        XCTAssertEqual(timing(quiet: true), .retry(60), "not over a film or a talk")
        XCTAssertEqual(timing(pointer: true, locked: true, quiet: true), .atUnlock,
                       "not under the shield, where nobody sees it fold and it would count as answered")
        XCTAssertEqual(timing(pointer: true, asleep: true, locked: true, quiet: true), .atWake, "no timer for a dark display")
        XCTAssertEqual(NotchController.updateOfferHoldDefault, 20, "at most 20 s unanswered")
    }

    // MARK: The controller

    private struct Harness {
        let vm: NotchViewModel
        let controller: NotchController
        let memory: UpdateOfferMemory
        var installs: () -> [(String, Bool)]
    }

    private func harness(available: UpdateCheck.Release?) throws -> Harness {
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores())
        let root = NotchRootView(frame: CGRect(origin: .zero, size: vm.geometry.windowSize))
        let controller = NotchController()
        controller.pointer.buttonsHeld = { false }
        controller.attachForTesting(viewModel: vm, rootView: root)
        // Far from the notch, wherever the real pointer is.
        controller.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
        controller.updateMomentsQuiet = { false }
        controller.updateScreenLocked = { false }
        let memory = UpdateOfferMemory(defaults: defaults())
        controller.updateOfferMemory = memory
        controller.availableUpdate = { available }
        controller.installerState = { (.idle, nil) }
        controller.quitApp = { XCTFail("a test never quits") }
        var installs: [(String, Bool)] = []
        controller.installUpdate = { release, retry in installs.append((release.version, retry)) }
        return Harness(vm: vm, controller: controller, memory: memory, installs: { installs })
    }

    private func spin(until condition: () -> Bool, within seconds: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testAnOfferShowsAndLaterRemembersIt() throws {
        let h = try harness(available: release())
        h.controller.considerUpdateOffer()
        XCTAssertEqual(h.vm.updateOffer?.version, "0.3.0.1", "shown at once on an idle island")
        XCTAssertEqual(h.vm.activity, .update(UpdateOffer(release: release())))
        h.controller.updateAlertAction(.later)
        XCTAssertNil(h.vm.updateOffer, "Later folds it")
        XCTAssertFalse(h.memory.isUnanswered("0.3.0.1"), "and remembers it")
        h.controller.considerUpdateOffer()
        XCTAssertNil(h.vm.updateOffer, "not offered here again")
    }

    func testUnansweredItFoldsAfterItsHoldAndIsRemembered() throws {
        let h = try harness(available: release())
        h.controller.updateOfferHold = 0.1
        h.controller.considerUpdateOffer()
        XCTAssertNotNil(h.vm.updateOffer)
        spin(until: { h.vm.updateOffer == nil })
        XCTAssertNil(h.vm.updateOffer, "20 s without an answer folds it")
        XCTAssertFalse(h.memory.isUnanswered("0.3.0.1"))
    }

    /// Install is not an answer until it ends, and the alert stays, untimed,
    /// following the install.
    func testInstallRunsTheInstallerAndTheAlertStays() throws {
        let h = try harness(available: release())
        h.controller.updateOfferHold = 0.1
        h.controller.considerUpdateOffer()
        h.controller.updateAlertAction(.install)
        XCTAssertEqual(h.installs().map(\.0), ["0.3.0.1"])
        XCTAssertEqual(h.installs().map(\.1), [false])
        h.controller.installerState = { (.downloading(received: 10, total: 100), self.release()) }
        spin(until: { false }, within: 0.3)
        XCTAssertNotNil(h.vm.updateOffer, "no hold while it installs")
        XCTAssertTrue(h.memory.isUnanswered("0.3.0.1"), "a Mac that restarts midway is asked again")

        h.controller.installerState = { (.failed(.offline), self.release()) }
        h.controller.updateAlertAction(.tryAgain)
        XCTAssertEqual(h.installs().map(\.1), [false, true], "Try Again resets, then installs")
    }

    /// A surface opened over it takes it down, unanswered; it comes back when
    /// the panel closes.
    func testOpenedOverItReturnsWhenThePanelCloses() throws {
        let h = try harness(available: release())
        h.controller.considerUpdateOffer()
        XCTAssertNotNil(h.vm.updateOffer)
        h.vm.isOpen = true
        XCTAssertNil(h.vm.updateOffer, "the open takes it down")
        h.controller.considerUpdateOffer()
        XCTAssertNil(h.vm.updateOffer, "not over an open panel")
        h.vm.isOpen = false
        h.controller.considerUpdateOffer()
        XCTAssertEqual(h.vm.updateOffer?.version, "0.3.0.1", "back once the island is free")
        XCTAssertTrue(h.memory.isUnanswered("0.3.0.1"))
    }

    /// A click beside the buttons does nothing; the panel stays shut.
    func testAClickOnTheAlertOpensNothing() throws {
        let h = try harness(available: release())
        h.controller.considerUpdateOffer()
        h.controller.islandClicked()
        XCTAssertFalse(h.vm.isOpen)
        XCTAssertNotNil(h.vm.updateOffer)
    }

    /// While it is only an offer, a newer release takes its place and a
    /// withdrawn one takes it down — unanswered, so it is not remembered.
    func testAWithdrawnOrNewerReleaseChangesTheOffer() throws {
        let h = try harness(available: release())
        h.controller.considerUpdateOffer()
        h.controller.availableUpdate = { self.release("0.3.0.2") }
        h.controller.considerUpdateOffer()
        XCTAssertEqual(h.vm.updateOffer?.version, "0.3.0.2")
        h.controller.availableUpdate = { nil }
        h.controller.considerUpdateOffer()
        XCTAssertNil(h.vm.updateOffer)
        XCTAssertNil(h.memory.answered, "taken back, not answered")
    }

    /// With the lock card off nothing marks the island locked
    /// (`isLockedPresentation` stays false), so the lock itself is asked: an
    /// offer shown under the shield folded unseen after 20 s and was
    /// remembered as answered. It waits for the unlock instead, with no timer
    /// running through the lock, and the unlock asks for it.
    func testLockedWithTheCardOffItWaitsForTheUnlock() throws {
        let h = try harness(available: release())
        h.controller.updateScreenLocked = { true }
        h.controller.considerUpdateOffer()
        XCTAssertNil(h.vm.updateOffer, "not under the shield")
        XCTAssertTrue(h.memory.isUnanswered("0.3.0.1"), "still owed")
        h.controller.updateScreenLocked = { false }
        h.controller.considerUpdateOffer()
        XCTAssertEqual(h.vm.updateOffer?.version, "0.3.0.1", "offered once the Mac is unlocked")

        let source = try String(
            contentsOf: VisualLab.repositoryRoot.appendingPathComponent("Sources/IslaKit/Notch/NotchController.swift"),
            encoding: .utf8
        )
        let unlock = try XCTUnwrap(source.range(of: "private func screenUnlocked() {"))
        let body = source[unlock.upperBound...].prefix(4000)
        let end = body.range(of: "\n    }\n")?.lowerBound ?? body.endIndex
        XCTAssertTrue(body[..<end].contains("updateScreenSeenAgain()"),
                      "the unlock asks for what it held back, on the path the screen saver's end takes")
    }

    /// Behind the screen saver inside its password grace, or with another
    /// user switched in, the Mac is not locked but nobody sees the island: an
    /// offer shown there folded unseen and was remembered as answered (review,
    /// 2026-10-19). It is taken down unanswered when either begins, waits, and
    /// is offered again a pass after the screen is seen.
    func testBehindTheScreenSaverOrAnotherUserItWaitsUntilTheScreenIsSeen() throws {
        let h = try harness(available: release())
        h.controller.considerUpdateOffer()
        XCTAssertNotNil(h.vm.updateOffer)

        h.controller.screenSaverChanged(running: true)
        XCTAssertNil(h.vm.updateOffer, "taken down when the screen saver starts")
        h.controller.considerUpdateOffer()
        XCTAssertNil(h.vm.updateOffer, "not shown behind it")
        XCTAssertTrue(h.memory.isUnanswered("0.3.0.1"), "and not answered")
        h.controller.screenSaverChanged(running: false)
        XCTAssertNil(h.vm.updateOffer, "a pass later, not inside the notification")
        spin(until: { h.vm.updateOffer != nil })
        XCTAssertEqual(h.vm.updateOffer?.version, "0.3.0.1", "offered again once it stops")

        h.controller.sessionActiveChanged(false)
        XCTAssertNil(h.vm.updateOffer, "taken down when another user is switched in")
        h.controller.considerUpdateOffer()
        XCTAssertNil(h.vm.updateOffer, "not shown in a session nobody is at")
        h.controller.sessionActiveChanged(true)
        spin(until: { h.vm.updateOffer != nil })
        XCTAssertEqual(h.vm.updateOffer?.version, "0.3.0.1", "offered again on the way back")
        XCTAssertTrue(h.memory.isUnanswered("0.3.0.1"))
    }

    /// The pop-up outranks it (§19.1): the offer gives way unanswered and
    /// returns, with a fresh hold, when the pop-up folds. A release that
    /// overtook it meanwhile is what returns — the replaced one is asked again
    /// before it is shown, and never comes back for a frame first.
    func testAPopUpReplacesItAndItReturnsWhenThePopUpFolds() throws {
        let h = try harness(available: release())
        h.controller.hudFoldDelay = 0.15
        var shown: [String?] = []
        let watch = h.vm.$updateOffer.map { $0?.version }.removeDuplicates().sink { shown.append($0) }
        defer { watch.cancel() }
        let key = HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil)

        h.controller.considerUpdateOffer()
        h.controller.presentHUD(key)
        XCTAssertNotNil(h.vm.hud)
        XCTAssertNil(h.vm.updateOffer, "the pop-up takes its place")
        XCTAssertTrue(h.memory.isUnanswered("0.3.0.1"), "replaced is not answered")
        spin(until: { h.vm.hud == nil && h.vm.updateOffer != nil })
        XCTAssertEqual(h.vm.updateOffer?.version, "0.3.0.1", "back when the pop-up folds")

        h.controller.presentHUD(key)
        h.controller.availableUpdate = { self.release("0.3.0.2") }
        spin(until: { h.vm.hud == nil && h.vm.updateOffer != nil })
        XCTAssertEqual(h.vm.updateOffer?.version, "0.3.0.2", "the newer release returns")
        XCTAssertEqual(shown, [nil, "0.3.0.1", nil, "0.3.0.1", nil, "0.3.0.2"], "the overtaken one is never shown again")
    }

    /// Once Install is pressed the alert belongs to that install until it
    /// ends. A newer build landing meanwhile, and a pop-up taking the alert's
    /// place for a moment, brought the alert back titled as the newer build
    /// over the older one's progress (Codex review, 2026-10-19). It comes back
    /// as the release being installed; the newer one waits for the install to
    /// end.
    func testAnInstallUnderWayKeepsItsAlertWhateverLandsMeanwhile() throws {
        let h = try harness(available: release())
        h.controller.hudFoldDelay = 0.15
        var shown: [String?] = []
        let watch = h.vm.$updateOffer.map { $0?.version }.removeDuplicates().sink { shown.append($0) }
        defer { watch.cancel() }

        h.controller.considerUpdateOffer()
        h.controller.updateAlertAction(.install)
        h.controller.installerState = { (.downloading(received: 10, total: 100), self.release()) }
        h.controller.availableUpdate = { self.release("0.3.0.2") }
        h.controller.considerUpdateOffer()
        XCTAssertEqual(h.vm.updateOffer?.version, "0.3.0.1", "up, it stays the install's")

        h.controller.presentHUD(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil))
        XCTAssertNil(h.vm.updateOffer)
        spin(until: { h.vm.hud == nil && h.vm.updateOffer != nil })
        XCTAssertEqual(h.vm.updateOffer?.version, "0.3.0.1", "back as the release being installed")
        XCTAssertFalse(shown.contains("0.3.0.2"), "the newer build is not offered over an install: \(shown)")

        h.controller.installerState = { (.failed(.offline), self.release()) }
        h.controller.considerUpdateOffer()
        XCTAssertEqual(h.vm.updateOffer?.version, "0.3.0.1", "its failure stays up for an answer")
    }

    func testNothingIsOfferedWithoutAnUpdate() throws {
        let h = try harness(available: nil)
        h.controller.considerUpdateOffer()
        XCTAssertNil(h.vm.updateOffer)
    }

    // MARK: VoiceOver

    /// One container named by its title, with its buttons inside — the
    /// island's own Isla button would hide them — and Install reaches the
    /// controller.
    func testVoiceOverFindsTheAlertAndItsButtons() async throws {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(physical: true), stores: isolated.stores)
        vm.updateOffer = UpdateOffer(release: release())
        var actions: [UpdateAlertAction] = []
        vm.onUpdateAction = { actions.append($0) }

        let root = await AXProbe.tree(of: NotchContentView(vm: vm), size: CGSize(width: VisualLab.windowSize.width, height: 200))
        let title = localized("Isla %@ is ready", "0.3.0.1")
        XCTAssertEqual(root.all { $0.label == title }.count, 1, "named once, not read twice\n\(root.dump)")
        let buttons = root.all(role: "AXButton")
        let later = try XCTUnwrap(buttons.first { $0.label == localized("Later") }, root.dump)
        let install = try XCTUnwrap(buttons.first { $0.label == localized("Install") }, root.dump)
        XCTAssertTrue(buttons.allSatisfy { $0.label != ProductIdentity.displayName }, "the island stands aside\n\(root.dump)")
        XCTAssertTrue(install.press(), root.dump)
        XCTAssertTrue(later.press(), root.dump)
        XCTAssertEqual(actions, [.install, .later])
    }
}
