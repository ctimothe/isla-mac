import SwiftUI
import XCTest
@testable import DynamicIslandKit

/// Which glass a surface gets, and why.
@MainActor
final class GlassRoutingTests: XCTestCase {

    private func style(samplesBackdrop: Bool, preferDrawn: Bool = false) -> GlassSurfaceStyle {
        GlassSurfaceStyle(
            cornerRadius: 30, elevation: .card, tint: nil, light: nil,
            samplesBackdrop: samplesBackdrop, preferDrawn: preferDrawn
        )
    }

    /// A surface with something behind it takes Apple's material on macOS 26.
    /// Below that there is no material to take.
    func testTheSystemMaterialIsUsedWhereItExistsAndCanSample() {
        let expected: Bool
        if #available(macOS 26.0, *) { expected = true } else { expected = false }
        XCTAssertEqual(style(samplesBackdrop: true).usesSystemGlass, expected)
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
}
