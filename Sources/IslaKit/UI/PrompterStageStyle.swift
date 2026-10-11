import SwiftUI

// The stage's colour and type tokens (T7 design note: word ladder, cue ladder,
// type; spec 10.1, 12.2's colours). Pure functions of the three settings that
// move them — Increase Contrast, the highlight and cue colours, cue
// brightness — and of the backdrop they are measured on, so
// `PrompterStageRenderTests` holds every reading state to its floor and the
// view only reads the answers. Nothing here is a hand-mixed value in a view.

/// An sRGB colour, 0...1 a channel. Plain numbers rather than `Color`, which
/// cannot be measured.
struct PromptRGB: Sendable, Equatable {
    let red: Double
    let green: Double
    let blue: Double

    static let white = PromptRGB(red: 1, green: 1, blue: 1)

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    /// Part of the way to white, for a tint too dark to read.
    func lightened(by amount: Double) -> PromptRGB {
        let t = min(max(amount, 0), 1)
        return PromptRGB(red: red + (1 - red) * t, green: green + (1 - green) * t, blue: blue + (1 - blue) * t)
    }
}

extension PrompterTint {
    /// Spec 12.2's colours, as tokens. White is the default and the one value
    /// sure to read on every backdrop; the others are measured, and lightened
    /// where they fail (`PrompterStageStyle.highlightColor`).
    var rgb: PromptRGB {
        switch self {
        case .white: return .white
        case .yellow: return PromptRGB(red: 1.0, green: 0.84, blue: 0.04)
        case .green: return PromptRGB(red: 0.2, green: 0.84, blue: 0.29)
        case .blue: return PromptRGB(red: 0.31, green: 0.55, blue: 1.0)
        case .pink: return PromptRGB(red: 1.0, green: 0.38, blue: 0.57)
        case .orange: return PromptRGB(red: 1.0, green: 0.62, blue: 0.04)
        }
    }
}

/// The stage's look for one set of settings.
struct PrompterStageStyle: Equatable {
    /// WCAG's large-text floor (and its non-text floor). The stage's smallest
    /// type is 18 pt (`PrompterFontSize.xs`), so every reading state is held
    /// to 3:1, read text included: a spoken word may still be glanced at.
    static let minimumContrast = 3.0
    /// The current word's mark: an underline, not weight, so the line never
    /// reflows as the word changes (design note).
    static let underlineWidth: CGFloat = 2
    /// Spec 6.5's paragraph divider.
    static let dividerDotCount = 3
    static let dividerDotDiameter: CGFloat = 3
    static let dividerDotSpacing: CGFloat = 6

    /// The dots are a shape, at the surface token: white 0.16, the value spec
    /// 6.5 gives, which is also the ramp's smallest visible fill.
    static func dividerOpacity(increaseContrast: Bool) -> Double {
        Theme.surfaceOpacity(increaseContrast: increaseContrast)
    }

    /// The glass the stage sits on, at its brightest: the drawn recipe's white
    /// wash (0.10 at the top-left) plus its specular streak (0.14, added
    /// light) over the panel's black. The stage asks for the drawn recipe
    /// (`samplesBackdrop: false`: there is nothing behind the panel's black to
    /// sample), so this is the grey its type can land on.
    static let drawnGlassBrightestGrey = 0.24
    /// Reduce Transparency's opaque panel (`GlassSurfaceStyle.solid`).
    static let solidGlassGrey = 0.11

    let increaseContrast: Bool
    let reduceTransparency: Bool
    let highlight: PrompterTint
    let cueTint: PrompterTint
    let cueBrightness: PrompterCueBrightness

    init(
        increaseContrast: Bool,
        reduceTransparency: Bool,
        highlight: PrompterTint = .white,
        cueTint: PrompterTint = .white,
        cueBrightness: PrompterCueBrightness = .dim
    ) {
        self.increaseContrast = increaseContrast
        self.reduceTransparency = reduceTransparency
        self.highlight = highlight
        self.cueTint = cueTint
        self.cueBrightness = cueBrightness
    }

    init(settings values: PrompterSettingsValues, increaseContrast: Bool, reduceTransparency: Bool) {
        self.init(
            increaseContrast: increaseContrast, reduceTransparency: reduceTransparency,
            highlight: values.highlight, cueTint: values.cueColor, cueBrightness: values.cueBrightness
        )
    }

    /// Every grey the type is measured on: the island's black, and the
    /// brightest point of the glass.
    var backdropGreys: [Double] {
        [0, reduceTransparency ? Self.solidGlassGrey : Self.drawnGlassBrightestGrey]
    }

    /// The highlight colour, lightened only as far as it has to be to clear
    /// the floor at full strength on every backdrop.
    var highlightColor: PromptRGB { Self.readable(highlight.rgb, over: backdropGreys) }
    var cueColor: PromptRGB { Self.readable(cueTint.rgb, over: backdropGreys) }

