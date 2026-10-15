import XCTest

/// Reduce Motion asks for travel to stop, not for change to stop being shown.
///
/// `.animation(reduceMotion ? nil : …)` was the app's reflex answer to the
/// setting, and in most places it answered the wrong question: the lock card's
/// cover light, its output picker and the stage's sync pill and row brightening
/// are fades, and a fade is not motion. Cut to nil, they snapped — the output
/// picker blinked on over the card, the sung line lit with no transition — so
/// the people who asked for calm got the most abrupt surfaces in the app
/// (F-055). Those sites now fade on `Theme.contentAnimation` either way.
///
/// What is left cuts because something in it would *travel* under any
/// animation, and each of those is listed below with its reason. The scan is
/// brittle by design, like `test-branding.sh`: a new `reduceMotion ? nil`
/// fails here until somebody writes down why it is geometry and not a fade.
final class ReduceMotionContractTests: XCTestCase {

    private struct Allowed {
        let file: String
        let line: String
        let count: Int
        let reason: String
    }

    private static let allowed: [Allowed] = [
        Allowed(
            file: "LockScreenCard.swift",
            line: ".animation(jump || reduceMotion ? nil : Theme.lyricScroll, value: centre)",
            count: 1,
            reason: "the lock card's lyric window: with the travel refused the leaving line only "
                + "faded while the rest still slid a row, so two lines shared one slot. (Redesign "
                + "2026-10-15, spec §7: the header's travel and the pane swap no longer cut under "
                + "Reduce Motion — the banner/card morph gives each form an identity and crossfades, "
                + "`LockScreenCard.stage` — so only the window's glide is left here.)"
        ),
        Allowed(
            file: "MediaPane.swift",
            line: ".animation(reduceMotion ? nil : Theme.contentAnimation, value: layout.hasLyricBand)",
            count: 1,
            reason: "the player's block moving 20 pt when the lyric band folds away or arrives "
                + "(redesign 2026-10-15, spec §4.1): the progress row and the transport travel, "
                + "and spec §13 says nothing travels under Reduce Motion. The band itself still "
                + "fades in and out on its own transition."
        ),
        Allowed(
            file: "MediaPane.swift",
            line: "reduceMotion ? nil : PlayerLayout.animation(from: settledPage, to: page, reduceMotion: false),",
            count: 1,
            reason: "the player, the lyric column and the tall page are one view whose elements "
                + "travel (redesign 2026-10-15, spec §5.1) — cover 132 to 52 to 34, the controls "
                + "across the pane. That is geometry, and spec §13 says nothing travels under Reduce "
                + "Motion: the pane gives each state an identity of its own instead and the change "
                + "is the 0.24 s crossfade (`MediaPane.body`)."
        ),
        Allowed(
            file: "Theme.swift",
            line: ".animation(reduceMotion ? nil : Theme.contentAnimation, value: configuration.isOn)",
            count: 1,
            reason: "the panel switch's knob, which crosses the track. The change stays; the "
                + "knob is simply on the other side."
        ),
        Allowed(
            file: "Theme.swift",
            line: "reduceMotion ? nil : hudLevel",
            count: 1,
            reason: "the volume pop-up's level bar, whose fill changes length with each press "
                + "(redesign 2026-10-15, spec §2.4: \"appears and folds by crossfade; the bar "
                + "steps\"). A glide is travel, and the presses are what a person counts; the "
                + "pop-up itself still crossfades in and out."
        ),
    ]

    func testOnlyGeometryCutsUnderReduceMotion() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "no sources found under \(sources.path)")

        var found: [String: Int] = [:]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: .newlines) where line.contains("reduceMotion ? nil") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                found["\(file.lastPathComponent)|\(trimmed)", default: 0] += 1
            }
        }

        var expected: [String: Int] = [:]
        for site in Self.allowed {
            expected["\(site.file)|\(site.line)", default: 0] += site.count
        }
        for (site, count) in found.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(
                count, expected[site] ?? 0,
                "\(site) cuts under Reduce Motion. A fade is not motion: use Theme.contentAnimation, "
                    + "or list it here with the geometry that makes it travel."
            )
        }
        for (site, count) in expected where found[site] == nil {
            XCTFail("\(site) is allowed \(count) cut(s) but no longer cuts; take it off the list")
        }
    }
}
