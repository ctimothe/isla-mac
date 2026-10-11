import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Renders the Translate pane to PNGs for a person to look at, only when asked:
/// `RENDER_DIR=/some/folder`. Nothing is asserted about pixels; this is the
/// look, filed where a reviewer can open it.
@MainActor
final class TranslatePaneRenderTests: XCTestCase {
    func testRenderTheHeadingsAndTheFailure() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RENDER_DIR"] else {
            throw XCTSkip("set RENDER_DIR to render")
        }
        let suite = "TranslatePaneRenderTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let translator = Translator(defaults: defaults)
        translator.choose(target: .uzbek)
        translator.input = "Where is the nearest train station?"
        await translator.translate()
        try render(translator, to: URL(fileURLWithPath: directory).appendingPathComponent("translate-blocked.png"))

        defaults.set(true, forKey: NotchViewModel.onlineTranslationKey)
        await translator.translate()
        try render(translator, to: URL(fileURLWithPath: directory).appendingPathComponent("translate-online.png"))
    }

    // MARK: - The cover

    /// A private suite per test, emptied before and after: the pane's
    /// translator reads and writes its language choice, and the cover choice
    /// is persisted, so neither may touch the real defaults domain.
    private func isolatedDefaults() throws -> (UserDefaults, () -> Void) {
        let suite = "TranslatePaneRenderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    /// F-002: with the Translate cover on, a secret run through ⌃⌥⌘T was
    /// dust on the left and readable at headline size on the right, and the
    /// accessibility tree handed the translation to anything that asked for it
    /// as static text. Covered, the answer is announced as "Hidden" and its
    /// words are nowhere in the tree.
    func testCoveredPaneHidesTheTranslation() async throws {
        let (defaults, release) = try isolatedDefaults()
        defer { release() }
        let privacy = PrivacyMode(defaults: defaults)
        privacy.setCovering(.translate, true)
        let translator = Translator(defaults: defaults)
        translator.input = "secret"
        translator.received("секрет", for: "secret", by: .system)

        let pane = TranslatePane(translator: translator, privacy: privacy, wantsKeyboard: .constant(false))
            .background(Color.black)
        let root = await AXProbe.tree(of: pane, size: CGSize(width: 470, height: 170))

        XCTAssertFalse(root.dump.contains("секрет"), root.dump)
        XCTAssertFalse(root.dump.contains("\"secret\""), root.dump)
        XCTAssertNotNil(root.first(label: "Hidden"), root.dump)

        // One reveal uncovers both columns: the dust on the answer answers a
        // press the way a click on it does.
        let hidden = root.all { $0.label == "Hidden" && $0.actionNames.contains("AXPress") }
        XCTAssertFalse(hidden.isEmpty, root.dump)
        XCTAssertTrue(hidden.last?.press() ?? false, root.dump)
        XCTAssertFalse(privacy.hides(.translate, "translate.source"))
        let revealed = await root.reread()
        XCTAssertTrue(revealed.dump.contains("секрет"), revealed.dump)
    }

    /// F-021: the field went to dust on the first typed character, and a click
    /// to place the caret revealed instead of placing it. A keystroke is the
    /// person at the keyboard, which the cover is not against, so writing
    /// through the editor uncovers the pane.
    func testTypingDoesNotCoverTheField() throws {
        let (defaults, release) = try isolatedDefaults()
        defer { release() }
        let privacy = PrivacyMode(defaults: defaults)
        privacy.setCovering(.translate, true)
        let translator = Translator(defaults: defaults)

        TranslatePane.typed("s", privacy: privacy, translator: translator)

        XCTAssertEqual(translator.input, "s")
        XCTAssertFalse(privacy.hides(.translate, "translate.source"))
    }

    /// The other half of the same rule: text that arrives without a keystroke
    /// (the hot key, the Service) is assigned to the translator directly and
    /// stays covered, and the editor echoing back the text it already holds is
    /// not a keystroke either.
    func testTextThatArrivesWithoutAKeystrokeStaysCovered() throws {
        let (defaults, release) = try isolatedDefaults()
        defer { release() }
        let privacy = PrivacyMode(defaults: defaults)
        privacy.setCovering(.translate, true)
        let translator = Translator(defaults: defaults)

        translator.input = "secret"
        TranslatePane.typed("secret", privacy: privacy, translator: translator)

        XCTAssertTrue(privacy.hides(.translate, "translate.source"))
    }

    /// With the cover off, typing records no reveal: one recorded then would
    /// leave the pane already uncovered the moment covering is turned on.
    func testTypingWithTheCoverOffRecordsNoReveal() throws {
        let (defaults, release) = try isolatedDefaults()
        defer { release() }
        let privacy = PrivacyMode(defaults: defaults)
        let translator = Translator(defaults: defaults)

        TranslatePane.typed("s", privacy: privacy, translator: translator)
        privacy.setCovering(.translate, true)

        XCTAssertTrue(privacy.hides(.translate, "translate.source"))
    }

    private func render(_ translator: Translator, to url: URL) throws {
        let pane = TranslatePane(translator: translator, privacy: PrivacyMode(), wantsKeyboard: .constant(false))
            .frame(width: 470, height: 170)
            .padding(14)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: pane)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
