import AppKit
import Combine
import UniformTypeIdentifiers

/// The Shelf: its selection, redraws, drops and the collected moment. Stored properties live in NotchViewModel.swift.
extension NotchViewModel {
    func shelfSelectionChanged(to selection: Set<UUID>) {
        // Stamped from the value the publisher hands over (it announces before
        // it stores), and only while the panel is open: a selection made while
        // shut is not "this opening's".
        shelfSelectionOpening = selection.isEmpty || !isOpen ? nil : openingGeneration
        let current = shelfSelectionOpening == openingGeneration
        if shelfSelectionIsCurrent != current { shelfSelectionIsCurrent = current }
    }

    /// Everything about the Shelf that changes the collapsed island's outline:
    /// whether it is live, and how many digits its count has — the bubble
    /// widens with them (spec §19.7, amended 2026-10-17). The controller
    /// re-cuts the clickable regions when this changes and only then, so a
    /// ninth screenshot cuts nothing and a tenth does. Built from the values
    /// the publishers hand over, never read back from the model, which still
    /// holds the old ones inside a sink.
    /// What about the Shelf the shut island draws, for the redraw that has
    /// to reach it while the panel is shut.
    struct ShelfRedraw: Equatable {
        let count: Int
        let holdsPlaced: Bool
    }

    struct ShelfCut: Equatable {
        let isLive: Bool
        let digits: Int
    }

    static func shelfCut(items: [ShelfItem], showingCollected: Bool) -> ShelfCut {
        let isLive = !items.isEmpty && (showingCollected || items.contains { $0.origin == .placed })
        return ShelfCut(isLive: isLive, digits: IslandBubbleLayout.digits(items.count))
    }

    /// The tray header's Remove All (spec §19.7): asks the question the tray
    /// draws in place of its row. Escape (`ArmedConfirmations`) and leaving
    /// the tray (`surface`) take it back.
    ///
    /// The selection goes first. The question is drawn in place of the grid,
    /// so a tile selected before it can no longer be seen, yet it still held
    /// the Delete key: ⌫ over the question removed that one hidden card and
    /// left the question standing with its count changed under it.
    func askToRemoveAll() {
        shelf.clearSelection()
        shelfClear.ask(count: shelf.items.count)
    }

    /// A screenshot that arrived on its own — copied elsewhere, or synced
    /// from a phone by Continuity — rather than one the user handed to the
    /// panel directly. It is already on the shelf by the time this is called;
    /// this only decides whether to show it.
    ///
    /// It never moves an open panel (owner decision 14, FOC-01): a surface
    /// that changes under somebody reading the clipboard, or whose VoiceOver
    /// cursor is in it, is the app moving the user for something the user did
    /// not ask for. Nor does it refresh the tray while shut: that pass — a
    /// `checkResourceIsReachable` per card plus thumbnail requests — is exactly
    /// how a background copy from a phone used to raise a Desktop-or-Documents
    /// permission prompt with no visible cause.
    ///
    /// The island shows it for a moment (`isShowingCollected`), unless a
    /// surface is open or the shield is up: the island is not on screen then,
    /// and a moment kept for later would be news from the past.
    func receivedScreenshot(at url: URL) {
        if !isOpen, !isLockedPresentation { showCollectedMoment() }
    }

    /// Shows the Shelf, or restarts its moment if one is showing: a burst of
    /// screenshots holds it until the last one's moment is over.
    private func showCollectedMoment() {
        collectedMomentEnd?.cancel()
        isShowingCollected = true
        let lifetime = collectedMomentLifetime
        collectedMomentEnd = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.isShowingCollected = false
        }
    }

    /// Ends a collected file's moment at once — the panel opening, as it ends
    /// a peek and an alert, so closing never uncovers one gone stale.
    func endCollectedMoment() {
        collectedMomentEnd?.cancel()
        collectedMomentEnd = nil
        if isShowingCollected { isShowingCollected = false }
    }

    /// A file the user dropped on the island by hand. The drop surface folds
    /// with the drag, and the Shelf is live (spec §19.7): compact on the
    /// island, or the bubble beside a song. The surface underneath is not
    /// moved — a drop over an open Clipboard is a file kept, not a request to
    /// look at the Shelf.
    func accept(urls: [URL]) -> Bool {
        shelf.add(urls)
        return true
    }

    /// Files let go over the panel, straight from a drag. A card dragged out
    /// of the Shelf and let go there is refused: it is the Shelf's own card
    /// coming back, not a person keeping a file, and refused it slides back
    /// where it came from. Taken as a drop it made a collected screenshot a
    /// person's, so one cancelled drag kept the island out of the notch for
    /// good (R7 review). Promised files land through `accept` directly: they
    /// are never a Shelf card, and refusing them mid-drag would lose them.
    func acceptDrop(urls: [URL]) -> Bool {
        if ShelfDragSource.isDraggingOut { return false }
        let result = shelf.add(urls)
        // The panel is open or a drag is under way, so the confirmation waits
        // in the alert queue for the panel to close and shows on the island
        // then, up to five seconds later. Over a panel that was already open
        // the drop returns to the player or Clipboard, not the tray
        // (`endDropSurface`), so nothing else answers the drop.
        //
        // It says what happened. A file dropped a second time added nothing,
        // and the island said "Added to Shelf" all the same; the tray's own
        // "Already on the Shelf" line was drawn in a tray already folded.
        if result.added > 0 {
            confirm(.addedToShelf)
        } else if result.duplicates > 0 {
            confirm(.alreadyOnShelf)
        }
        return true
    }
}
