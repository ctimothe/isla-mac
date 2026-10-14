import CoreGraphics
import SwiftUI

/// Where everything in the 208 pt Music player sits (spec §4.1, §4.8).
///
/// The board is drawn in *body coordinates* — the origin is the open body's
/// top-left corner, which sits at the top of the screen, and the first
/// `headerHeight` points are the header row (spec §1). The pane the player is
/// drawn in starts to the right of the rail and under the header, so every frame
/// here is stated twice: in body coordinates, as the spec writes it, and — through
/// `inPane(_:)`, the one conversion — in the pane's own, which is what the view
/// places things by. Nothing else in the app converts between the two, so a test
/// that holds the spec's numbers holds the pixels, and a board that moves moves
/// here and nowhere else.
///
/// Why the conversion is `(58, headerHeight)`: the shell pads the body 14 pt on
/// each side, the rail is 30 pt wide and a 14 pt gap follows it — 14 + 30 + 14 =
/// 58, which is exactly where the board puts the cover's left edge, so the cover
/// is the pane's own origin. Vertically the pane starts where the header ends, so
/// a body y is the pane y plus the header's height *whatever that height is*: a
/// Mac whose notch is 32 pt tall puts the player's rows at the same screen
/// position as one whose notch is 38, because the pane is simply taller there.
///
/// Pure, so the layout is something a test reads at 480, 560 and 620 and in
/// Russian without rendering anything.
struct PlayerLayout: Equatable {
    // MARK: - Body to pane

    /// The shell's own padding either side of the rail and the pane
    /// (`NotchContentView.content`), the rail's width (`Rail`) and the gap
    /// between rail and pane. One home for the three numbers the cover's
    /// x of 58 is made of.
    static let bodyInset: CGFloat = 14
    static let railWidth: CGFloat = 30
    static let railGap: CGFloat = 14

    /// The pane's left edge in body coordinates: 14 + 30 + 14.
    static var paneLeading: CGFloat { bodyInset + railWidth + railGap }
    /// What the pane leaves free on its right: the body's padding.
    static var paneTrailing: CGFloat { bodyInset }
    /// The header's height on a 14-inch MacBook Pro, which the boards are drawn
    /// with. Used where a pane is rendered with no notch around it.
    static let referenceHeaderHeight: CGFloat = 38

    /// The pane's width for a body of `bodyWidth`.
    static func paneWidth(bodyWidth: CGFloat) -> CGFloat {
        bodyWidth - paneLeading - paneTrailing
    }

    /// The body width a pane of `paneWidth` belongs to — the inverse, so the
    /// view can learn `bw` from the width it is handed.
    static func bodyWidth(paneWidth: CGFloat) -> CGFloat {
        paneWidth + paneLeading + paneTrailing
    }

    // MARK: - Thresholds

    /// Below this body width the slider is not drawn in the player — it would be
    /// narrower than its knob — and the Output menu carries it instead
    /// (spec §4.5, `Stress-Music-480`).
    static let volumeFoldWidth: CGFloat = 540

    /// How far the progress row, the transport and the controls rise when the
    /// lyric band folds away (spec §4.1 last paragraph). The metadata does the
    /// opposite — the title steps *down* 18, from 52 to 70, so the two lines of
    /// text sit in the middle of the cover's height instead of hugging its top
    /// with a hole under them (`Music-NoLyrics`).
    static let noLyricRise: CGFloat = 20

    // MARK: - Inputs

    let bodyWidth: CGFloat
    let headerHeight: CGFloat
    /// Whether the two-line lyric band is drawn (spec §4.3).
    let hasLyricBand: Bool
    /// Whether the person has Volume and Output on *and* the default device has
    /// a volume to give. Off, both controls are absent and the band keeps its
    /// place (spec §4.5).
    let hasVolumeAndOutput: Bool

