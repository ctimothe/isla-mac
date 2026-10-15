import Combine
import Foundation

/// What the Clipboard tab is showing of the history: which kind, and what the
/// search field says (spec §9.3). The history is `ClipboardStore`'s; this is
/// only the lens.
///
/// A model of its own, owned by `NotchViewModel`, rather than `@State` in the
/// pane, for the reason Translate's keyboard claim lives on the view model: the
/// field opening is a request for the keyboard, and the panel — which is key
/// only while somebody asks — has to hear it close from places the pane cannot
/// see. A tab change, the panel folding and Escape all end a search, and none
/// of them goes through the pane's views.
///
/// Memory only, like the history it filters: neither the kind nor a query
/// outlives the session, and a query does not outlive the panel's closing.
@MainActor
final class ClipboardBrowser: ObservableObject {
    /// The segmented control's choice. Kept while the panel is closed and the
    /// tab is changed away from: the segment a person chose is not something
    /// the panel forgets because they looked at Music.
    @Published var filter: ClipFilter = .all
    /// Whether the search field has replaced the filter in the header.
    @Published private(set) var isSearching = false
    @Published var query = ""

    func beginSearch() { isSearching = true }

    /// Closes the field and forgets what was typed: Escape and the ⓧ mean
    /// "stop searching", and a half-remembered query hiding most of the list
    /// the next time the tab opens would read as a broken history.
    func endSearch() {
        isSearching = false
        query = ""
    }

    /// The entries the pane draws, as a value so each rule is a test.
    ///
    /// - A search looks at everything: the filter is not on screen while the
    ///   field is open (it is *replaced*, spec §9.3), and results narrowed by a
    ///   control nobody can see would be a search that does not find what is
    ///   plainly in the list.
    /// - Otherwise the filter picks the kinds.
    /// - Pinned entries are listed first either way.
    struct Listing: Equatable {
        let items: [ClipItem]
        /// The index in `items` after which the hairline is drawn: the last
        /// pinned entry, when unpinned ones follow it. Nil when there is
        /// nothing to separate.
        let separatorAfter: Int?
        let isSearch: Bool
    }

    static func listing(
        of items: [ClipItem], filter: ClipFilter, query: String, searching: Bool
    ) -> Listing {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchActive = searching && !needle.isEmpty
        let ordered = ClipboardStore.listed(items)
        let shown: [ClipItem]
        if searchActive {
            shown = ordered.filter { ClipboardSearch.matches($0, query: needle) }
        } else if searching {
            // Open with nothing typed: the whole list, whatever the filter was.
            shown = ordered
        } else {
            shown = ordered.filter { filter.includes($0.kind) }
        }
        let pinned = shown.prefix(while: \.isPinned).count
        return Listing(
            items: shown,
            separatorAfter: pinned > 0 && pinned < shown.count ? pinned - 1 : nil,
            isSearch: searchActive
        )
    }
}
