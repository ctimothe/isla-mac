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

    /// WCAG relative luminance of an opaque sRGB colour, channels 0…255.
    private func luminance(_ red: Double, _ green: Double, _ blue: Double) -> Double {
        func linear(_ value: Double) -> Double {
            let channel = value / 255
            return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// `controlAccentColor` under dark Aqua for each accent a person can pick,
    /// as macOS resolves it. Read on 2026-10-11 from a scratch process
    /// launched with `-AppleAccentColor <n>` — the argument domain, so the
    /// Mac's own setting was never touched — and kept as numbers here because
    /// a test cannot change the accent it runs under. Graphite is the one
    /// that matters: grey on grey, with no hue to tell on from off.
    private static let accents: [(name: String, rgb: (Double, Double, Double))] = [
        ("graphite", (140, 140, 140)), ("blue", (0, 122, 255)), ("yellow", (255, 198, 0)),
        ("red", (255, 82, 87)), ("orange", (247, 130, 27)), ("green", (98, 186, 70)),
        ("purple", (165, 80, 167)), ("pink", (247, 79, 158)),
    ]

    /// A Settings switch that is on looks on, whatever accent drew it.
    ///
    /// The track is measured where it is drawn — inside a Settings card, which
    /// is `surface` white over the panel's black — rather than over bare black,
    /// which flatters it: the plan's own off fill (`surfaceHover`) cleared 3:1
    /// over black for neither graphite (2.97) nor blue (2.49), and over the
    /// card it fell to 1.86 and 1.55. The off track is a well shaded into the
    /// card instead, so the accent has the whole step to itself. 3:1 is
    /// WCAG's non-text floor (1.4.11), held at both contrast settings.
    func testSwitchOnAndOffAreTellableApartOnEveryAccent() {
        for increaseContrast in [false, true] {
            let card = Theme.surfaceOpacity(increaseContrast: increaseContrast)
            let well = card * (1 - Theme.switchWellOpacity(increaseContrast: increaseContrast))
            let off = luminance(well * 255, well * 255, well * 255)
            for accent in Self.accents {
                let on = luminance(accent.rgb.0, accent.rgb.1, accent.rgb.2)
                XCTAssertGreaterThanOrEqual(
                    (on + 0.05) / (off + 0.05), 3.0,
                    "\(accent.name) on vs off, increaseContrast \(increaseContrast)"
                )
                // Over bare black, the measure the plan named, the well adds
                // nothing to the black and the step only grows.
                XCTAssertGreaterThanOrEqual((on + 0.05) / 0.05, 3.0, accent.name)
            }
        }
        XCTAssertGreaterThan(
            PanelSwitchStyle.look(isOn: false, increaseContrast: true).outlineWidth, 0,
            "Increase Contrast draws an edge round the track"
        )
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

    /// The ramp above is measured over black, and a label rarely sits there:
    /// Settings notes sit on `surface` (4.29:1 at the old 0.46), a hovered
    /// Shelf card's age on `surfaceHover` (3.52:1), and the unselected option
    /// of a segmented row on `surface` stacked on `surface` (3.26:1). Each
    /// pair the code uses is measured here, at both Increase Contrast settings
    /// (F-052).
    func testLabelsClearAAOnTheFillsTheySitOn() {
        func ratio(_ text: Double, on fills: [Theme.Fill], contrast: Bool) -> Double {
            Theme.contrast(
                textOpacity: text,
                overGrey: Theme.composite(fills.map { $0.opacity(increaseContrast: contrast) })
            )
        }
        for contrast in [false, true] {
            let tertiary = Theme.tertiaryOpacity(increaseContrast: contrast)
            XCTAssertGreaterThanOrEqual(ratio(tertiary, on: [.surface], contrast: contrast), 4.5, "tertiary on surface, contrast \(contrast)")

            // Everything that raises the label past the base ramp stays a
            // ramp: never dimmer than tertiary itself.
            for fills: [Theme.Fill] in [
                [.surfaceHover], [.selectedChip], Theme.choiceOptionFills(increaseContrast: contrast),
            ] {
                let raised = Theme.tertiaryOpacity(over: fills, increaseContrast: contrast)
                XCTAssertGreaterThanOrEqual(raised, tertiary)
                XCTAssertGreaterThanOrEqual(ratio(raised, on: fills, contrast: contrast), 4.5, "\(fills) contrast \(contrast)")
                XCTAssertLessThan(raised, 1)
            }

            // The kind glyph is non-text: 3:1 on a hovered row.
            XCTAssertGreaterThanOrEqual(ratio(tertiary, on: [.surfaceHover], contrast: contrast), 3.0, "clipboard glyph, contrast \(contrast)")
        }
        // Where the base already clears, nothing is raised.
        XCTAssertEqual(
            Theme.tertiaryOpacity(over: [], increaseContrast: false),
            Theme.tertiaryOpacity(increaseContrast: false)
        )
        // The numbers the finding quotes.
        XCTAssertEqual(ratio(0.46, on: [.surface], contrast: false), 4.29, accuracy: 0.02)
        XCTAssertEqual(ratio(0.46, on: [.surfaceHover], contrast: false), 3.52, accuracy: 0.02)
        XCTAssertEqual(ratio(0.46, on: [.surface, .surface], contrast: false), 3.26, accuracy: 0.02)
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

    // MARK: - Lyric context lines (owner decision 9, F-051)

    /// Every lyric line the voice is not in still reads as text.
    ///
    /// The floor sat at white 0.28 (2.27:1 over black) and the neighbour at
    /// 0.34 (2.89:1): under WCAG's 3:1 even for the large type a lyric is set
    /// in, by a documented preference for depth over contrast. Depth survives
    /// as steps rather than as a line nobody can read — floor, neighbour, the
    /// sung line's unsung words, the sung words — and each step is held here.
    func testLyricContextClearsThreeToOne() {
        let base = LyricRow.Ramp.panel(increaseContrast: false)
        XCTAssertGreaterThanOrEqual(ratioOverBlack(whiteOpacity: base.floor), 3.0, "the far floor")
        XCTAssertGreaterThanOrEqual(ratioOverBlack(whiteOpacity: base.neighbour), 3.9, "the neighbour")
        let raised = LyricRow.Ramp.panel(increaseContrast: true)
        XCTAssertGreaterThanOrEqual(raised.floor, base.floor, "Increase Contrast never lowers the floor")
        XCTAssertGreaterThanOrEqual(raised.neighbour, base.neighbour)
        for ramp in [base, raised] {
            XCTAssertGreaterThan(ramp.neighbour, ramp.floor, "depth: the near line above the far ones")
            XCTAssertLessThan(ramp.neighbour, ramp.unswept, "the sung line is never the dimmer one")
            XCTAssertLessThan(ramp.reading, ramp.unswept, "not even while the reader scrolls")
        }
        // The statics the rest of the app already reads are the ramp, not a
        // second set of numbers that could drift from it.
        for contrast in [false, true] {
            let ramp = LyricRow.Ramp.panel(increaseContrast: contrast)
            XCTAssertEqual(LyricRow.falloffFloor(increaseContrast: contrast), ramp.floor)
            XCTAssertEqual(LyricRow.neighbourOpacity(increaseContrast: contrast), ramp.neighbour)
            XCTAssertEqual(LyricRow.readingOpacity(increaseContrast: contrast), ramp.reading)
        }
    }

    /// The player's lyric band, next line (redesign 2026-10-15, spec §4.3): the
    /// board draws it at white 0.36, and that is the panel's own lyric floor, so
    /// it clears the same 3:1 the context lines are held to. It follows the ramp
    /// rather than stating a second 0.36, rises with Increase Contrast, and stays
    /// under the sung line's unswept words so the sung line is never the dimmer.
    func testTheBandsNextLineClearsTheLyricFloor() {
        XCTAssertEqual(Theme.lyricBandNextOpacity(increaseContrast: false), 0.36,
                       "the board's value holds: 0.36 passes, so it is not lowered")
        for contrast in [false, true] {
            let opacity = Theme.lyricBandNextOpacity(increaseContrast: contrast)
            XCTAssertGreaterThanOrEqual(ratioOverBlack(whiteOpacity: opacity), 3.0, "contrast \(contrast)")
            XCTAssertEqual(opacity, LyricRow.Ramp.panel(increaseContrast: contrast).floor)
            XCTAssertLessThan(opacity, LyricRow.Ramp.panel(increaseContrast: contrast).unswept)
        }
        XCTAssertGreaterThan(
            Theme.lyricBandNextOpacity(increaseContrast: true), Theme.lyricBandNextOpacity(increaseContrast: false)
        )
    }

    /// The quaternary step (spec §2.1) is for glyphs nobody has to read, and it
    /// rises with the setting like every other.
    func testQuaternaryIsForGlyphsAndRisesWithContrast() {
        XCTAssertEqual(Theme.quaternaryOpacity(increaseContrast: false), 0.30)
        XCTAssertEqual(Theme.quaternaryOpacity(increaseContrast: true), 0.50)
        XCTAssertLessThan(
            Theme.quaternaryOpacity(increaseContrast: false), Theme.tertiaryOpacity(increaseContrast: false),
            "never text a person must read: tertiary is the floor for that"
        )
    }

    /// The lock card's lyrics read over the palest cover the card can carry.
    ///
    /// The card drew the panel's falloff — greys tuned against black — over
    /// a cover-lit backdrop, and in the visual lab's light renders the context
    /// lines dissolved into the cover. Measured against the backdrop
    /// `LockCardLegibility` solves for a white cover, the floor holds 3:1 and the neighbour AA.
    func testCardLyricsHoldOverTheBrightestCover() {
        for increaseContrast in [false, true] {
            let backdrop = LockCardLegibility.backdrop(coverLuma: 1, increaseContrast: increaseContrast)
            let ramp = LyricRow.Ramp.card(increaseContrast: increaseContrast)
            let label = "increaseContrast \(increaseContrast)"
            XCTAssertGreaterThanOrEqual(
                LockCardLegibility.contrast(textOpacity: ramp.floor, overGrey: backdrop), 3.0,
                "the far floor, \(label)")
            XCTAssertGreaterThanOrEqual(
                LockCardLegibility.contrast(textOpacity: ramp.neighbour, overGrey: backdrop), 4.5,
                "the neighbour, \(label)")
            XCTAssertGreaterThan(ramp.unswept, ramp.neighbour, "the sung line stays brightest, \(label)")
            XCTAssertGreaterThan(ramp.neighbour, ramp.floor, "depth survives, \(label)")
        }
        XCTAssertGreaterThan(
            LyricRow.Ramp.card(increaseContrast: true).floor,
            LyricRow.Ramp.card(increaseContrast: false).floor,
            "Increase Contrast lifts the card's lines too")
    }

    /// A credit is never dressed as the sung line, and it answers Increase
    /// Contrast like every other line.
    ///
    /// The credit branch's comment said "never bold" while it passed the
    /// caller's weight through — and both callers pass `.bold` — so "Produced
    /// by" came out bold italic, like a lyric. Its dim state was a fixed 0.34
    /// that the setting never moved.
    func testCreditsAreNeverBold() {
        XCTAssertNotEqual(LyricRow.creditWeight, .bold)
        XCTAssertNotEqual(LyricRow.creditWeight, .heavy)
        XCTAssertNotEqual(LyricRow.creditWeight, .black)
        XCTAssertGreaterThan(
            LyricRow.creditOpacity(isCurrent: false, increaseContrast: true),
            LyricRow.creditOpacity(isCurrent: false, increaseContrast: false)
        )
        XCTAssertGreaterThanOrEqual(
            ratioOverBlack(whiteOpacity: LyricRow.creditOpacity(isCurrent: false, increaseContrast: false)), 3.0,
            "a waiting credit reads like any context line")
        XCTAssertGreaterThan(
            LyricRow.creditOpacity(isCurrent: true, increaseContrast: false),
            LyricRow.creditOpacity(isCurrent: false, increaseContrast: false)
        )
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
            let backdrop = LockCardLegibility.backdrop(coverLuma: 1.0, increaseContrast: increaseContrast)
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

    /// The same promise at every brightness between: the wash is solved for the
    /// cover, so no grey along the way is the one the rule forgot.
    func testEveryCoverBrightnessHoldsAA() {
        for increaseContrast in [false, true] {
            for step in 0...20 {
                let luma = Double(step) / 20
                let backdrop = LockCardLegibility.backdrop(coverLuma: luma, increaseContrast: increaseContrast)
                XCTAssertGreaterThanOrEqual(
                    LockCardLegibility.contrast(
                        textOpacity: Theme.cardTertiaryOpacity(increaseContrast: increaseContrast),
                        overGrey: backdrop),
                    4.5, "luma \(luma) increaseContrast \(increaseContrast)"
                )
            }
        }
    }

    /// **Transparent keeps a contrast guarantee** (re-review 2026-10-15). Spec 7.2's
    /// black 0.30 had dropped out of the solver, so white secondary and tertiary
    /// type over a bright wallpaper had only a text shadow. 0.30 is now the floor:
    /// a dark wallpaper holds at it, a bright or unknown one gets the least more at
    /// which the dimmest type clears the same 4.5:1 the cover wash is solved for.
    func testTransparentIsBlackAt030OverADarkWallpaperAndHeavierOverABrightOne() {
        for increaseContrast in [false, true] {
            let text = Theme.cardTertiaryOpacity(increaseContrast: increaseContrast)
            XCTAssertEqual(
                LockCardLegibility.transparentWash(luminance: 0.03, increaseContrast: increaseContrast),
                LockCardMaterial.transparentAlpha,
                "a dark wallpaper holds at the spec's 0.30")
            var last = LockCardMaterial.transparentAlpha
            for step in 0...20 {
                let luma = Double(step) / 20
                let wash = LockCardLegibility.transparentWash(luminance: luma, increaseContrast: increaseContrast)
                XCTAssertGreaterThanOrEqual(wash, last, "a brighter wallpaper never gets less black, luma \(luma)")
                XCTAssertLessThan(wash, 1)
                XCTAssertGreaterThanOrEqual(
                    LockCardLegibility.contrast(textOpacity: text, overGrey: luma * (1 - wash)),
                    LockCardLegibility.minimumContrast, "AA over wallpaper luma \(luma)")
                last = wash
            }
        }
        let bright = LockCardLegibility.transparentWash(luminance: 0.9)
        XCTAssertGreaterThan(bright, 0.30)
        XCTAssertEqual(
            LockCardLegibility.transparentWash(luminance: nil), LockCardLegibility.transparentWash(luminance: 1),
            "unknown is the worst case, white")
        XCTAssertGreaterThan(LockCardLegibility.transparentWash(luminance: nil), 0.30)
        // The decision routes it: same alpha, still the black wash.
        XCTAssertEqual(
            LockCardMaterial.decision(style: .clear, hasArtwork: true, luminance: 0.9, reduceTransparency: false),
            LockCardMaterial.Decision(layer: .blackWash, alpha: bright))
    }

    /// A dark cover keeps the light it had.
    ///
    /// The owner asked on 2026-09-21 for a card "lit by its own cover", and a
    /// fixed heavy wash would have answered F-003 by putting that light out on
    /// every dark cover. Below the brightness where the old wash already held,
    /// nothing changes.
    func testADarkCoverKeepsTheLightItHad() {
        XCTAssertEqual(LockCardLegibility.washOpacity(coverLuma: 0.25, increaseContrast: false), 0.34)
        XCTAssertEqual(LockCardLegibility.washOpacity(coverLuma: 0.3, increaseContrast: false), 0.34)
        XCTAssertEqual(LockCardLegibility.washOpacity(coverLuma: 0.25, increaseContrast: true), 0.56)
        XCTAssertEqual(LockCardLegibility.washOpacity(coverLuma: 0, increaseContrast: false), 0.34)
    }

    /// A brighter cover never gets a lighter wash — otherwise two covers a
    /// shade apart could swap which one reads.
    func testTheWashNeverLightensAsTheCoverBrightens() {
        for increaseContrast in [false, true] {
            var last = 0.0
            for step in 0...50 {
                let wash = LockCardLegibility.washOpacity(
                    coverLuma: Double(step) / 50, increaseContrast: increaseContrast)
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