    init(
        bodyWidth: CGFloat,
        headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight,
        hasLyricBand: Bool = true,
        hasVolumeAndOutput: Bool = true
    ) {
        self.bodyWidth = bodyWidth
        self.headerHeight = headerHeight
        self.hasLyricBand = hasLyricBand
        self.hasVolumeAndOutput = hasVolumeAndOutput
    }

    /// The body is wider than 560 by this much; everything against the trailing
    /// edge moves by it, and the title column and the slider take it.
    var widthDelta: CGFloat { bodyWidth - NotchMetrics.defaultBodyWidth }

    /// Whether the slider is drawn in the player (the Output menu carries it
    /// below `volumeFoldWidth`).
    var showsVolumeSlider: Bool {
        hasVolumeAndOutput && bodyWidth >= Self.volumeFoldWidth
    }

    /// Whether the Output menu has to carry the slider.
    var volumeFoldsIntoMenu: Bool {
        hasVolumeAndOutput && bodyWidth < Self.volumeFoldWidth
    }

    // MARK: - The conversion

    /// A frame in body coordinates, in the pane's. The one conversion: the
    /// pane's origin is `(paneLeading, headerHeight)` in body coordinates.
    static func inPane(_ body: CGRect, headerHeight: CGFloat) -> CGRect {
        body.offsetBy(dx: -paneLeading, dy: -headerHeight)
    }

    func inPane(_ body: CGRect) -> CGRect {
        Self.inPane(body, headerHeight: headerHeight)
    }

    /// The pane's own size at this body width, on a 208 pt body with the
    /// shell's 14 pt below it.
    var paneSize: CGSize {
        CGSize(
            width: Self.paneWidth(bodyWidth: bodyWidth),
            height: NotchMetrics.standardBodyHeight - NotchGeometry.bodyBottomPadding - headerHeight
        )
    }

    // MARK: - Frames, in body coordinates

    /// What a no-band layout moves up by.
    private var rise: CGFloat { hasLyricBand ? 0 : Self.noLyricRise }

    /// The text column's width: `bw − 220`, the title's and subtitle's ceiling,
    /// the band's, and the progress row's.
    var columnWidth: CGFloat { bodyWidth - 220 }

    static let columnLeading: CGFloat = 206

    var cover: CGRect { CGRect(x: Self.paneLeading, y: 54, width: 132, height: 132) }

    /// 16 pt semibold; 52, or 70 without a band (see `noLyricRise`).
    var title: CGRect {
        CGRect(x: Self.columnLeading, y: hasLyricBand ? 52 : 70, width: columnWidth, height: 20)
    }

    var subtitle: CGRect {
        CGRect(x: Self.columnLeading, y: title.minY + 21, width: columnWidth, height: 16)
    }

    /// The sung line and the next one, 18 pt apart. Absent without a band.
    var sungLine: CGRect { CGRect(x: Self.columnLeading, y: 99, width: columnWidth, height: 17) }
    var nextLine: CGRect { CGRect(x: Self.columnLeading, y: 117, width: columnWidth, height: 17) }

    var progress: CGRect {
        CGRect(x: Self.columnLeading, y: 141 - rise, width: columnWidth, height: 12)
    }

    var shuffle: CGRect { CGRect(x: Self.columnLeading, y: transport.minY + 2, width: 24, height: 24) }
    var transport: CGRect { CGRect(x: 236, y: 158 - rise, width: 100, height: 28) }
    var repeatButton: CGRect { CGRect(x: 342, y: transport.minY + 2, width: 24, height: 24) }

    /// `96 + (bw − 560)` wide, 12 tall; nil where it is not drawn.
    var volume: CGRect? {
        guard showsVolumeSlider else { return nil }
        return CGRect(x: 384, y: 166 - rise, width: 96 + widthDelta, height: 12)
    }

    /// The trailing pair rides the edge: Output at `bw − 68`, Lyrics at
    /// `bw − 40`, each 26 × 26 — the last one ends at `bw − 14`, which is the
    /// pane's own right edge.
    var output: CGRect? {
        guard hasVolumeAndOutput else { return nil }
        return CGRect(x: bodyWidth - 68, y: 159 - rise, width: 26, height: 26)
    }

