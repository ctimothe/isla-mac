import CoreGraphics

/// The Prompter tab's geometry, as numbers a test can hold to the body.
///
/// The tab lives in the 208 pt body beside the 30 pt rail, under the notch and
/// above the body's bottom padding, so on the deepest supported notch at the
/// narrowest width it has 154 by 408 points to be useful in. These are the
/// heights and widths the view lays itself out with; `PrompterTabLayoutTests`
/// asserts them at 480, 560 and 620 pt on the shallowest and deepest notch,
/// in both languages, so a row cannot quietly grow past the body.
enum PrompterTabMetrics {
    // MARK: The pane

    /// `NotchContentView`'s body padding on each side, the rail and the gap
    /// between the rail and the pane.
    static let bodySidePadding: CGFloat = 14
    static let railWidth: CGFloat = 30
    static let railGap: CGFloat = 14

    static func paneSize(bodyWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
        CGSize(
            width: bodyWidth - 2 * bodySidePadding - railWidth - railGap,
            height: NotchMetrics.standardBodyHeight - notchHeight - NotchGeometry.bodyBottomPadding
        )
    }

    // MARK: Rows

    static let scriptRowHeight: CGFloat = 22
    /// Between the script menu, New Script and Delete Script.
    static let scriptRowGap: CGFloat = 6
    /// The least the script menu is squeezed to before its title truncates
    /// no further: a few words of the title and the chevron.
    static let minimumScriptMenuWidth: CGFloat = 96
    static let chipRowHeight: CGFloat = 22
    static let quietLineHeight: CGFloat = 14
    static let controlRowHeight: CGFloat = 26
    static let rowGap: CGFloat = 4
    /// About three lines of the editor's 13 pt text. The editor takes
    /// whatever the fixed rows leave, which on the deepest notch is 54.
    static let minimumEditorHeight: CGFloat = 40

    struct Layout: Equatable {
        var scriptRow: CGRect
        var chipRow: CGRect
        var editor: CGRect
        var quietLine: CGRect
        var controlRow: CGRect
    }

    /// Top to bottom: the script, its page chips, the editor, one quiet line
    /// (counts, the capture chip, or the single message there is), and the
    /// control row.
    static func layout(in size: CGSize) -> Layout {
        let fixed = scriptRowHeight + chipRowHeight + quietLineHeight + controlRowHeight + 4 * rowGap
        let editorHeight = max(0, size.height - fixed)
        var y: CGFloat = 0
        func row(_ height: CGFloat) -> CGRect {
            defer { y += height + rowGap }
            return CGRect(x: 0, y: y, width: size.width, height: height)
        }
        return Layout(
            scriptRow: row(scriptRowHeight),
            chipRow: row(chipRowHeight),
            editor: row(editorHeight),
            quietLine: row(quietLineHeight),
            controlRow: row(controlRowHeight)
        )
    }

    // MARK: Page chips

    static let chipHeight: CGFloat = 22
    static let chipSpacing: CGFloat = 4
    static let chipRowGap: CGFloat = 4
    static let addButtonWidth: CGFloat = 24
    /// "Delete Page" in the longer language, with the armed word's room.
    static let deleteControlWidth: CGFloat = 112
    /// The read mark a chip wears once its page's end was reached.
    static let readMarkWidth: CGFloat = 10

    static func chipWidth(index: Int, read: Bool) -> CGFloat {
        let digits = CGFloat(String(index + 1).count)
        return max(26, 14 + 7 * digits) + (read ? readMarkWidth : 0)
    }

    /// Every chip laid end to end, the first `readCount` wearing a mark: the
    /// widest the strip can be for that many reads.
    static func chipStripWidth(count: Int, readCount: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        var width: CGFloat = 0
        for index in 0..<count {
            width += chipWidth(index: index, read: index < readCount)
        }
        return width + CGFloat(count - 1) * chipSpacing
    }

    /// Chips scroll sideways rather than wrap or overflow: a talk can have 200
    /// pages, and a second row of them would not fit the body. The strip gives
    /// way to the add and delete controls, never the reverse.
    static func chipStrip(count: Int, readCount: Int, paneWidth: CGFloat) -> (width: CGFloat, scrolls: Bool) {
        let content = chipStripWidth(count: count, readCount: readCount)
        let available = paneWidth - addButtonWidth - deleteControlWidth - 2 * chipRowGap
        return (min(content, max(0, available)), content > available)
    }

    // MARK: Control row

    /// The speed stepper: slower, the value, faster.
    static let stepperWidth: CGFloat = 108
    static let controlGap: CGFloat = 12
    static let startHorizontalPadding: CGFloat = 12
    static let minimumStartWidth: CGFloat = 64

    /// The primary control, wide enough for its word with room to spare. The
    /// view makes it fixed-size, so it is the stepper's gap that gives way.
    static func startControlWidth(labelWidth: CGFloat) -> CGFloat {
        max(minimumStartWidth, labelWidth + 2 * startHorizontalPadding)
    }

    static func controlRowMinimumWidth(startWidth: CGFloat) -> CGFloat {
        stepperWidth + controlGap + startWidth
    }

    // MARK: Quiet line

    static let chipIconWidth: CGFloat = 14
    static let quietLineGap: CGFloat = 8

    // MARK: Whole-tab blocks

    /// The alert that replaces the body when the library cannot be used:
    /// title, up to three lines of explanation, one row of buttons.
    static let alertTextWidth: CGFloat = 360
    static let alertDetailHeight: CGFloat = 46
    static let alertBlockHeight: CGFloat = 16 + 4 + alertDetailHeight + 8 + 24
    /// One sentence and one control, for a library with no scripts.
    static let emptyStateHeight: CGFloat = 28 + 8 + 24
}
