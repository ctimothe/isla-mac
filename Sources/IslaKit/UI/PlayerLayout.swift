import AppKit
import CoreGraphics
import SwiftUI

/// Where everything on the player sits (spec §19.6, board `R2-Music-Open`).
///
/// The board measures the player from the shape's left edge, shoulders and all:
/// the shape is 425.4 wide with a 34 pt shoulder each side, so the body the
/// panel lays out is 357.4 and a board x is a body x plus 34 (`x(_:)`). An edge
/// the board gives as a distance from the shape's *right* edge is a body x
/// through `right(_:)`. Vertically the content starts under the header row, so
/// a board y is a content y plus 38 on every notch (`SurfaceLayout.inContent`).
///
/// One place for the numbers, and pure, so a test reads the table without
/// rendering anything and a board that moves moves here.
struct PlayerLayout: Equatable {
    /// The shape's shoulder on the player (`Surface.topRadius`).
    static let shoulder: CGFloat = 34
    /// The header row's height the boards are drawn with — a 14-inch MacBook
    /// Pro's notch. Kept for the surfaces that are rendered with no notch
    /// around them.
    static let referenceHeaderHeight: CGFloat = SurfaceLayout.referenceNotchHeight

    let bodyWidth: CGFloat
    /// Whether the person has the Output button on (Settings › Music). Off, its
    /// place is empty and the other controls keep theirs.
    let hasOutputButton: Bool

    init(bodyWidth: CGFloat = Self.referenceBodyWidth, hasOutputButton: Bool = true) {
        self.bodyWidth = bodyWidth
        self.hasOutputButton = hasOutputButton
    }

    /// The player's body: the board's shape less its two shoulders.
    static var referenceBodyWidth: CGFloat { SurfaceLayout.playerReference.width - 2 * shoulder }

    /// A board x, measured from the shape's left edge, as a body x.
    static func x(_ board: CGFloat) -> CGFloat { board - shoulder }

    /// A board distance from the shape's right edge, as a body x.
    func right(_ inset: CGFloat) -> CGFloat { bodyWidth + Self.shoulder - inset }

    /// `m`, the shape's centre, which is the body's.
    var centre: CGFloat { bodyWidth / 2 }

    /// A board y, in the content's coordinates.
    static func y(_ board: CGFloat) -> CGFloat { board - SurfaceLayout.referenceNotchHeight }

    // MARK: - Frames, in content coordinates

    /// (54, 38), 60 × 60, radius 10: the cover, and the button the stage opens
    /// from.
    var cover: CGRect { CGRect(x: Self.x(54), y: Self.y(38), width: Self.coverSide, height: Self.coverSide) }
    static let coverSide: CGFloat = 60
    static let coverRadius: CGFloat = 10

    /// The title's and the subtitle's leading edge, x 129.2.
    var textLeading: CGFloat { Self.x(129.2) }
    /// The title's baseline, 65; the subtitle's, 84.5.
    var titleBaseline: CGFloat { Self.y(65) }
    var subtitleBaseline: CGFloat { Self.y(84.5) }
    static let titleSize: CGFloat = 16
    static let subtitleSize: CGFloat = 14

    /// 23 × 18 at top 49, ending 54.2 from the shape's right edge.
    var equalizer: CGRect {
        CGRect(x: right(54.2) - 23, y: Self.y(49), width: 23, height: 18)
    }

    /// The gap the title keeps before the equalizer.
    static let titleClearance: CGFloat = 8

    /// The title truncates before the equalizer.
    var titleWidth: CGFloat { equalizer.minX - Self.titleClearance - textLeading }
    /// The subtitle runs to the equalizer's right edge: nothing stands beside
    /// it.
    var subtitleWidth: CGFloat { equalizer.maxX - textLeading }

    /// The times' row: Elapsed at (53.5, 114), Remaining at top 114 ending
    /// 54.2 from the right edge.
    var timesTop: CGFloat { Self.y(114) }
    var elapsedLeading: CGFloat { Self.x(53.5) }
    var timesTrailing: CGFloat { right(54.2) }