    /// Design note, word ladder: unread and current at full, read at 0.40
    /// (0.55 with Increase Contrast). Cue ladder: dim 0.45, low 0.55, medium
    /// 0.70, bright 0.90, plus 0.15 with Increase Contrast, capped at 1. Each
    /// is then raised, never lowered, to the floor its colour needs: white
    /// needs nothing, blue read at 0.40 is 1.8:1 over black and is raised.
    func opacity(for state: PrompterWordState) -> Double {
        switch state {
        case .unread, .current:
            return 1
        case .read:
            let ladder = increaseContrast ? 0.55 : 0.40
            return max(ladder, Self.floorOpacity(for: highlightColor, over: backdropGreys))
        case .cue:
            let base: Double
            switch cueBrightness {
            case .dim: base = 0.45
            case .low: base = 0.55
            case .medium: base = 0.70
            case .bright: base = 0.90
            }
            let ladder = min(1, base + (increaseContrast ? 0.15 : 0))
            return max(ladder, Self.floorOpacity(for: cueColor, over: backdropGreys))
        }
    }

    func underlines(_ state: PrompterWordState) -> Bool { state == .current }

    func color(for state: PrompterWordState) -> Color {
        (state == .cue ? cueColor : highlightColor).color.opacity(opacity(for: state))
    }

    // MARK: Measuring

    /// WCAG contrast of `rgb` at `opacity` over an sRGB grey, composited the
    /// way `LockCardLegibility` composites white (source-over in gamma space,
    /// how SwiftUI draws it), so for white this is `Theme.contrast` exactly.
    static func contrast(of rgb: PromptRGB, opacity: Double, overGrey grey: Double) -> Double {
        func over(_ channel: Double) -> Double { opacity * channel + (1 - opacity) * grey }
        let text = luminance(PromptRGB(red: over(rgb.red), green: over(rgb.green), blue: over(rgb.blue)))
        let ground = luminance(PromptRGB(red: grey, green: grey, blue: grey))
        let (light, dark) = text >= ground ? (text, ground) : (ground, text)
        return (light + 0.05) / (dark + 0.05)
    }

    /// The least opacity, in whole percent, at which `rgb` clears the floor on
    /// every grey; 1 when even full strength does not (which `readable` rules
    /// out for the colours the stage draws).
    static func floorOpacity(for rgb: PromptRGB, over greys: [Double]) -> Double {
        for percent in 1...100 {
            let opacity = Double(percent) / 100
            if greys.allSatisfy({ contrast(of: rgb, opacity: opacity, overGrey: $0) >= minimumContrast }) {
                return opacity
            }
        }
        return 1
    }

    /// `rgb` itself when it clears the floor at full strength on every grey;
    /// otherwise lightened toward white in 5 percent steps until it does.
    static func readable(_ rgb: PromptRGB, over greys: [Double]) -> PromptRGB {
        for step in 0...20 {
            let candidate = rgb.lightened(by: Double(step) * 0.05)
            if greys.allSatisfy({ contrast(of: candidate, opacity: 1, overGrey: $0) >= minimumContrast }) {
                return candidate
            }
        }
        return .white
    }

    private static func luminance(_ rgb: PromptRGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }
}

/// The stage's fixed dimensions (design note, layout at 208 pt).
enum PrompterStageMetrics {
    /// The column never comes closer than this to either side of the body.
    static let sideMargin: CGFloat = 24
    /// Controls are 24 pt targets in a 24 pt row.
    static let controlRowHeight: CGFloat = 24
    static let controlSize: CGFloat = 24
    /// Between the text region and the control row.
    static let controlRowGap: CGFloat = 6
    /// Lines drawn above and below the region, so a fast move never shows an
    /// empty edge before the next frame fills it (spec 10.2).
    static let cullBuffer: Double = 400
    /// Spec 10.5: the fade at each end of the text region is 5 percent of it.
    static let fadeFraction: CGFloat = 0.05
    /// The stage's glass sits 14 pt inside the panel's 22 pt bottom corners
    /// (the body's padding), so its own corners are the panel's less that
    /// inset: concentric curves, as the system draws nested shapes.
    static let cornerRadius: CGFloat = Theme.openBottomRadius - NotchGeometry.bodyBottomPadding

    /// `prompter.columnWidth`, never wider than the body less the margins, and
    /// never negative on a body too small to hold any.
    static func columnWidth(setting: Double, bodyWidth: Double) -> Double {
        max(0, min(setting, bodyWidth - 2 * Double(sideMargin)))
    }
}

/// The scroll curves of spec 10.3, by what moved the page.
enum PrompterStageMotion: CaseIterable, Sendable, Equatable {
    /// A clock tick in a timer mode: `linear 0.06`, so 20 Hz targets join up
    /// into one steady glide.
    case timer
    /// A recognized word (Follow, release 3): `easeOut 0.5`.
    case follow
    /// A hand on the wheel, and its settle: `easeOut 0.15`.
    case manual
    /// The reading position changed in Settings: `smooth`, 0.28 s.
    case readingPosition
    /// A new layout or page: the text is simply where it belongs.
    case cut

    var duration: Double? {
        switch self {
        case .timer: return 0.06
        case .follow: return 0.5
        case .manual: return 0.15
        case .readingPosition: return 0.28
        case .cut: return nil
        }
    }

    /// The curve, or none. Reduce Motion replaces every one with an immediate
    /// move (10.3): the page travelling is the one motion on this stage, and
    /// the setting exists to stop exactly that.
    func animation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion, let duration else { return nil }
        switch self {
        case .timer: return .linear(duration: duration)
        case .follow, .manual: return .easeOut(duration: duration)
        case .readingPosition: return .smooth(duration: duration)
        case .cut: return nil
        }
    }
}
