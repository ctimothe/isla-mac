import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Every Settings section at 480, 560 and 620 pt in English and Russian, with
/// Volume and Brightness on and its Accessibility permission missing, so the
/// label-beside-a-control rows can be compared before and after a change to
/// `SettingsRowChrome` (2026-10-17, owner: "Accessibility" broke as
/// "Accessibilit / y" beside "Open Privacy & Security…"). Run by hand with
/// `Scripts/visual-lab.sh <folder> VisualLabSettingsRowsTests`; skips itself
/// without ISLA_VISUAL_OUT. Nothing here asks the real Accessibility API:
/// the HUD is given a trust that always says no and a scheduler that never
/// fires.
@MainActor
final class VisualLabSettingsRowsTests: VisualLabCase {
    func testEverySectionAtEveryWidth() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "settings-rows")
        let size = CGSize(width: VisualLab.windowSize.width, height: 460)
        let variants = [480, 560, 620].flatMap { width in
            ["en", "ru"].map { LabVariant(name: "\($0)-w\(width)", width: CGFloat(width), language: $0) }
        }
        let defaults: [String: Any] = [
            SettingsTable.volumeAndBrightnessKey: true,
            NotchViewModel.showLyricsKey: true,
        ]
        func panel(_ section: SettingsSection, _ variant: LabVariant) async throws -> AnyView {
            let hud = MediaKeyHUD(
                isEnabled: { true },
                trust: FakeTrust(false),
                schedule: { _, _ in {} },
                repairer: FakeRepair(),
                ledger: MemoryRepairLedger()
            )
            hud.refresh()
            return Self.scene(try await self.openPanel(session, tab: .settings, hud: hud, configure: { vm in
                vm.settingsSection = section
            }), variant, height: size.height)
        }
        for section in SettingsSection.allCases {
            try await shoot.shoot("top-\(section.rawValue)", variants: variants, size: size, settle: 0.4,
                                  defaults: defaults,
                                  notes: "Volume and Brightness on, Accessibility missing.") { variant in
                try await panel(section, variant)
            }
            try await shoot.shoot("bottom-\(section.rawValue)", variants: variants, size: size, settle: 0.4,
                                  defaults: defaults,
                                  notes: "The same, scrolled to the end of the form.",
                                  interact: { Self.scrollToEnd($0) }) { variant in
                try await panel(section, variant)
            }
        }
    }

    /// Scrolls every scroll view under `root` to its end, so the last rows of a
    /// form the lab cannot scroll by hand are in the picture.
    private static func scrollToEnd(_ root: NSView) {
        if let scroll = root as? NSScrollView, let document = scroll.documentView {
            let overflow = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let y = document.isFlipped ? overflow : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        for child in root.subviews { scrollToEnd(child) }
    }
}
