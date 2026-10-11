import SwiftUI
import XCTest
@testable import IslaKit

/// Lyric Delay tuned while watching the line (LY-16, L-02).
///
/// The by-ear correction is the only real measurement of the gap between the
/// player's position and the voice reaching the ear, and the control that
/// sets it sat in Settings with no lyric in sight: a ±3 s slider at about
/// 0.04 s a point, so every move meant a trip to the Music tab and back.
/// The row now shows the line the caption would draw, steps in 0.05 s, and
/// says the value as a direction rather than as a sign.
@MainActor
final class LyricDelayCopyTests: XCTestCase {

    // MARK: Copy and steps

    /// "+0.25" is a sign the listener has to decode, and until LY-01 the sign
    /// ran backwards. A direction cannot be misread: later, earlier, or on
    /// time.
    func testTheDelayIsSpokenAsADirection() {
        XCTAssertEqual(LyricDelayCopy.value(0.25), localized("%.2f s later", 0.25))
        XCTAssertEqual(LyricDelayCopy.value(-0.1), localized("%.2f s earlier", 0.1))
        XCTAssertEqual(LyricDelayCopy.value(0), localized("On time"))
        // A slider drag can leave a residue too small to print. "0.00 s
        // later" names a direction the lyric is not moved in.
        XCTAssertEqual(LyricDelayCopy.value(0.004), localized("On time"))
        XCTAssertEqual(LyricDelayCopy.value(-0.004), localized("On time"))
        XCTAssertEqual(LyricDelayCopy.value(0.25), "0.25 s later", "the English table reads it in full")
    }

    /// One step is 0.05 s, under a third of the −125/+45 ms window in which
    /// an offset goes unnoticed, and the ends are the store's ±3 s.
    func testAStepIsFiveHundredthsAndStopsAtTheEnds() {
        XCTAssertEqual(LyricDelayStep.next(0.20, later: true), 0.25)
        XCTAssertEqual(LyricDelayStep.next(0.20, later: false), 0.15)
        XCTAssertEqual(LyricDelayStep.next(0, later: false), -0.05)
        XCTAssertEqual(LyricDelayStep.next(2.98, later: true), 3.0)
        XCTAssertEqual(LyricDelayStep.next(3.0, later: true), 3.0)
        XCTAssertEqual(LyricDelayStep.next(-2.98, later: false), -3.0)
        // The slider leaves values off the grid; a step lands back on it
        // rather than carrying 0.0347 along forever.
        XCTAssertEqual(LyricDelayStep.next(0.2347, later: true), 0.25)
        XCTAssertEqual(LyricDelayStep.next(0.2347, later: false), 0.20)
        // A value already on the grid, read back through binary floating
        // point, still moves by exactly one step.
        XCTAssertEqual(LyricDelayStep.next(0.1 + 0.2, later: true), 0.35)
        XCTAssertEqual(LyricDelayStep.next(0.1 + 0.2, later: false), 0.25)
    }

    // MARK: The row

    /// The Earlier and Later buttons move the stored global correction by a
    /// step each, positive meaning later (LY-01).
    func testTheButtonsStepTheDelay() async {
        let fixture = Fixture()
        defer { fixture.release() }
        let root = await fixture.tree()
        guard let later = root.first(label: localized("Later")),
              let earlier = root.first(label: localized("Earlier")) else {
            return XCTFail("no Earlier or Later\n\(root.dump)")
        }
        XCTAssertTrue(later.press(), root.dump)
        await AXProbe.wait(0.05)
        XCTAssertEqual(fixture.lyrics.userOffset, 0.05, accuracy: 1e-9)
        XCTAssertTrue(earlier.press(), root.dump)
        XCTAssertTrue(earlier.press(), root.dump)
        await AXProbe.wait(0.05)
        XCTAssertEqual(fixture.lyrics.userOffset, -0.05, accuracy: 1e-9)
    }

    /// VoiceOver's increment is a step too, not the slider's own tenth of
    /// the range (0.6 s, wider than the whole window in which an offset goes
    /// unnoticed), and the value it then speaks is a direction.
    func testAVoiceOverStepMovesTheDelayByOneStep() async {
        let fixture = Fixture()
        defer { fixture.release() }
        fixture.lyrics.userOffset = 0.20
        let root = await fixture.tree()
        guard let slider = root.all(role: "AXSlider").first(where: { $0.label == localized("Lyric Delay") }) else {
            return XCTFail("no Lyric Delay slider\n\(root.dump)")
        }
        XCTAssertEqual(Self.spoken(slider), localized("%.2f s later", 0.20), root.dump)
        XCTAssertTrue(Self.perform(slider.element, "accessibilityPerformIncrement"), root.dump)
        await AXProbe.wait(0.1)
        XCTAssertEqual(fixture.lyrics.userOffset, 0.25, accuracy: 1e-9)

        let after = await root.reread()
        guard let again = after.all(role: "AXSlider").first(where: { $0.label == localized("Lyric Delay") }) else {
            return XCTFail("no Lyric Delay slider\n\(after.dump)")
        }
        XCTAssertEqual(Self.spoken(again), localized("%.2f s later", 0.25), after.dump)
        for _ in 0..<6 { _ = Self.perform(again.element, "accessibilityPerformDecrement") }
        await AXProbe.wait(0.1)
        XCTAssertEqual(fixture.lyrics.userOffset, -0.05, accuracy: 1e-9)
    }