    var lyrics: CGRect {
        CGRect(x: bodyWidth - 40, y: 159 - rise, width: 26, height: 26)
    }

    // MARK: - Nothing playing (spec §4.8)

    /// The well that stands where the cover goes: the playing layout's frame.
    static let emptyWell = CGRect(x: paneLeading, y: 54, width: 132, height: 132)

    /// What the empty tab lays out, by state — pure, so the table in §4.8 is a
    /// test. `titleY`, `bodyY`, `buttonsY` are body y for the elements the
    /// table lists; `footerY` is the reader-down line under the buttons.
    struct EmptyFrames: Equatable {
        let titleY: CGFloat
        let titleSize: CGFloat
        let bodyY: CGFloat
        let buttonsY: CGFloat
        let footerY: CGFloat?

        /// Wrapping width of the title and the body (spec: "wraps at 330").
        static let textWidth: CGFloat = 330
        static let buttonHeight: CGFloat = 22
        static let buttonSpacing: CGFloat = 8
    }

    static func emptyFrames(for message: MediaPane.EmptyStateMessage) -> EmptyFrames {
        switch message {
        case .nothingPlaying:
            return EmptyFrames(titleY: 80, titleSize: 16, bodyY: 103, buttonsY: 132, footerY: nil)
        case .readerDown:
            return EmptyFrames(titleY: 70, titleSize: 16, bodyY: 93, buttonsY: 120, footerY: 153)
        case .hiddenByMusicOnly:
            // 15 / semibold on the board, wrapping: the `title` role's 16 is the
            // size that ships (spec §2.2 maps 15 and 16 to it).
            return EmptyFrames(titleY: 72, titleSize: 16, bodyY: 115, buttonsY: 140, footerY: nil)
        }
    }
}

// MARK: - Player, column, tall (spec §5.1, §6)

/// The three views of one model: the player `P`, the lyric column `C` and the
/// tall lyric page `T` (spec §5.1).
///
/// They are not three panes swapped by a transition. The cover, the title, the
/// progress row, the transport, the volume bar and the two buttons are the very
/// same views in all three, and what changes with the state is only the frame
/// each is placed in — so a state change is an animation of frames, and every
/// element *travels* to its next place instead of fading out where it was and
/// in where it goes. (`matchedGeometryEffect` is for a pair of views one of
/// which is inserted while the other leaves; here nothing leaves, which is
/// both simpler and sturdier: there is no id pair to drift apart.) The one
/// matched pair left is the cover's, with the island's own — see `MediaPane`.
///
/// Every frame is a row of the table in the spec, so `frames(for:)` is that
/// table and the tests read it at 480, 560 and 620.
extension PlayerLayout {
    enum State: Equatable, CaseIterable {
        case player
        case column
        case tall

        /// The body height the state sits in: the player and the column in the
        /// standard 208, the tall page in the 400 the window was cut for
        /// (`NotchMetrics.tallestBody`). One home for the pair, so `openBodySize`
        /// and the layout cannot disagree about what "tall" is.
        var bodyHeight: CGFloat {
            self == .tall ? NotchMetrics.tallestBody.height : NotchMetrics.standardBodyHeight
        }

        /// What the Lyrics button does from here: the player opens the column,
        /// and the column or the tall page closes back to the player (§5.1:
        /// "P ↔ C on the Lyrics button").
        var afterLyricsButton: Bool { self == .player }
    }

