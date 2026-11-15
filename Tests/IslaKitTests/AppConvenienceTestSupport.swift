import Foundation
@testable import IslaKit

// Conveniences the tests lean on that the app itself never calls. They lived in
// the app's sources until the 2026-11-15 cleanup; here they cost the shipped
// binary nothing.

extension ClipHighlight {
    /// The matched ranges as character offsets, for a test that holds what is
    /// lit without reading attributes.
    static func matchedText(_ runs: [Run], query: String) -> [String] {
        let plain = runs.map(\.text).joined()
        return ClipboardSearch.ranges(of: query, in: plain).map { String(plain[$0]) }
    }
}

extension ClipRow {
    /// The glyph a symbol mark names, or nil for the marks that are drawings
    /// (a swatch, a thumbnail, a file's icon).
    static func glyph(for item: ClipItem, hidden: Bool) -> String? {
        if case .symbol(let name) = mark(for: item, hidden: hidden) { return name }
        return nil
    }
}

extension WelcomePane {
    /// Every key this pane shows, so a test can prove both tables carry them.
    static let localizedKeys = Copy.english.all
}

extension NotchViewModel.Surface {
    /// The surfaces somebody can be sent to: every one but the drop surface and
    /// the welcome, which the app presents on its own.
    static let reachable: [NotchViewModel.Surface] = [.player, .stage, .tray, .clipboard, .translate, .settings]
}
