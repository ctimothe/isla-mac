import Foundation
@testable import IslaKit

// Conveniences the tests lean on that the app itself never calls. They lived in
// the app's sources until the 2026-11-15 cleanup; here they cost the shipped
// binary nothing.

extension NotchViewModel.Surface {
    /// The surfaces somebody can be sent to: every one but the drop surface and
    /// the welcome, which the app presents on its own.
    static let reachable: [NotchViewModel.Surface] = [.player, .stage, .tray, .clipboard, .translate, .settings]
}
