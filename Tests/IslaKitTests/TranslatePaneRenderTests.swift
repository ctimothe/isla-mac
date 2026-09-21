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
