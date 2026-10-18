import SwiftUI
import XCTest
@testable import IslaKit

/// Which glass a surface gets, and why.
@MainActor
final class GlassRoutingTests: XCTestCase {

    private func style(
        samplesBackdrop: Bool, preferDrawn: Bool = false, solid: Bool = false
    ) -> GlassSurfaceStyle {
        GlassSurfaceStyle(
            cornerRadius: 30, elevation: .card, tint: nil, light: nil,
            samplesBackdrop: samplesBackdrop, preferDrawn: preferDrawn, solid: solid
        )
    }

    /// A caller can ask for the opaque panel outright — the lock card's Solid
    /// style — and then neither the system material nor the drawn recipe is
    /// used, whatever the OS and whatever the setting.
    func testSolidIsTheOpaquePanelByChoice() {
        SystemAppearance.shared.overrideForTests(reduceTransparency: false)
        defer { SystemAppearance.shared.resetForTests() }

        let solid = style(samplesBackdrop: true, solid: true)
        XCTAssertFalse(solid.usesSystemGlass)
        XCTAssertTrue(solid.isOpaque)
        XCTAssertFalse(style(samplesBackdrop: true).isOpaque, "and it is off unless asked for")
    }

    /// A surface with something behind it takes Apple's material on macOS 26.
    /// Below that there is no material to take.
    ///
    /// With Reduce Transparency pinned off. It used to read the live setting,
    /// which is on in the CI image, so this passed on a desk and failed there.
    func testTheSystemMaterialIsUsedWhereItExistsAndCanSample() {
        SystemAppearance.shared.overrideForTests(reduceTransparency: false)
        defer { SystemAppearance.shared.resetForTests() }

        let expected: Bool
        if #available(macOS 26.0, *) { expected = true } else { expected = false }
        XCTAssertEqual(style(samplesBackdrop: true).usesSystemGlass, expected)
    }

    /// And with it on, every surface is the opaque panel — on any OS, whatever
    /// the surface asked for. The branch CI's Mac actually takes, asserted on
    /// purpose rather than by accident.
    func testReduceTransparencyMakesEverySurfaceOpaque() {
        SystemAppearance.shared.overrideForTests(reduceTransparency: true)
        defer { SystemAppearance.shared.resetForTests() }

        for surface in [style(samplesBackdrop: true), style(samplesBackdrop: false)] {
            XCTAssertFalse(surface.usesSystemGlass, "no frosted surface survives the setting")
            XCTAssertTrue(surface.isOpaque)
        }
    }

    /// A surface inside an already-opaque window has no backdrop, so the real
    /// material would sample nothing and the recipe is the honest choice. The
    /// lyrics stage's sync pill is exactly this.
    func testASurfaceWithNoBackdropAlwaysDrawsItsOwn() {
        XCTAssertFalse(style(samplesBackdrop: false).usesSystemGlass)
    }

    func testDrawnCanBeForcedPerSurface() {
        XCTAssertFalse(style(samplesBackdrop: true, preferDrawn: true).usesSystemGlass)
    }

    /// And forced globally without a rebuild, which is the escape hatch for the
    /// lock card: it draws above the login shield, and whether the real material
    /// finds anything to sample there cannot be settled from a build machine.
    func testDrawnCanBeForcedByDefaultsForTheLockScreen() {
        let defaults = UserDefaults.standard
        let had = defaults.object(forKey: NotchViewModel.drawnGlassKey)
        defer {
            if let had { defaults.set(had, forKey: NotchViewModel.drawnGlassKey) }
            else { defaults.removeObject(forKey: NotchViewModel.drawnGlassKey) }
        }

        defaults.set(true, forKey: NotchViewModel.drawnGlassKey)
        XCTAssertTrue(NotchViewModel.forcesDrawnGlass)
        XCTAssertFalse(style(samplesBackdrop: true).usesSystemGlass)

        defaults.set(false, forKey: NotchViewModel.drawnGlassKey)
        XCTAssertFalse(NotchViewModel.forcesDrawnGlass)
    }

    /// The lock card is the recipe, every finish, cover or no cover — which is
    /// what checklist.md has always said of it: no window above the shield is
    /// given a backdrop, so there is nothing for Apple's material to sample.
    ///
    /// F-012: the coverless Tinted and Transparent cards asked for a backdrop
    /// and nothing else, so on macOS 26 they took `glassEffect` over the shield
    /// while the record said recipe. K-017: because that answer flipped with
    /// the cover, the glass modifier switched branches when a coverless song
    /// followed one with art, and SwiftUI rebuilt the card's whole content —
    /// a scrub or a volume drag in flight was torn down without `onEnded`.
    /// Constant `false` closes both.
    ///
    /// With Reduce Transparency pinned off, the one setting that would make
    /// this pass for the wrong reason.
    func testTheLockCardNeverAsksForTheSystemMaterial() {
        SystemAppearance.shared.overrideForTests(reduceTransparency: false)
        defer { SystemAppearance.shared.resetForTests() }

        for cardStyle in NotchViewModel.LockCardStyle.allCases {
            for hasArtwork in [true, false] {
                let routing = LockScreenCard.glassRouting(style: cardStyle, hasArtwork: hasArtwork)
                let surface = style(
                    samplesBackdrop: routing.samplesBackdrop,
                    preferDrawn: routing.preferDrawn,
                    solid: routing.solid
                )
                XCTAssertFalse(
                    surface.usesSystemGlass,
                    "\(cardStyle) with\(hasArtwork ? "" : "out") a cover must not take glassEffect"
                )
                // Spec §7.2 (2026-10-15): Solid is `#1C1C1E` and Transparent is black
                // at 0.30, each with a hairline — both are panels, not the recipe.
                let panel = cardStyle == .solid || cardStyle == .clear
                XCTAssertEqual(routing.solid, panel, "Solid and Transparent are panels")
                XCTAssertEqual(surface.isOpaque, panel, "and the cover-lit styles are not")
            }
        }
    }
}
