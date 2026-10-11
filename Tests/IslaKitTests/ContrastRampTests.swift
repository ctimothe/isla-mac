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

    // MARK: - The card over its own cover (F-003)

    /// Every label on the card clears AA over the palest cover there is.
    ///
    /// The card is lit by the song's cover, and the black wash over it was a
    /// fixed 0.34. Over a near-white cover that left a 0.66 grey, on which the
    /// artist line (0.62) measured 1.76:1 and the elapsed time and lyric status
    /// (0.50) 1.59:1 — the comment above the wash promised "white type holds
    /// over the palest one" and the arithmetic said otherwise. Everything here
    /// was measured against black, which is the one backdrop the card never
    /// has. This measures against the brightest backdrop it can have.
    func testEveryCardLabelHoldsAAOverTheBrightestCover() {
        for increaseContrast in [false, true] {
            let backdrop = LockCardLegibility.backdrop(coverLuma: 1.0, style: .glass, increaseContrast: increaseContrast)
            XCTAssertGreaterThanOrEqual(
                LockCardLegibility.contrast(
                    textOpacity: Theme.cardSecondaryOpacity(increaseContrast: increaseContrast), overGrey: backdrop),
                4.5, "the artist line over a white cover, increaseContrast \(increaseContrast)"
            )
            XCTAssertGreaterThanOrEqual(
                LockCardLegibility.contrast(
                    textOpacity: Theme.cardTertiaryOpacity(increaseContrast: increaseContrast), overGrey: backdrop),
                4.5, "the times and the lyric status over a white cover, increaseContrast \(increaseContrast)"
            )
        }
    }

    /// The same promise at every brightness between, and in Transparent for
    /// the part of the card the cover lights: the wash is solved for the
    /// cover, so no grey along the way is the one the rule forgot.
    func testEveryCoverBrightnessHoldsAA() {
        for style in [NotchViewModel.LockCardStyle.glass, .clear] {
            for increaseContrast in [false, true] {
                for step in 0...20 {
                    let luma = Double(step) / 20
                    let backdrop = LockCardLegibility.backdrop(
                        coverLuma: luma, style: style, increaseContrast: increaseContrast)
                    XCTAssertGreaterThanOrEqual(
                        LockCardLegibility.contrast(
                            textOpacity: Theme.cardTertiaryOpacity(increaseContrast: increaseContrast),
                            overGrey: backdrop),
                        4.5, "\(style.rawValue) luma \(luma) increaseContrast \(increaseContrast)"
                    )
                }
            }
        }
    }

    /// A dark cover keeps the light it had.
    ///
    /// The owner asked on 2026-09-21 for a card "lit by its own cover", and a
    /// fixed heavy wash would have answered F-003 by putting that light out on
    /// every dark cover. Below the brightness where the old wash already held,
    /// nothing changes.
    func testADarkCoverKeepsTheLightItHad() {
        XCTAssertEqual(LockCardLegibility.washOpacity(coverLuma: 0.25, style: .glass, increaseContrast: false), 0.34)
        XCTAssertEqual(LockCardLegibility.washOpacity(coverLuma: 0.3, style: .glass, increaseContrast: false), 0.34)
        XCTAssertEqual(LockCardLegibility.washOpacity(coverLuma: 0.25, style: .glass, increaseContrast: true), 0.56)
        XCTAssertEqual(LockCardLegibility.washOpacity(coverLuma: 0.25, style: .clear, increaseContrast: false), 0.2)
        XCTAssertEqual(LockCardLegibility.washOpacity(coverLuma: 0, style: .glass, increaseContrast: false), 0.34)
    }

    /// A brighter cover never gets a lighter wash — otherwise two covers a
    /// shade apart could swap which one reads.
    func testTheWashNeverLightensAsTheCoverBrightens() {
        for increaseContrast in [false, true] {
            var last = 0.0
            for step in 0...50 {
                let wash = LockCardLegibility.washOpacity(
                    coverLuma: Double(step) / 50, style: .glass, increaseContrast: increaseContrast)
                XCTAssertGreaterThanOrEqual(wash, last)
                XCTAssertLessThan(wash, 1, "the cover is dimmed, never painted out")
                last = wash
            }
        }
    }

    /// The model reproduces the audit's arithmetic, so the numbers above are
    /// the numbers the audit measured: today's 0.62 over a 0.66 grey.
    func testTheContrastModelMatchesTheAudit() {
        XCTAssertEqual(LockCardLegibility.contrast(textOpacity: 0.62, overGrey: 0.66), 1.76, accuracy: 0.01)
        XCTAssertEqual(LockCardLegibility.contrast(textOpacity: 0.50, overGrey: 0.66), 1.59, accuracy: 0.01)
        XCTAssertEqual(LockCardLegibility.contrast(textOpacity: 1, overGrey: 0), 21, accuracy: 0.01)
    }
}