    /// Every element's frame in body coordinates for one state. `nil` where the
    /// state does not draw it.
    struct StateFrames: Equatable {
        var bodyHeight: CGFloat
        var cover: CGRect
        var coverRadius: CGFloat
        var title: CGRect
        /// The size the title is set in: 16 in the player, 13 in the column and
        /// on the tall page (role `title` / `subhead`).
        var titleSize: CGFloat
        /// The player's "Artist — Album" line; the column's and the tall page's
        /// artist-only line. The two are drawn as one frame each state.
        var subtitle: CGRect
        var subtitleSize: CGFloat
        /// Whether the subtitle is the full line (the player) or the artist
        /// alone (the column and the tall page).
        var subtitleIsArtistOnly: Bool
        var progress: CGRect
        var transport: CGRect
        /// Shuffle and Repeat flank the transport in the player and fold away
        /// in the column and the tall page ("for reading", the board says); the
        /// frames are still given so they fold *into* the transport instead of
        /// vanishing from nowhere.
        var shuffle: CGRect
        var repeatButton: CGRect
        var showsModes: Bool
        var volume: CGRect?
        var output: CGRect?
        var lyrics: CGRect
        /// The lyric lines' region — the page the lines scroll in. The player
        /// has none: its two-line band is `sungLine` / `nextLine`.
        var lyricArea: CGRect?
        /// The sung line's frame in the column and on the tall page, so the
        /// reading centre is one number that comes from the table: the line the
        /// song is in sits here and the lines move through it.
        var sungLine: CGRect?
        /// Distance between two lines' tops, the fixed slot every row occupies.
        var lyricPitch: CGFloat?
        var lyricSize: CGFloat?
    }

    /// The spec's table, for this layout's width, header and settings.
    func frames(for state: State) -> StateFrames {
        switch state {
        case .player:
            return StateFrames(
                bodyHeight: state.bodyHeight,
                cover: cover, coverRadius: 14,
                title: title, titleSize: Theme.TypeRole.title.size,
                subtitle: subtitle, subtitleSize: Theme.TypeRole.reading.size, subtitleIsArtistOnly: false,
                progress: progress, transport: transport,
                shuffle: shuffle, repeatButton: repeatButton, showsModes: true,
                volume: volume, output: output, lyrics: lyrics,
                lyricArea: nil, sungLine: hasLyricBand ? sungLine : nil, lyricPitch: nil, lyricSize: nil
            )
        case .column:
            return StateFrames(
                bodyHeight: state.bodyHeight,
                cover: CGRect(x: Self.paneLeading, y: 50, width: 52, height: 52), coverRadius: 9,
                title: CGRect(x: 122, y: 53, width: Self.columnTitleWidth, height: 16),
                titleSize: Theme.TypeRole.subhead.size,
                subtitle: CGRect(x: 122, y: 71, width: Self.columnTitleWidth, height: 14),
                subtitleSize: Theme.TypeRole.body.size, subtitleIsArtistOnly: true,
                progress: CGRect(x: Self.paneLeading, y: 116, width: 190, height: 12),
                transport: CGRect(x: 84, y: 136, width: 138, height: 28),
                shuffle: CGRect(x: 84, y: 138, width: 24, height: 24),
                repeatButton: CGRect(x: 200, y: 138, width: 24, height: 24), showsModes: false,
                volume: hasVolumeAndOutput ? CGRect(x: Self.paneLeading, y: 176, width: 128, height: 12) : nil,
                output: hasVolumeAndOutput ? CGRect(x: 197, y: 169, width: 26, height: 26) : nil,
                lyrics: CGRect(x: 225, y: 169, width: 26, height: 26),
                // From the header's foot to the pane's bottom, `bw − 282` wide:
                // 268 is where the lines start, the pane's own edge `bw − 14`
                // where they end.
                lyricArea: CGRect(
                    x: Self.columnLinesLeading, y: headerHeight,
                    width: bodyWidth - Self.columnLinesLeading - Self.paneTrailing,
                    height: state.bodyHeight - NotchGeometry.bodyBottomPadding - headerHeight
                ),
                sungLine: CGRect(x: Self.columnLinesLeading, y: 96, width: bodyWidth - Self.columnLinesLeading - Self.paneTrailing, height: 17),
                lyricPitch: 23, lyricSize: Theme.TypeRole.subhead.size
            )
        case .tall:
            // The footer row, right to left, from the trailing edge: Lyrics at
            // `bw − 45`, Output at `bw − 75`, the volume bar's right end 19
            // before Output, the progress row's 12 before the volume bar. At
            // 560 that is the board's 515 / 485 / 388 and 158 + 218.
            let outputX = bodyWidth - 75
            let volumeX = outputX - 19 - 78
            return StateFrames(
                bodyHeight: state.bodyHeight,
                cover: CGRect(x: Self.paneLeading, y: 46, width: 34, height: 34), coverRadius: 7,
                title: CGRect(x: 102, y: 46, width: bodyWidth - 102 - Self.paneTrailing, height: 16),
                titleSize: Theme.TypeRole.subhead.size,
                subtitle: CGRect(x: 102, y: 63, width: bodyWidth - 102 - Self.paneTrailing, height: 14),
                subtitleSize: Theme.TypeRole.body.size, subtitleIsArtistOnly: true,
                progress: CGRect(x: 158, y: 358, width: volumeX - 12 - 158, height: 12),
                transport: CGRect(x: 60, y: 350, width: 92, height: 28),
                shuffle: CGRect(x: 60, y: 352, width: 24, height: 24),
                repeatButton: CGRect(x: 128, y: 352, width: 24, height: 24), showsModes: false,
                volume: hasVolumeAndOutput ? CGRect(x: volumeX, y: 358, width: 78, height: 12) : nil,
                output: hasVolumeAndOutput ? CGRect(x: outputX, y: 351, width: 26, height: 26) : nil,
                lyrics: CGRect(x: bodyWidth - 45, y: 351, width: 26, height: 26),
                // The page between the cover row and the footer: the lines run
                // the pane's width from the cover's own left edge.
                lyricArea: CGRect(
                    x: Self.paneLeading, y: Self.tallAreaTop,
                    width: bodyWidth - Self.paneLeading - Self.paneTrailing,
                    height: Self.tallAreaBottom - Self.tallAreaTop
                ),
                sungLine: CGRect(x: Self.paneLeading, y: 166, width: bodyWidth - Self.paneLeading - Self.paneTrailing, height: 21),
                lyricPitch: 34, lyricSize: Theme.TypeRole.lyric.size
            )
        }
    }

