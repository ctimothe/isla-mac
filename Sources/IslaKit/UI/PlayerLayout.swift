import CoreGraphics

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