    /// While a song with lyrics plays, the row shows the line the caption
    /// would draw at this moment, through the same delay — so moving the
    /// delay moves the line, which is the whole point of the preview.
    func testThePreviewShowsTheLineThePanelShowsAndFollowsTheDelay() async {
        let fixture = Fixture()
        defer { fixture.release() }
        await LabFixtures.play(LabFixtures.Track(elapsed: 25, cover: nil), on: fixture.media)
        fixture.lyrics.present(LabFixtures.timeline())
        let root = await fixture.tree()
        // 25 s plus the 0.2 s lead is inside the line stamped at 24 s.
        XCTAssertFalse(root.all { $0.value == "Sit in the waiting room again" }.isEmpty, root.dump)
        XCTAssertFalse(root.all { $0.value == localized("Move until the line lights with the voice.") }.isEmpty, root.dump)

        // Three seconds later puts the lyric moment at 22.2 s: the line
        // before. The panel would draw that one, so the preview does.
        fixture.lyrics.userOffset = 3
        let later = await root.reread(settle: 0.25)
        XCTAssertFalse(later.all { $0.value == "Walk the length of the block and back" }.isEmpty, later.dump)
    }

    /// Paused, there is no voice to line anything up with, so there is no
    /// preview and no instruction to follow one.
    func testThePreviewIsHiddenWhilePaused() async {
        let fixture = Fixture()
        defer { fixture.release() }
        var track = LabFixtures.Track(elapsed: 25, cover: nil)
        track.playing = false
        await LabFixtures.play(track, on: fixture.media)
        fixture.lyrics.present(LabFixtures.timeline())
        let root = await fixture.tree()
        XCTAssertTrue(root.all { $0.value == "Sit in the waiting room again" }.isEmpty, root.dump)
        XCTAssertTrue(root.all { $0.value == localized("Move until the line lights with the voice.") }.isEmpty, root.dump)
        // The steppers are there whatever plays.
        XCTAssertNotNil(root.first(label: localized("Later")), root.dump)
    }

    /// The preview reads the clock through a timeline of its own, never by
    /// observing the media controller: that observation redrew all of
    /// Settings ten times a second (F-015, MS-12).
    func testNeitherThePaneNorThePreviewObservesTheMediaController() {
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let stores = isolated.stores
        let pane = SettingsPane(
            shelf: stores.shelf, screenshotVault: stores.screenshotVault, lyrics: stores.lyrics,
            media: stores.media, localLyrics: stores.localLyricsLibrary, privacy: stores.privacy,
            hotKeys: HotKeyCenter(defaults: isolated.suite, registrar: { _, _ in nil }),
            updates: UpdateCheck(fetch: { _ in throw URLError(.notConnectedToInternet) })
        )
        let controls = LyricDelayControls(lyrics: stores.lyrics, media: stores.media)
        for (name, view) in [("SettingsPane", pane as Any), ("LyricDelayControls", controls as Any)] {
            let observed = Mirror(reflecting: view).children.filter { $0.value is ObservedObject<MediaController> }
            XCTAssertTrue(observed.isEmpty, "\(name) observes MediaController through \(observed.map { $0.label ?? "?" })")
        }
    }

    // MARK: Support

    /// The controls over a lyric store of their own: a private defaults
    /// suite and a temporary offsets folder, so no step a test takes lands
    /// in the xctest defaults domain or the owner's support folder.
    @MainActor
    private final class Fixture {
        let isolated = ProbeFixtures.isolatedStores()
        let lyrics: LyricsStore
        var media: MediaController { isolated.stores.media }

        init() {
            lyrics = LyricsStore(
                offsetsDirectory: isolated.temp.appendingPathComponent("delay-offsets", isDirectory: true),
                defaults: isolated.suite
            )
        }

        func tree() async -> AXNode {
            await AXProbe.tree(
                of: VStack(spacing: 0) { LyricDelayControls(lyrics: lyrics, media: media) }
                    .frame(width: 440, alignment: .top),
                size: CGSize(width: 440, height: 120)
            )
        }

        func release() { isolated.release() }
    }

    /// What VoiceOver speaks as a slider's value: its value description when
    /// it has one, which is where SwiftUI puts a declared value.
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