    /// (96.7, 117.4), 231.3 × 7, radius 3.5 — ending 97.4 from the shape's
    /// right edge, so it is 231.3 on the board's 425.4.
    var progress: CGRect {
        let minX = Self.x(96.7)
        return CGRect(x: minX, y: Self.y(117.4), width: right(97.4) - minX, height: 7)
    }
    static let progressRadius: CGFloat = 3.5

    /// The controls row's centre, y 164.6.
    var controlsMidY: CGFloat { Self.y(164.6) }
    /// Every control is a 42 × 42 target.
    static let hitTarget: CGFloat = 42

    /// The five controls' centres: `m − 133`, `m − 69`, `m`, `m + 69`, `m + 133`.
    enum Control: CaseIterable, Equatable {
        case favourite, previous, playPause, next, output

        var offset: CGFloat {
            switch self {
            case .favourite: return -133
            case .previous: return -69
            case .playPause: return 0
            case .next: return 69
            case .output: return 133
            }
        }

        /// The glyph's drawn size on the board.
        var glyph: CGSize {
            switch self {
            case .favourite, .output: return CGSize(width: 28, height: 27)
            case .previous, .next: return CGSize(width: 35, height: 22)
            case .playPause: return CGSize(width: 29, height: 34)
            }
        }
    }

    /// The 42 × 42 target a control is centred in.
    func target(_ control: Control) -> CGRect {
        let side = Self.hitTarget
        return CGRect(x: centre + control.offset - side / 2, y: controlsMidY - side / 2, width: side, height: side)
    }

    /// The Output button's target, or nil while the person has it off.
    var output: CGRect? { hasOutputButton ? target(.output) : nil }

    // MARK: - Nothing playing (spec §4.8, in §19.6's frame)

    /// The well where the cover goes, at the cover's frame.
    var emptyWell: CGRect { cover }

    /// What the empty player lays out, by state — pure, so §4.8's three states
    /// in the player's frame are a test. The status and its line of why are in
    /// the title's column, top-aligned with the well; the remedy is the
    /// controls row; the reader-down pointer sits under it.
    struct EmptyFrames: Equatable {
        /// The status and the line under it, as one column.
        let text: CGRect
        let headlineSize: CGFloat
        /// The row of buttons, as wide as the times' row.
        let buttons: CGRect
        let footer: CGRect?

        static let buttonHeight: CGFloat = 22
        static let buttonSpacing: CGFloat = 8
        static let openButtonHorizontalPadding: CGFloat = 10
    }

    // MARK: - The empty player's "Open …" buttons

    /// Most buttons the empty player offers. The fit below decides how many
    /// of the three the 318 pt row holds, per name.
    static let maxOpenButtons = 3
    /// The app's own icon at the button's leading edge, and the gap after it.
    static let openButtonIconSide: CGFloat = 16
    static let openButtonIconGap: CGFloat = 6

    /// What the row of buttons may occupy: the controls row's own span, from
    /// the elapsed time's leading edge to the remaining time's trailing one.
    static func openButtonsRoom(bodyWidth: CGFloat) -> CGFloat {
        PlayerLayout(bodyWidth: bodyWidth).timesTrailing - x(53.5)
    }

    /// How a row of "Open …" buttons is dressed, from the generous form to the
    /// tightest. The Russian row is why this exists: at 480 the text column
    /// leaves 260 pt, and «Открыть Apple Music» beside «Открыть Spotify» needs
    /// about 290 with an icon and ten points of padding a side, so the row
    /// dropped Spotify, which the spec and every earlier build always offered.
    /// Two buttons that always appear, squeezed a little, beat a third button
    /// and a missing Spotify.
    enum OpenButtonForm: CaseIterable, Equatable {
        /// The icon, and 10 pt of padding either side.
        case full
        /// The icon still, with 6 pt of padding: the first thing given up.
        case tight
        /// Words only, 6 pt of padding: what a long language at the narrowest
        /// panel comes to. Never truncated, so this is the last step.
        case iconless

