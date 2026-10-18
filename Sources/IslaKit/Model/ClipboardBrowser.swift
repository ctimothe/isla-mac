import Combine
import Foundation

/// What Clipboard is showing of the history: which kind, what the search field
/// says, and which row the arrow keys are on (spec §9.3, §19.8). The history is
/// `ClipboardStore`'s; this is only the lens.
///
/// A model of its own, owned by `NotchViewModel`, rather than `@State` in the
/// surface, because what was typed has to be cleared from places the surface
/// cannot see: the surface changing, the panel folding and Escape all do it,
/// and none of them goes through the surface's views.
///
/// Memory only, like the history it filters: neither the kind nor a query
/// outlives the session, and a query does not outlive the panel's closing.
@MainActor
final class ClipboardBrowser: ObservableObject {
    /// The segmented control's choice. Kept while the panel is closed and the
    /// surface is changed away from: the segment a person chose is not
    /// something the panel forgets because they looked at the player.
    @Published var filter: ClipFilter = .all
    /// The search field, which is always on Clipboard (§19.8) and has the
    /// keyboard when it opens: typing searches.
    @Published var query = "" {
        // A new query is a new list; the arrow keys start again from its top.
        didSet { if query != oldValue { selection = nil } }
    }
    /// The row ↑ and ↓ moved to, or nil for the first row of the listing.
    @Published var selection: UUID?

    /// Escape's first press, the surface changing and the panel folding: what
    /// was typed goes. A half-remembered query hiding most of the list the
    /// next time Clipboard opens would read as a broken history.
    func clearQuery() {
        if !query.isEmpty { query = "" }
        if selection != nil { selection = nil }
    }

    /// The four kinds the surface's filter offers (§19.8): files show under
    /// All, which is where a copied file has always been looked for.
    nonisolated static let filters: [ClipFilter] = [.all, .text, .links, .images]

    /// The entries the surface draws, as a value so each rule is a test.
    ///
    /// - The filter picks the kinds, and a search narrows within them: the two
    ///   controls sit side by side (§19.8), so a search finds what is plainly
    ///   in the list they describe together.
    /// - Pinned entries are listed first either way.
    struct Listing: Equatable {
        let items: [ClipItem]
        /// The index in `items` after which the hairline is drawn: the last
        /// pinned entry, when unpinned ones follow it. Nil when there is
        /// nothing to separate.
        let separatorAfter: Int?
        let isSearch: Bool
    }

    /// - A row the privacy cover is hiding is searched by its kind's name and
    ///   never by its content (review 2026-10-15): the dots over a row are a
    ///   promise about what a screen-share can see, and a search that kept the
    ///   rows containing "password" while dropping the others told the audience
    ///   exactly which dots were hiding one.
    static func listing(
        of items: [ClipItem], filter: ClipFilter, query: String,
        isHidden: (ClipItem) -> Bool = { _ in false }
    ) -> Listing {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchActive = !needle.isEmpty
        let shown = ClipboardStore.listed(items).filter {
            filter.includes($0.kind)
                && (!searchActive || ClipboardSearch.matches($0, query: needle, hidden: isHidden($0)))
        }
        let pinned = shown.prefix(while: \.isPinned).count
        return Listing(
            items: shown,
            separatorAfter: pinned > 0 && pinned < shown.count ? pinned - 1 : nil,
            isSearch: searchActive
        )
    }

    /// The row the arrow keys are on, in `listing`: the chosen one while it is
    /// still listed, else the first. Nil for an empty listing.
    static func selectedIndex(in listing: Listing, selection: UUID?) -> Int? {
        guard !listing.items.isEmpty else { return nil }
        if let selection, let index = listing.items.firstIndex(where: { $0.id == selection }) { return index }
        return 0
    }

    /// ↑ (−1) or ↓ (+1): the next row, stopping at either end rather than
    /// wrapping — a list that jumps from its last row to its first under a
    /// held key has lost the person's place.
    static func moved(_ step: Int, in listing: Listing, selection: UUID?) -> UUID? {
        guard let index = selectedIndex(in: listing, selection: selection) else { return nil }
        let next = min(max(index + step, 0), listing.items.count - 1)
        return listing.items[next].id
    }
}