    /// The same table without building an instance, for a test or a caller that
    /// has only a width.
    static func frames(
        for state: State, bodyWidth: CGFloat, headerHeight: CGFloat = referenceHeaderHeight,
        hasVolumeAndOutput: Bool = true
    ) -> StateFrames {
        PlayerLayout(bodyWidth: bodyWidth, headerHeight: headerHeight, hasVolumeAndOutput: hasVolumeAndOutput)
            .frames(for: state)
    }

    /// Where the column's lines start (`x 268`), and how wide the title may be
    /// before it: from the title's 122 to the lines, less the 6 pt a lyric needs
    /// to not read as the title's continuation.
    static let columnLinesLeading: CGFloat = 268
    static let columnTitleWidth: CGFloat = 140

    /// The tall page's lyric region: under the cover row (46…80) and above the
    /// footer (350).
    static let tallAreaTop: CGFloat = 86
    static let tallAreaBottom: CGFloat = 338

    // MARK: Lyric ramp (spec §5.1)

    /// The opacity the board gives the line `offset` rows from the sung one
    /// (negative above). The column's are 0.22, 0.36, **1.0**, 0.5, 0.32, 0.18;
    /// the tall page's 0.16, 0.30, **1.0**, 0.50, 0.32, 0.20, 0.12. Past the
    /// board's last row a line is the faintest there is.
    static func boardLyricOpacity(offset: Int, tall: Bool) -> Double {
        let column: [Int: Double] = [-2: 0.22, -1: 0.36, 0: 1, 1: 0.5, 2: 0.32, 3: 0.18]
        let page: [Int: Double] = [-2: 0.16, -1: 0.30, 0: 1, 1: 0.50, 2: 0.32, 3: 0.20, 4: 0.12]
        let table = tall ? page : column
        if let value = table[offset] { return value }
        return tall ? 0.12 : 0.18
    }