        var horizontalPadding: CGFloat { self == .full ? EmptyFrames.openButtonHorizontalPadding : 6 }
        var showsIcon: Bool { self != .iconless }
    }

    /// One button's width: the padding either side, the icon and its gap (in the
    /// forms that draw one), and the label as the `body` role sets it. A button
    /// is never truncated, so this is what the fit below is made of;
    /// `labelWidth` is injected so a test names the width it means and the view
    /// measures the real string.
    static func openButtonWidth(labelWidth: CGFloat, form: OpenButtonForm = .full) -> CGFloat {
        form.horizontalPadding * 2
            + (form.showsIcon ? openButtonIconSide + openButtonIconGap : 0) + labelWidth
    }

    /// The label's width in the `body` role (11 pt medium, 0.07 pt of tracking
    /// a character), rounded up and padded by a point so the rendered text
    /// never needs the last pixel of its button.
    static func measuredLabelWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Theme.TypeRole.body.size, weight: .medium)
        let kern = Theme.tracking(forSize: Theme.TypeRole.body.size)
        let width = (text as NSString).size(withAttributes: [.font: font, .kern: kern]).width
        return ceil(width) + 1
    }

    /// The buttons the row shows and the form they are drawn in.
    struct OpenButtonRow: Equatable {
        var apps: [AppIcons.Installed]
        var form: OpenButtonForm
    }

    /// Which of the installed music apps get a button, and how they are dressed.
    ///
    /// The installed `MediaSourcePolicy.leadingApps` (Apple Music, Spotify) are
    /// always offered. If they do not fit in the full form they are drawn
    /// tighter — less padding, then no icon — until they do, and the row offers
    /// nothing else. Only when they fit in the full form do the other apps
    /// follow, in the order given, as the longest prefix that still fits `room`
    /// with `spacing` between buttons, at most `limit`.
    ///
    /// A prefix and not "whatever fits": a long name skipped to make room for
    /// a short one further down would put an app nobody has heard of ahead of
    /// Spotify. And never a truncated button: when even the iconless form is
    /// too wide the row is still that form (two short words cannot be made
    /// shorter), but no supported panel width reaches it.
    static func openButtonRow(
        _ apps: [AppIcons.Installed], room: CGFloat, spacing: CGFloat = EmptyFrames.buttonSpacing,
        limit: Int = maxOpenButtons, labelWidth: (AppIcons.Installed) -> CGFloat
    ) -> OpenButtonRow {
        let lead = MediaSourcePolicy.leadingApps
        let required = apps.filter { lead.contains($0.bundleID) }
        let ordered = required + apps.filter { !lead.contains($0.bundleID) }
        func width(_ list: [AppIcons.Installed], _ form: OpenButtonForm) -> CGFloat {
            list.reduce(0) { $0 + openButtonWidth(labelWidth: labelWidth($1), form: form) }
                + spacing * CGFloat(max(0, list.count - 1))
        }
        guard width(required, .full) <= room else {
            let form = [OpenButtonForm.tight, .iconless].first { width(required, $0) <= room } ?? .iconless
            return OpenButtonRow(apps: required, form: form)
        }
        var chosen: [AppIcons.Installed] = []
        var used: CGFloat = 0
        for app in ordered {
            guard chosen.count < limit else { break }
            let w = openButtonWidth(labelWidth: labelWidth(app))
            let next = used + (chosen.isEmpty ? 0 : spacing) + w
            guard next <= room else { break }
            chosen.append(app)
            used = next
        }
        return OpenButtonRow(apps: chosen, form: .full)
    }

    /// The apps alone, for a caller that does not draw.
    static func openButtonApps(
        _ apps: [AppIcons.Installed], room: CGFloat, spacing: CGFloat = EmptyFrames.buttonSpacing,
        limit: Int = maxOpenButtons, labelWidth: (AppIcons.Installed) -> CGFloat
    ) -> [AppIcons.Installed] {
        openButtonRow(apps, room: room, spacing: spacing, limit: limit, labelWidth: labelWidth).apps
    }

    static func emptyFrames(
        for message: MediaPane.EmptyStateMessage, bodyWidth: CGFloat = referenceBodyWidth
    ) -> EmptyFrames {
        let layout = PlayerLayout(bodyWidth: bodyWidth)
        let leading = layout.elapsedLeading
        let width = layout.timesTrailing - leading
        let text = CGRect(x: layout.textLeading, y: layout.cover.minY, width: layout.subtitleWidth, height: 92)
        let buttons = CGRect(
            x: leading, y: layout.controlsMidY - EmptyFrames.buttonHeight / 2 - 8,
            width: width, height: EmptyFrames.buttonHeight
        )
        switch message {
        case .nothingPlaying, .hiddenByMusicOnly:
            return EmptyFrames(text: text, headlineSize: 14, buttons: buttons, footer: nil)
        case .readerDown:
            return EmptyFrames(
                text: text, headlineSize: 14, buttons: buttons,
                footer: CGRect(x: leading, y: buttons.maxY + 8, width: width, height: 14)
            )
        }
    }
}

