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
            line: ".animation(reduceMotion ? nil : Theme.contentAnimation, value: pane)",
            count: 2,
            reason: "the header and the cover beside it: the cover changes size with the pane "
                + "(76 to 44 pt), and the title slides with it. Geometry."
        ),
        Allowed(
            file: "LockScreenCard.swift",
            line: ".animation(reduceMotion ? nil : Theme.paneAnimation, value: pane)",
            count: 1,
            reason: "the card's middle: its frame follows the header's cover, which cuts, so an "
                + "animation here slides the seek bar. Its panes fade on a transition of their own."
        ),
        Allowed(
            file: "LockScreenCard.swift",
            line: ".animation(jump || reduceMotion ? nil : Theme.lyricScroll, value: centre)",
            count: 1,
            reason: "the lock card's lyric window: with the travel refused the leaving line only "
                + "faded while the rest still slid a row, so two lines shared one slot."
        ),
        Allowed(
            file: "Theme.swift",
            line: ".animation(reduceMotion ? nil : Theme.contentAnimation, value: configuration.isOn)",
            count: 1,
            reason: "the panel switch's knob, which crosses the track. The change stays; the "
                + "knob is simply on the other side."
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
