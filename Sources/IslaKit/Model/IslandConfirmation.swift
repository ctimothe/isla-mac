import AppKit
import CoreGraphics

/// A short answer on the island to something the person just did (refinement
/// pass 2026-10-25, MR-7): a symbol and a few words, white on the island's
/// black, for 1.5 s — "Lyrics imported", "Copied", "Added to Shelf".
///
/// Each of the three acts used to end with nothing on screen. An LRC import
/// happens behind a file picker that has just closed; Return in the Clipboard
/// browser copies and shuts the panel in one press; a file let go over a shut
/// island goes into a Shelf nobody is looking at. The island is where the eye
/// already is.
///
/// It is an alert like the others (`IslandActivity.confirmation`), not an
/// overlay of its own: it takes its turn by rank, waits its second for an
/// open panel or a drag like the charger does, and is dropped after it. That
/// is what keeps it to one surface per event — an act made inside the open
/// panel is answered there (the Clipboard row's own tick, the stage showing
/// the lyrics it imported, the tray showing the file), and by the time the
/// panel closes the second is usually gone.
///
/// It never speaks. Whoever made the act says it once, at the act, drawn or
/// not: Return and the Copy buttons already said "Copied", and the import and
/// the drop say theirs where they happen (`NotchViewModel.confirm`). A
/// sentence spoken again when the pill appears would be the same news twice.
struct IslandConfirmation: Equatable {
    enum Kind: Equatable {
        case lyricsImported
        case copied
        case addedToShelf
    }

    var kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    var symbol: String {
        switch kind {
        case .lyricsImported: return "checkmark.circle.fill"
        case .copied: return "doc.on.doc.fill"
        case .addedToShelf: return "tray.and.arrow.down.fill"
        }
    }

    var title: String {
        switch kind {
        case .lyricsImported: return localized("Lyrics imported")
        case .copied: return localized("Copied")
        case .addedToShelf: return localized("Added to Shelf")
        }
    }

    /// What the island's value says while it shows. The words on it, and the
    /// words the act announced.
    var accessibilityLabel: String { title }

    /// How long it holds the island once it shows. Long enough to read three
    /// words, short enough that a second copy finds the first already gone —
    /// the volume pop-up's linger (`Theme.hudLinger`), and the beat Apple's
    /// own small confirmations keep.
    static let holdDuration: TimeInterval = 1.5

    /// Whether the act announces it. Copying already says "Copied" wherever it
    /// happens — `CopyButton`, the Clipboard row, Return — so only the other
    /// two speak through `NotchViewModel.confirm`.
    var announcesAtTheAct: Bool { kind != .copied }
}

/// Where the confirmation's two parts sit in the shut island. Body-local, like
/// `CompactIslandLayout`: the symbol in the left wing at the charger word's
/// inset, the title in the right wing ending where the charger's battery does,
/// so nothing is drawn under the notch on a Mac that has one.
enum ConfirmationLayout {
    static let symbolSize: CGFloat = 14
    static let titleSize: CGFloat = CompactIslandLayout.chargingTextSize
    static let titleOpacity: Double = CompactIslandLayout.chargingTextOpacity
    static var leadingInset: CGFloat { CompactIslandLayout.chargingTextInset }
    static var trailingInset: CGFloat { CompactIslandLayout.batteryTrailing - CompactIslandLayout.shoulder }

    /// The least a wing is, so a short word ("Copied", «Скопировано») draws the
    /// same pill as the charger's: the notch plus 180.
    static let minimumExtension: CGFloat = NotchMetrics.compactChargingExtension

    /// The title's width at its size, rounded up.
    static func titleWidth(_ title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: titleSize, weight: .medium)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The pill: the notch's height, and wide enough for the title in the
    /// right wing with both insets — never narrower than the charger's, never
    /// wider than the panel. Both wings grow alike, so the notch stays centred.
    static func bodySize(title: String, notchSize: CGSize, bodyWidth: CGFloat) -> CGSize {
        let wing = titleWidth(title) + trailingInset + CompactIslandLayout.cutoutClearance
        let width = max(notchSize.width + minimumExtension, notchSize.width + 2 * wing)
        return CGSize(width: min(width, bodyWidth), height: notchSize.height)
    }
}
