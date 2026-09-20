import SwiftUI
import XCTest
@testable import IslaKit

/// Contrast ratios for the tokens the chrome is built from.
///
/// The panel is white-on-black, so a token's ratio against black is computable
/// and worth asserting: `surface` at white 0.08 is 1.14:1, which is a shape
/// nobody can see. This is not only an accessibility question — the selected
/// tab chip and the empty scrubber track are drawn from these tokens.
@MainActor
final class ContrastRampTests: XCTestCase {

    /// WCAG relative luminance for a grey of the given white opacity over black.
    private func ratioOverBlack(whiteOpacity: Double) -> Double {
        let channel = whiteOpacity
        let linear = channel <= 0.03928
            ? channel / 12.92
            : pow((channel + 0.055) / 1.055, 2.4)
        return (linear + 0.05) / 0.05
    }

    func testTheNonTextChromeIsVisibleAsAShape() {
        XCTAssertGreaterThanOrEqual(
            ratioOverBlack(whiteOpacity: Theme.surfaceOpacity(increaseContrast: false)), 1.4,
            "a filled chip has to read as a filled chip"
        )
        XCTAssertGreaterThanOrEqual(
            ratioOverBlack(whiteOpacity: Theme.surfaceHoverOpacity(increaseContrast: false)), 2.0
        )
    }

    func testIncreaseContrastRaisesEveryTokenItShould() {
        for pair in [
            (Theme.tertiaryOpacity(increaseContrast: false), Theme.tertiaryOpacity(increaseContrast: true)),
            (Theme.secondaryOpacity(increaseContrast: false), Theme.secondaryOpacity(increaseContrast: true)),
            (Theme.surfaceOpacity(increaseContrast: false), Theme.surfaceOpacity(increaseContrast: true)),
            (Theme.hairlineOpacity(increaseContrast: false), Theme.hairlineOpacity(increaseContrast: true)),
        ] {
            XCTAssertGreaterThan(pair.1, pair.0, "Increase Contrast must raise this token")
        }
    }

    /// 9pt labels are the type least able to afford a low ratio, and they carry
    /// most of the panel: tab titles, counters, scrubber times, placeholders.
    func testTheSmallestLabelClearsWCAGAAAtEverySetting() {
        for contrast in [false, true] {
            XCTAssertGreaterThanOrEqual(
                ratioOverBlack(whiteOpacity: Theme.tertiaryOpacity(increaseContrast: contrast)), 4.5,
                "tertiary carries 9-10pt labels and must clear AA"
            )
        }
    }

    /// The dimmest lyric context line. At white 0.18 it was 1.54:1.
    func testTheLyricFalloffHasAFloor() {
        XCTAssertGreaterThanOrEqual(
            ratioOverBlack(whiteOpacity: LyricRow.falloffFloor(increaseContrast: true)), 3.0
        )
    }

    /// The neighbour one step from the sung line must sit between floor and
    /// song: e67e80e fixed it sitting below the floor (0.34 < 0.38) under
    /// Increase Contrast, which turned depth inside out.
    func testLyricNeighbourSitsAboveTheFalloffFloor() {
        for contrast in [false, true] {
            XCTAssertGreaterThan(
                LyricRow.neighbourOpacity(increaseContrast: contrast),
                LyricRow.falloffFloor(increaseContrast: contrast)
            )
        }
    }

    /// Increase Contrast reaches the lock card too.
    ///
    /// The card carried twenty-two raw literals, so the setting moved every
    /// label in the panel and nothing at all on the one surface a person reads
    /// from across a room. It keeps its own values — it floats over a wallpaper
    /// rather than the panel's black, so its type runs brighter — but they are
    /// functions of the setting now, like everything else.
    func testTheLockCardAnswersIncreaseContrast() {
        for pair in [
            (Theme.cardSecondaryOpacity(increaseContrast: false), Theme.cardSecondaryOpacity(increaseContrast: true)),
            (Theme.cardTertiaryOpacity(increaseContrast: false), Theme.cardTertiaryOpacity(increaseContrast: true)),
            (Theme.cardFillOpacity(increaseContrast: false), Theme.cardFillOpacity(increaseContrast: true)),
            (Theme.cardTrackOpacity(increaseContrast: false), Theme.cardTrackOpacity(increaseContrast: true)),
            (Theme.cardHairlineOpacity(increaseContrast: false), Theme.cardHairlineOpacity(increaseContrast: true)),
        ] {
            XCTAssertGreaterThan(pair.1, pair.0, "every card token must rise with the setting")
        }
    }

    /// The card's type is brighter than the panel's, on purpose: the panel sits
    /// on its own black and the card sits on whatever wallpaper is behind it.
    func testTheCardRunsBrighterThanThePanel() {
        XCTAssertGreaterThan(
            Theme.cardTertiaryOpacity(increaseContrast: false),
            Theme.tertiaryOpacity(increaseContrast: false)
        )
        XCTAssertGreaterThan(
            Theme.cardSecondaryOpacity(increaseContrast: false),
            Theme.secondaryOpacity(increaseContrast: false)
        )
    }

    /// And a filled shape on the card reads as a filled shape. 0.08 white was
    /// 1.14:1 over black — the artwork well and the unselected output dot were
    /// not visible as shapes at all.
    func testTheCardsFilledShapesClearTheShapeFloor() {
        XCTAssertGreaterThan(ratioOverBlack(whiteOpacity: Theme.cardFillOpacity(increaseContrast: false)), 1.4)
        XCTAssertGreaterThan(ratioOverBlack(whiteOpacity: Theme.cardTrackOpacity(increaseContrast: false)), 1.6)
    }
}