    /// The opacity a context line is *drawn* at: the board's, raised to the
    /// ramp's contrast floor where the board is dimmer.
    ///
    /// The canvas draws its far lines at white 0.12–0.32; `Theme`'s contrast
    /// floor (`LyricRow.Ramp`, WCAG 3:1 over black, held by `ContrastRampTests`)
    /// is 0.36 and the neighbour's 0.42, and the spec says the floor wins over
    /// the boards (§2.1). So the board's order — above the sung line dimmer than
    /// below it, the next line the brightest context — is kept where it clears
    /// the floor, and a line the board draws under it is drawn at the floor:
    /// the column's 0.22/0.32/0.18 and the tall page's 0.16/0.30/0.32/0.20/0.12
    /// all become 0.36, the line above the sung one 0.42, and the line after it
    /// stays 0.5 (it already clears). Reading by hand lifts every context line
    /// to the ramp's reading step, as it does everywhere.
    static func lyricOpacity(
        offset: Int, tall: Bool, ramp: LyricRow.Ramp, reading: Bool
    ) -> Double {
        if offset == 0 { return 1 }
        if reading { return ramp.reading }
        let floor = abs(offset) == 1 ? ramp.neighbour : ramp.floor
        return max(boardLyricOpacity(offset: offset, tall: tall), floor)
    }

    // MARK: Animation (spec §2.4)

    /// How a change of state is animated: P ↔ C on `openAnimation` (the body
    /// keeps its height), C ↔ T on `expandAnimation` (the body grows or shrinks
    /// and everything travels with it), and a straight P ↔ T — the tall state
    /// remembered across a visit to the player — on the one that moves the
    /// body. Reduce Motion takes the travel away from all three: the 0.24
    /// crossfade (`Theme.reducedMotion`).
    static func animation(from: State, to: State, reduceMotion: Bool) -> Animation {
        if reduceMotion { return Theme.reducedMotion }
        return from.bodyHeight == to.bodyHeight ? Theme.openAnimation : Theme.expandAnimation
    }

    // MARK: A new track (spec §5.1)

    /// Whether a column opened before the track changed should fall back to the
    /// player: only when the new song has no lyrics to put in it — a miss the
    /// lookup has *settled*, never the moment of the change, when the answer is
    /// not in yet. Otherwise the column stays: it is where the person chose to
    /// be.
    static func shouldReturnToPlayer(awaitingNewTrack: Bool, availability: LyricsAvailability) -> Bool {
        guard awaitingNewTrack else { return false }
        switch availability {
        case .noLocalLyrics, .invalidLocalFile, .cannotLookUp: return true
        case .disabled, .resolving, .findingLocalLyrics, .ready: return false
        }
    }
}

/// The three header tools' frames, in body coordinates (spec §5.2, §6): Show
/// Translation at `bw − 91`, More at `bw − 65` and Expand / Collapse at
/// `bw − 39`, each 22 × 22 and 8 below the top. Fixed in every state, so the
/// two that are always there never move and the one that is hidden until the
/// translation release leaves a gap rather than sliding its neighbour.
enum HeaderToolFrames {
    static let side: CGFloat = 22
    static let top: CGFloat = 8
    static let spacing: CGFloat = 4

    static func showTranslation(bodyWidth: CGFloat) -> CGRect {
        CGRect(x: bodyWidth - 91, y: top, width: side, height: side)
    }

    static func more(bodyWidth: CGFloat) -> CGRect {
        CGRect(x: bodyWidth - 91 + side + spacing, y: top, width: side, height: side)
    }

    static func expand(bodyWidth: CGFloat) -> CGRect {
        CGRect(x: bodyWidth - 39, y: top, width: side, height: side)
    }
}