// MARK: - The lyric ramp (spec §19.6)

extension PlayerLayout {
    /// The opacity the stage's board gives the line `offset` rows from the sung
    /// one (negative above): lines already sung 0.34 and 0.20 by distance, lines
    /// to come 0.50, 0.32 and 0.18, and past the board's last row the faintest.
    static func boardLyricOpacity(offset: Int) -> Double {
        let board: [Int: Double] = [-2: 0.20, -1: 0.34, 0: 1, 1: 0.50, 2: 0.32, 3: 0.18]
        if let value = board[offset] { return value }
        return offset < 0 ? 0.20 : 0.18
    }

    /// The opacity a context line is *drawn* at: the board's, raised to the
    /// ramp's contrast floor where the board is dimmer.
    ///
    /// `Theme`'s floor (`LyricRow.Ramp`, WCAG 3:1 over black, held by
    /// `ContrastRampTests`) is 0.36 and the neighbour's 0.42, and the floor wins
    /// over the boards (§2.1). So the board's order — the line after the sung
    /// one the brightest context, the lines above dimmer than those below — is
    /// kept where it clears the floor: the line above becomes 0.42, the line
    /// after it stays 0.50, and every line the board draws under the floor is
    /// drawn at it. Reading by hand lifts every context line to the ramp's
    /// reading step, as it does everywhere.
    static func lyricOpacity(offset: Int, ramp: LyricRow.Ramp, reading: Bool) -> Double {
        if offset == 0 { return 1 }
        if reading { return ramp.reading }
        let floor = abs(offset) == 1 ? ramp.neighbour : ramp.floor
        return max(boardLyricOpacity(offset: offset), floor)
    }

    /// The translation row's type (§5.3 on the stage): 13 regular, under the
    /// sung line and every other.
    static func translationStyle(isSung: Bool) -> (size: CGFloat, weight: Font.Weight) {
        (13, .regular)
    }

    /// How bright a translation row is drawn: the sung line's at the board's
    /// 0.66, every other line's at 0.45 — raised to the panel's tertiary label
    /// grey, which is the floor for 13 pt regular text (4.5:1 over black), so
    /// 0.50, and 0.65 with Increase Contrast. The spec says the floor wins over
    /// the boards (§2.1); the lyric ramp's own 0.36 floor is the large-type one.
    static func translationOpacity(isSung: Bool, increaseContrast: Bool) -> Double {
        let floor = Theme.tertiaryOpacity(increaseContrast: increaseContrast)
        return max(isSung ? 0.66 : 0.45, floor)
    }
}
