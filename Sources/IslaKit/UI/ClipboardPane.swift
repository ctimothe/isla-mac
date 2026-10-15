import AppKit
import SwiftUI

/// The Clipboard tab (redesign spec §9): a list of 28 pt rows that each read as
/// what they are — text, a colour, code, a link, a picture, files — pinned
/// entries first above a hairline, a grid of thumbnails for the Images filter,
/// a search that replaces the filter in the header, and the same Expand as the
/// other tabs that can grow.
///
/// Every frame comes from `ClipboardLayout`, in the board's body coordinates,
/// and is converted once by `PlayerLayout.inPane`, so what a test holds is what
/// is drawn. The store under it (the poll, the pasteboard-privacy rules, the
/// 40-entry cap) is `ClipboardStore`; what is on show of it is
/// `ClipboardBrowser`.
struct ClipboardPane: View {
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var privacy: PrivacyMode
    /// The filter and the search field, owned by the view model so the panel can
    /// end a search from outside the pane. A pane built without one (a test, the
    /// lab) gets a private browser showing everything.
    @ObservedObject var browser: ClipboardBrowser
    /// Read through `@AppStorage` rather than once from
    /// `NotchViewModel.clipboardHistoryEnabled`, so Turn On below redraws the
    /// pane the moment it writes the switch. The store is a parameter only so
    /// a test can hand it a private suite instead of the owner's defaults.
    @AppStorage private var historyEnabled: Bool
    /// The Settings switch, flipped on from here. Local only: history never
    /// leaves the Mac, so turning it on beside the sentence that says it is
    /// off asks nothing of anyone.
    private let turnOnHistory: () -> Void
    /// Translate, from a row's menu: hands the entry's text to the Translate tab
    /// the way ⌃⌥⌘T does (`NotchViewModel.translateClipboardText`).
    private let translate: (String) -> Void
    /// The header's height on this Mac, for the body-to-pane conversion.
    private let headerHeight: CGFloat
    /// The keyboard claim the search field follows (`NotchViewModel.wantsKeyboard`),
    /// and the way it ends a search. The field lives on this pane's filter row,
    /// not in the header strip (review 2026-10-15: the notch covered it there).
    @Binding private var wantsKeyboard: Bool
    private let closeSearch: () -> Void

    @StateObject private var clear: ClipboardClearConfirmation

    init(
        clipboard: ClipboardStore,
        privacy: PrivacyMode,
        browser: ClipboardBrowser? = nil,
        historyDefaults: UserDefaults = .standard,
        headerHeight: CGFloat = PlayerLayout.referenceHeaderHeight,
        wantsKeyboard: Binding<Bool> = .constant(false),
        closeSearch: @escaping () -> Void = {},
        translate: @escaping (String) -> Void = { _ in },
        clearConfirmation: ClipboardClearConfirmation? = nil,
        turnOnHistory: @escaping () -> Void = {}
    ) {
        _clear = StateObject(wrappedValue: clearConfirmation ?? ClipboardClearConfirmation())
        self.clipboard = clipboard
        self.privacy = privacy
        _browser = ObservedObject(wrappedValue: browser ?? ClipboardBrowser())
        _historyEnabled = AppStorage(wrappedValue: true, NotchViewModel.clipboardHistoryKey, store: historyDefaults)
        self.headerHeight = headerHeight
        _wantsKeyboard = wantsKeyboard
        self.closeSearch = closeSearch
        self.translate = translate
        self.turnOnHistory = turnOnHistory
    }

    /// Privacy & Security > Paste from Other Apps, then the Privacy &
    /// Security root. The anchor is not one Apple documents, so the root is
    /// the fallback when it does not open: one more click from there beats a
    /// button that does nothing.
    static let privacySettingsURLs: [URL] = [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard",
        "x-apple.systempreferences:com.apple.preference.security",
    ].compactMap(URL.init(string:))

    /// Opens the first of `privacySettingsURLs` that System Settings accepts.
    static func openPrivacySettings() {
        for url in privacySettingsURLs where NSWorkspace.shared.open(url) { return }
    }

    /// A frame in the board's body coordinates, in this pane's.
    private func pane(_ rect: CGRect) -> CGRect {
        PlayerLayout.inPane(rect, headerHeight: headerHeight)
    }

    var body: some View {
        GeometryReader { geo in
            let size = ClipboardLayout.bodySize(paneSize: geo.size, headerHeight: headerHeight)
            content(size)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        // Don't Allow stops the poll, and a stopped poll cannot notice the
        // switch going back to Allow. Looking at this tab is the moment a
        // user back from System Settings expects history to resume, so the
        // system is asked again here rather than on a timer.
        .onAppear { clipboard.recheckAccess() }
        // A question left standing would be waiting inside the next visit to
        // the tab, one click from emptying it.
        .onDisappear { clear.cancel() }
        .onChange(of: clipboard.items.isEmpty) { _, empty in if empty { clear.cancel() } }
    }

    // MARK: - The tab, by state

    private var showsAlert: Bool {
        // Only while something wants the pasteboard: with history and
        // clipboard screenshots both off nothing is lost to the refusal,
        // and a failure nobody is affected by is not worth the space.
        clipboard.access == .denied && NotchStores.clipboardShouldPoll(
            history: historyEnabled,
            images: NotchViewModel.saveClipboardImagesEnabled
        )
    }

    @ViewBuilder
    private func content(_ size: CGSize) -> some View {
        let alert = showsAlert
        let confirming = clear.isAsking && !clipboard.items.isEmpty
        let hasFilterRow = ClipboardHeader.showsFilterRow(itemCount: clipboard.items.count, isSearching: browser.isSearching)
        let viewport = pane(ClipboardLayout.viewport(
            bodySize: size, showsAlert: alert, confirming: confirming, hasFilterRow: hasFilterRow, headerHeight: headerHeight
        ))
        let listing = ClipboardBrowser.listing(
            of: clipboard.items, filter: browser.filter, query: browser.query, searching: browser.isSearching,
            isHidden: { privacy.hides(.clipboard, $0.id.uuidString) }
        )
        ZStack(alignment: .topLeading) {
            if alert { deniedAlert(size, hasFilterRow: hasFilterRow) }
            if hasFilterRow { filterRow(size) }
            if clipboard.items.isEmpty {
                emptyState(in: pane(ClipboardLayout.viewport(bodySize: size, showsAlert: alert, hasFilterRow: hasFilterRow, headerHeight: headerHeight)))
            } else if listing.items.isEmpty {
                if listing.isSearch {
                    noResults(in: viewport)
                } else if let title = browser.filter.emptyTitle, !browser.isSearching {
                    // Entries exist, but none of the chosen kind.
                    kindEmpty(title: title, symbol: browser.filter.symbol, in: viewport)
                } else {
                    emptyState(in: viewport)
                }
            } else if browser.filter == .images, !browser.isSearching {
                imageGrid(listing.items, size: size, viewport: viewport)
            } else {
                list(listing, size: size, viewport: viewport)
            }
            if confirming { confirmBar(size) }
        }
        .animation(Theme.contentAnimation, value: confirming)
    }

    // MARK: - The filter row (§9.3)

    /// The Kind filter, or while Search is open the field that replaces it, on
    /// the row under the header: (58, 44), `bw − 72` × 22. Drawn by the pane
    /// rather than the header strip because it is below the strip, and a
    /// control placed outside its parent's bounds is a hit-testing gamble.
    @ViewBuilder
    private func filterRow(_ size: CGSize) -> some View {
        if browser.isSearching {
            let frame = pane(ClipboardHeader.searchField(bodyWidth: size.width, headerHeight: headerHeight))
            ClipboardSearchField(browser: browser, wantsKeyboard: $wantsKeyboard, close: closeSearch)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .transition(.opacity)
        } else {
            let frame = pane(ClipboardHeader.filter(bodyWidth: size.width, headerHeight: headerHeight))
            ClipboardKindControl(selection: $browser.filter, bodyWidth: size.width)
                .offset(x: frame.minX, y: frame.minY)
                .transition(.opacity)
        }
    }

    // MARK: - The list (§9.2)

    private func list(_ listing: ClipboardBrowser.Listing, size: CGSize, viewport: CGRect) -> some View {
        let narrow = ClipboardHeader.usesSymbols(bodyWidth: size.width)
        return ScrollView(showsIndicators: false) {
            // One clock for every covered row in the list — see
            // `SpoilerClock` — and only while one is covered.
            SpoilerClock(active: spoilerClockActive) {
                // Re-read twice a minute, so "Now" does not linger into the
                // afternoon on a list left open: one timeline for every age
                // rather than one per row.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LazyVStack(spacing: ClipboardLayout.rowGap) {
                        ForEach(Array(listing.items.enumerated()), id: \.element.id) { index, item in
                            ClipRow(
                                item: item, clipboard: clipboard, privacy: privacy,
                                query: listing.isSearch ? browser.query : "",
                                now: context.date, narrowAges: narrow,
                                translate: translate, askClear: askClear
                            )
                            if listing.separatorAfter == index { separator }
                        }
                    }
                }
            }
        }
        // Rows beyond the window fade out under 26 pt of mask instead of
        // being cut square against the body's foot (H-017, spec §9.2), and only
        // while something is beyond the edge.
        .scrollEdgeFade(.vertical, length: ClipboardLayout.overflowFade)
        .frame(width: viewport.width, height: viewport.height)
        .offset(x: viewport.minX, y: viewport.minY)
    }

    /// The hairline under the pinned rows: 7 pt of list with the line 3 down,
    /// inset 8 each side.
    private var separator: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.horizontal, ClipboardLayout.separatorInset)
            .frame(height: ClipboardLayout.separatorHeight, alignment: .center)
            .accessibilityHidden(true)
    }

    /// Whether the list's spoiler clock has anything to animate. The tab
    /// used to run it unconditionally, and covers are off by default, so an
    /// unchanging list redrew twenty times a second (F-016). Needs the
    /// section covered and a row still hidden: revealing the last row stops
    /// the clock, covering the section again starts it.
    static func spoilerClockActive(covers: Bool, hiddenCount: Int) -> Bool {
        covers && hiddenCount > 0
    }

    private var spoilerClockActive: Bool {
        let covers = privacy.covers(.clipboard)
        // Only walked when the section covers: `hides` is false for every
        // row otherwise.
        let hidden = covers
            ? clipboard.items.filter { privacy.hides(.clipboard, $0.id.uuidString) }.count
            : 0
        return Self.spoilerClockActive(covers: covers, hiddenCount: hidden)
    }

    private func askClear() {
        clear.ask(count: clipboard.items.filter { !$0.isPinned }.count)
    }

    // MARK: - Images (§9.2)

    /// A picture is read by eye, so the Images filter is a grid: 88 × 66
    /// thumbnails, 12 apart, the age centred under each, and the one line that
    /// says where they live.
    private func imageGrid(_ items: [ClipItem], size: CGSize, viewport: CGRect) -> some View {
        let columns = ClipboardLayout.imageColumns(bodyWidth: size.width)
        let narrow = ClipboardHeader.usesSymbols(bodyWidth: size.width)
        return ScrollView(showsIndicators: false) {
            SpoilerClock(active: spoilerClockActive) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.fixed(ClipboardLayout.imageTile.width), spacing: ClipboardLayout.imageGap),
                                count: columns
                            ),
                            alignment: .leading, spacing: ClipboardLayout.imageRowGap
                        ) {
                            ForEach(items) { item in
                                ClipImageTile(
                                    item: item, clipboard: clipboard, privacy: privacy,
                                    now: context.date, narrowAges: narrow,
                                    translate: translate, askClear: askClear
                                )
                            }
                        }
                        Text(localized("Images are kept in memory, like the rest of the history."))
                            .islandFont(.body, weight: .regular)
                            .foregroundStyle(Theme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                    }
                    .frame(width: viewport.width, alignment: .leading)
                }
            }
        }
        .scrollEdgeFade(.vertical, length: ClipboardLayout.overflowFade)
        .frame(width: viewport.width, height: viewport.height)
        .offset(x: viewport.minX, y: viewport.minY)
    }

    // MARK: - Empty, history off, no results (§9.3, §9.4)

    /// The glyph alone used to be the whole empty tab, and VoiceOver read it
    /// by its symbol's name, "Paste" (F-036, M-08). The words say what lands
    /// here and what never does — concealed copies, which is what password
    /// managers mark theirs as, are skipped before they are read — and the
    /// glyph is drawing. Laid out like the empty Shelf, so the two tabs read
    /// as one panel.
    private func emptyState(in frame: CGRect) -> some View {
        VStack(spacing: 6) {
            Image(systemName: NotchViewModel.Tab.clipboard.symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
                .padding(.bottom, 4)
            if historyEnabled {
                Text(localized("Nothing copied yet"))
                    .islandFont(.subhead, weight: .semibold)
                    .foregroundStyle(.white)
                Text(localized("Text, links, images and files you copy appear here. Copies from password managers are skipped."))
                    .islandFont(.body, weight: .regular)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // An empty list with history off is not "nothing copied yet",
                // and saying which one it is saves a hunt. The way back on
                // sits under the sentence: sending someone to Settings for a
                // switch they could be handed here was a second hunt.
                Text(localized("Clipboard History"))
                    .islandFont(.subhead, weight: .semibold)
                    .foregroundStyle(.white)
                Text(localized("Clipboard history is off in Settings."))
                    .islandFont(.body, weight: .regular)
                    .foregroundStyle(Theme.secondary)
                Button(localized("Turn On"), action: turnOnHistory)
                    .buttonStyle(ToolbarPushButtonStyle())
                    .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
    }

    /// A filter with nothing of its kind (`ClipFilter.emptyTitle`): the kind's own
    /// symbol, "No Links", and a line saying copies of that kind will land here.
    private func kindEmpty(title: String, symbol: String, in frame: CGRect) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
                .padding(.bottom, 4)
            Text(title)
                .islandFont(.subhead, weight: .semibold)
                .foregroundStyle(.white)
            Text(localized("Copies of this kind appear here."))
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
    }

    /// `magnifyingglass` 26 pt, the query in the title, and the way out. The
    /// words are the system's own for a search that found nothing.
    private func noResults(in frame: CGRect) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
                .padding(.bottom, 4)
            Text(localized("No Results for “%@”", browser.query.trimmingCharacters(in: .whitespacesAndNewlines)))
                .islandFont(.subhead, weight: .semibold)
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(localized("Check the spelling or try a new search."))
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY)
    }

    // MARK: - Denied (§9.4)

    /// Paste from Other Apps set to Don't Allow (J-001), as an inline alert:
    /// 488 × 44, radius 9, the warning orange at 0.12 with a 0.35 ring, the raised
    /// hand, the sentence and the way to fix it. Inline above the list, because
    /// the failure belongs to this section and to nothing else; Settings
    /// carries no second banner for the same event. What was kept before the
    /// refusal stays below it, still usable.
    private func deniedAlert(_ size: CGSize, hasFilterRow: Bool) -> some View {
        let origin = hasFilterRow
            ? ClipboardLayout.listOrigin(headerHeight: headerHeight)
            : ClipboardLayout.listOriginWithoutFilterRow(headerHeight: headerHeight)
        let frame = pane(CGRect(
            x: origin.x, y: origin.y,
            width: ClipboardLayout.rowWidth(bodyWidth: size.width), height: ClipboardLayout.alertHeight
        ))
        return HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.warning)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(localized("macOS is not letting Isla read what you copy, so nothing new is kept."))
                .islandFont(.body, weight: .regular)
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(localized("Open Privacy Settings")) { Self.openPrivacySettings() }
                .buttonStyle(ToolbarPushButtonStyle())
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(width: frame.width, height: frame.height)
        .background(
            RoundedRectangle(cornerRadius: ClipboardLayout.alertRadius, style: .continuous)
                .fill(Theme.warning.opacity(ClipboardLayout.alertFillOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClipboardLayout.alertRadius, style: .continuous)
                .strokeBorder(Theme.warning.opacity(ClipboardLayout.alertRingOpacity), lineWidth: 0.5)
        )
        .offset(x: frame.minX, y: frame.minY)
    }

    // MARK: - Clear History, asked once (§9.4)

    /// "Clear %d entries? Pinned items stay." with Cancel and Clear History, in
    /// place at the list's foot. Escape answers it first
    /// (`ArmedConfirmations`), and it does not lapse by itself.
    private func confirmBar(_ size: CGSize) -> some View {
        let frame = pane(ClipboardLayout.confirmBar(bodySize: size))
        return HStack(spacing: 6) {
            Text(localized("Clear %d entries? Pinned items stay.", clear.count))
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(localized("Cancel")) { clear.cancel() }
                .buttonStyle(ToolbarPushButtonStyle())
            Button(localized("Clear History")) { clear.confirm { clipboard.clear() } }
                .buttonStyle(ToolbarPushButtonStyle(kind: .danger))
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, ClipboardLayout.separatorInset)
        .frame(width: frame.width, height: frame.height)
        .background(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
                .padding(.horizontal, ClipboardLayout.separatorInset)
        }
        .background(Color.black)
        .offset(x: frame.minX, y: frame.minY)
        .transition(.opacity)
    }
}

// MARK: - A row (§9.1, §9.2)

struct ClipRow: View {
    let item: ClipItem
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var privacy: PrivacyMode
    /// The search field's text while it filters: matches are drawn in the
    /// find-in-page yellow (spec §9.3). Empty draws none.
    var query = ""
    var now = Date()
    /// Below 540 (spec §9.3) the age's weekday and date shorten.
    var narrowAges = false
    var translate: (String) -> Void = { _ in }
    var askClear: () -> Void = {}

    @State private var hovering = false
    @State private var justCopied = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hidden: Bool { privacy.hides(.clipboard, item.id.uuidString) }

    /// The row's leading mark, from `ClipMark`.
    static func mark(for item: ClipItem, hidden: Bool) -> ClipMark {
        ClipMark.mark(for: item.kind, hidden: hidden)
    }

    /// The glyph a symbol mark names, or nil for the marks that are drawings
    /// (a swatch, a thumbnail, a file's icon). A covered row keeps its kind's
    /// glyph readable (spec §9.4), which supersedes H-026's one neutral glyph:
    /// what the cover hides is the content, and the count in the header.
    static func glyph(for item: ClipItem, hidden: Bool) -> String? {
        if case .symbol(let name) = mark(for: item, hidden: hidden) { return name }
        return nil
    }

    var body: some View {
        HStack(spacing: ClipboardLayout.contentLeading - ClipboardLayout.rowInset - ClipboardLayout.markSide) {
            leadingMark
                .frame(width: ClipboardLayout.markSide, height: ClipboardLayout.markSide)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, ClipboardLayout.rowInset)
        .frame(height: ClipboardLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: ClipboardLayout.rowRadius, style: .continuous)
                .fill(hovering || justCopied ? Theme.clipboardWell : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: copy)
        // Everything the hover controls do, without the hover. Remove and
        // the eye used to appear only under a pointer, so a keyboard or
        // VoiceOver user could not do either (F-005). The menu is AppKit's,
        // and `MenuTracking` holds the panel open while it is up.
        .contextMenu {
            ClipEntryMenu(
                item: item, clipboard: clipboard, privacy: privacy,
                copy: copy, copyPlain: copyPlain, translate: translate, askClear: askClear
            )
        }
        // One element per row, named by what it would copy. It used to be
        // `.combine` under a fixed label, so every row in the list was the
        // same "Copy Entry" button and twenty of them could not be told
        // apart (F-005). `.ignore` swallows the glyph, the text and the hover
        // controls; what the controls do is offered as actions below. A
        // covered row says only "Hidden" — the cover's own label, which
        // `.ignore` would otherwise drop — because a screen reader must not
        // be the hole in a feature about not showing things.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        // VO-Space copies, as a click does.
        .accessibilityAction { copy() }
        // The menu's verbs, in the Actions rotor. Written bottom-up: SwiftUI
        // vends named actions outermost first, so the rotor reads Show or
        // Hide, Pin or Unpin, Translate, and the Remove last, as the menu does.
        .accessibilityAction(named: Text(localized("Remove Entry"))) { clipboard.remove(item) }
        .accessibilityActions {
            if item.kind.isText {
                Button(localized("Translate")) { translate(item.text ?? "") }
            }
        }
        .accessibilityActions {
            Button(item.isPinned ? localized("Unpin") : localized("Pin")) { clipboard.togglePin(item) }
        }
        .accessibilityActions {
            if privacy.covers(.clipboard) {
                Button(hidden ? localized("Show") : localized("Hide"), action: toggleCover)
            }
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: justCopied)
    }

    // MARK: The mark

    @ViewBuilder
    private var leadingMark: some View {
        switch Self.mark(for: item, hidden: hidden) {
        case .symbol(let name):
            Image(systemName: name)
                .islandFont(.reading, weight: .regular)
                .foregroundStyle(Theme.secondary)
                // The copied tick takes the mark's place only in the trailing
                // slot (below): the mark is what says what the row is.
                .accessibilityHidden(true)
        case .swatch:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(ClipSwatch.color(for: item.text ?? "") ?? Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
                .frame(width: 14, height: 14)
        case .neutralSwatch:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.18))
                .frame(width: 14, height: 14)
        case .thumbnail:
            if case .image(let image) = item.payload {
                Image(decorative: image.thumbnail, scale: 2)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            }
        case .fileIcon:
            if let url = ClipFileIcons.first(of: item) {
                Image(nsImage: ClipFileIcons.icon(for: url)).resizable().frame(width: 20, height: 20)
            }
        case .fileStack:
            if case .files(let urls) = item.payload {
                ZStack {
                    ForEach(Array(urls.prefix(3).enumerated().reversed()), id: \.offset) { index, url in
                        Image(nsImage: ClipFileIcons.icon(for: url))
                            .resizable()
                            .frame(width: 18, height: 18)
                            .opacity(1 - Double(index) * 0.22)
                            .offset(x: CGFloat(2 - min(index, 2)) * 1.5, y: 0)
                    }
                }
            }
        }
    }

    // MARK: The content

    @ViewBuilder
    private var content: some View {
        if hidden {
            // The kind's own proportion of dots, so a covered list still reads
            // as a list of different things without saying which (spec §9.4).
            GeometryReader { geo in
                SpoilerField(seed: UInt64(bitPattern: Int64(item.id.uuidString.hashValue)))
                    .frame(width: geo.size.width * item.kind.coverFraction, height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .frame(maxHeight: .infinity, alignment: .center)
                    // Announced rather than described: a screen reader must not
                    // be the hole in a feature about not showing things.
                    .accessibilityLabel(Text(localized("Hidden")))
            }
            .frame(height: 12)
        } else {
            visibleContent
        }
    }

    @ViewBuilder
    private var visibleContent: some View {
        switch item.kind {
        case .text:
            Text(ClipHighlight.attributed(
                [ClipHighlight.Run(text: item.preview, color: .white, font: .reading)], query: query
            ))
            .lineLimit(1).truncationMode(.tail)
        case .colour, .code:
            Text(ClipHighlight.attributed(
                [ClipHighlight.Run(text: item.preview, color: .white, font: .monospaced)], query: query
            ))
            .lineLimit(1).truncationMode(.tail)
        case .link:
            if let link = item.link {
                // The host is what you scan for: white, weight 500; the rest in
                // secondary (spec §9.1).
                Text(ClipHighlight.attributed([
                    ClipHighlight.Run(text: link.host, color: .white, font: .readingMedium),
                    ClipHighlight.Run(text: link.rest, color: Theme.secondary, font: .reading),
                ], query: query))
                .lineLimit(1).truncationMode(.tail)
            }
        case .image:
            if case .image(let image) = item.payload {
                twoPart(localized("Image"), ClipImageText.detail(image))
            }
        case .file, .files:
            twoPart(ClipFileText.title(for: item), ClipFileText.detail(for: item))
        }
    }

    /// A white name and a tertiary description after it, on one line.
    private func twoPart(_ name: String, _ detail: String?) -> some View {
        Text(ClipHighlight.attributed(
            [ClipHighlight.Run(text: name, color: .white, font: .reading)]
                + (detail.map { [ClipHighlight.Run(text: "  " + $0, color: Theme.tertiary, font: .reading)] } ?? []),
            query: query
        ))
        .lineLimit(1).truncationMode(.tail)
    }

    // MARK: The trailing slot

    @ViewBuilder
    private var trailing: some View {
        if justCopied {
            // The tick alone was the confirmation: a 12 pt glyph turning
            // green, which sunlight, a colour-blind eye or a shared screen
            // all lose (H-016). The word holds the trailing slot for the
            // flash, in place of the hover controls, so a copy is a shape
            // and a word, never a tint alone.
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.success)
                    .symbolSwap(value: justCopied, reduceMotion: reduceMotion)
                Text(localized("Copied"))
                    .islandFont(.body, weight: .medium)
                    .foregroundStyle(.white)
            }
            .transition(.opacity)
        } else {
            HStack(spacing: ClipboardLayout.buttonGap) {
                // At rest on a covered pane, not only under the pointer: a
                // covered row that shows nothing says nothing about how to
                // read it, and the eye was the one control a hover-less
                // touch or trackpad user never found (M-04).
                if privacy.covers(.clipboard) {
                    RevealEye(hidden: hidden) { privacy.toggle(item.id.uuidString) }
                }
                if hovering {
                    hoverButton(
                        symbol: item.isPinned ? "pin.fill" : "pin", label: item.isPinned ? localized("Unpin") : localized("Pin"),
                        tint: item.isPinned ? Color.white : Theme.secondary
                    ) { clipboard.togglePin(item) }
                    hoverButton(symbol: "xmark", label: localized("Remove Entry"), tint: Theme.secondary, weight: .semibold) {
                        clipboard.remove(item)
                    }
                } else if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(Theme.tertiary)
                        .frame(minWidth: 16)
                        .accessibilityHidden(true)
                } else {
                    Text(ClipboardAge.text(of: item.date, now: now, narrow: narrowAges))
                        .islandFont(.body, weight: .regular)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func hoverButton(
        symbol: String, label: String, tint: Color, weight: Font.Weight = .regular, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "xmark" ? 9 : 11, weight: weight))
                .foregroundStyle(tint)
                // A 10pt glyph is a ~10pt target sitting beside the reveal eye,
                // inside a row whose own background copies to the pasteboard —
                // missing it by two points overwrote what the user had copied.
                .frame(width: ClipboardLayout.buttonSide, height: ClipboardLayout.buttonSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: Accessibility and actions

    /// The preview, or "Hidden" under the cover, or "Copied" for the flash.
    /// A row whose preview is empty keeps the old generic name rather than
    /// none at all: a nameless button is read as just "button".
    private var accessibilityLabel: String {
        if hidden { return localized("Hidden") }
        if justCopied { return localized("Copied") }
        if case .image(let image) = item.payload { return "\(item.preview), \(image.dimensionsText)" }
        return item.preview.isEmpty ? localized("Copy Entry") : item.preview
    }

    /// One copy for the click, VO-Space and the menu. The announcement is how
    /// the moment reaches speech (M-02): the label turning to "Copied" is
    /// heard only if VoiceOver happens to read the row again inside the
    /// flash, and it does not move on its own. `Announcer` drops the second
    /// of two identical sentences inside a second, so a click and the AX
    /// action arriving together are said once.
    private func copy() {
        clipboard.copy(item)
        confirm()
    }

    private func copyPlain() {
        guard clipboard.copyPlainText(item) else { return }
        confirm()
    }

    private func confirm() {
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + ClipboardLayout.copiedLifetime) { justCopied = false }
        Announcer.shared.announce(localized("Copied"))
    }

    private func toggleCover() {
        privacy.toggle(item.id.uuidString)
    }
}

// MARK: - A picture in the Images grid (§9.2)

struct ClipImageTile: View {
    let item: ClipItem
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var privacy: PrivacyMode
    var now = Date()
    var narrowAges = false
    var translate: (String) -> Void = { _ in }
    var askClear: () -> Void = {}

    @State private var hovering = false
    @State private var justCopied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hidden: Bool { privacy.hides(.clipboard, item.id.uuidString) }

    var body: some View {
        VStack(spacing: ClipboardLayout.imageAgeGap) {
            tile
                .frame(width: ClipboardLayout.imageTile.width, height: ClipboardLayout.imageTile.height)
                .clipShape(RoundedRectangle(cornerRadius: ClipboardLayout.imageRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ClipboardLayout.imageRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(hovering ? 0.45 : 0.2), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) { if hovering && !justCopied { hoverButtons } }
                .overlay(alignment: .topLeading) {
                    if item.isPinned && !hovering && !hidden {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(Color.white)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .padding(3)
                    }
                }
                .overlay { if justCopied { copiedOverlay } }
            Text(ClipboardAge.text(of: item.date, now: now, narrow: narrowAges))
                .islandFont(.caption, weight: .regular)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .frame(width: ClipboardLayout.imageTile.width, height: ClipboardLayout.imageAgeHeight)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: copy)
        .contextMenu {
            ClipEntryMenu(
                item: item, clipboard: clipboard, privacy: privacy,
                copy: copy, copyPlain: {}, translate: translate, askClear: askClear
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hidden ? localized("Hidden") : label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { copy() }
        .accessibilityAction(named: Text(localized("Remove Entry"))) { clipboard.remove(item) }
        .accessibilityActions {
            Button(item.isPinned ? localized("Unpin") : localized("Pin")) { clipboard.togglePin(item) }
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: justCopied)
    }

    private var label: String {
        guard case .image(let image) = item.payload else { return item.preview }
        return "\(item.preview), \(ClipImageText.detail(image))"
    }

    @ViewBuilder
    private var tile: some View {
        if hidden {
            ZStack(alignment: .bottomTrailing) {
                SpoilerField(seed: UInt64(bitPattern: Int64(item.id.uuidString.hashValue)))
                RevealEye(hidden: true) { privacy.toggle(item.id.uuidString) }
            }
        } else if case .image(let image) = item.payload {
            Image(decorative: image.thumbnail, scale: 2)
                .resizable()
                .scaledToFill()
        }
    }

    private var hoverButtons: some View {
        HStack(spacing: 2) {
            tileButton(symbol: item.isPinned ? "pin.fill" : "pin", label: item.isPinned ? localized("Unpin") : localized("Pin")) {
                clipboard.togglePin(item)
            }
            tileButton(symbol: "xmark", label: localized("Remove Entry")) { clipboard.remove(item) }
        }
        .padding(2)
    }

    private func tileButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "xmark" ? 9 : 10, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private var copiedOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.success)
                    .symbolSwap(value: justCopied, reduceMotion: reduceMotion)
                Text(localized("Copied"))
                    .islandFont(.body, weight: .medium)
                    .foregroundStyle(.white)
            }
        }
        .transition(.opacity)
    }

    private func copy() {
        clipboard.copy(item)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + ClipboardLayout.copiedLifetime) { justCopied = false }
        Announcer.shared.announce(localized("Copied"))
    }
}

// MARK: - The right-click menu (§9.2)

/// Copy ⌘C · Copy as Plain Text (text kinds) · — · Pin / Unpin · Translate
/// (text kinds) · — · Remove Entry · Clear Everything… (destructive). A covered
/// pane adds Show or Hide after Copy, as it did.
///
/// "Copy as Plain Text", not the spec's "Paste as Plain Text ⌥⇧⌘V" (review
/// 2026-10-15): Isla has no Accessibility permission and the panel is not key, so
/// the verb only ever wrote the string to the pasteboard and pressed nothing — a
/// "Paste" that did not paste, with a shortcut glyph promising a key that was
/// never bound. It is named for what it does and carries no shortcut.
struct ClipEntryMenu: View {
    let item: ClipItem
    let clipboard: ClipboardStore
    let privacy: PrivacyMode
    let copy: () -> Void
    let copyPlain: () -> Void
    let translate: (String) -> Void
    let askClear: () -> Void

    /// The menu as values, in order, so its verbs are a test and the body below
    /// cannot drift from them.
    enum Entry: Equatable {
        case copy, copyAsPlainText, showOrHide(hidden: Bool), divider
        case pin(isPinned: Bool), translate, removeEntry, clearEverything

        /// The title; nil for a divider.
        var title: String? {
            switch self {
            case .copy: return localized("Copy")
            case .copyAsPlainText: return localized("Copy as Plain Text")
            case .showOrHide(let hidden): return hidden ? localized("Show") : localized("Hide")
            case .divider: return nil
            case .pin(let isPinned): return isPinned ? localized("Unpin") : localized("Pin")
            case .translate: return localized("Translate")
            case .removeEntry: return localized("Remove Entry")
            case .clearEverything: return localized("Clear Everything…")
            }
        }
    }

    static func entries(isText: Bool, hasText: Bool, isPinned: Bool, covered: Bool, hidden: Bool) -> [Entry] {
        var entries: [Entry] = [.copy]
        if isText { entries.append(.copyAsPlainText) }
        if covered { entries.append(.showOrHide(hidden: hidden)) }
        entries.append(.divider)
        entries.append(.pin(isPinned: isPinned))
        if isText, hasText { entries.append(.translate) }
        entries.append(.divider)
        entries.append(.removeEntry)
        entries.append(.clearEverything)
        return entries
    }

    private var entries: [Entry] {
        Self.entries(
            isText: item.kind.isText, hasText: item.text != nil, isPinned: item.isPinned,
            covered: privacy.covers(.clipboard), hidden: privacy.hides(.clipboard, item.id.uuidString)
        )
    }

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .copy:
                Button(entry.title ?? "", action: copy).keyboardShortcut("c", modifiers: .command)
            case .copyAsPlainText:
                Button(entry.title ?? "", action: copyPlain)
            case .showOrHide:
                Button(entry.title ?? "") { privacy.toggle(item.id.uuidString) }
            case .divider:
                Divider()
            case .pin:
                Button(entry.title ?? "") { clipboard.togglePin(item) }
            case .translate:
                Button(entry.title ?? "") { if let text = item.text { translate(text) } }
            case .removeEntry:
                Button(entry.title ?? "") { clipboard.remove(item) }
            case .clearEverything:
                Button(entry.title ?? "", role: .destructive, action: askClear)
            }
        }
    }
}

// MARK: - Highlighted text (§9.3)

/// A line of text in runs of different colour and weight, with every match of
/// the query drawn in the find-in-page yellow on dark text.
enum ClipHighlight {
    enum FontKind { case reading, readingMedium, monospaced }

    struct Run {
        let text: String
        let color: Color
        let font: FontKind
    }

    /// The runs as one attributed string. Matches are found on the whole line,
    /// not run by run, so a query that spans the host and the path of a link
    /// still lights both halves.
    static func attributed(_ runs: [Run], query: String) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            piece.foregroundColor = run.color
            switch run.font {
            case .reading: piece.font = Theme.TypeRole.reading.font(weight: .regular)
            case .readingMedium: piece.font = Theme.TypeRole.reading.font(weight: .medium)
            case .monospaced: piece.font = .system(size: 12, weight: .regular, design: .monospaced)
            }
            result += piece
        }
        let plain = String(result.characters)
        for range in ClipboardSearch.ranges(of: query, in: plain) {
            guard let attributedRange = Range(range, in: result) else { continue }
            result[attributedRange].backgroundColor = Theme.findHighlight
            result[attributedRange].foregroundColor = Theme.findHighlightText
        }
        return result
    }

    /// The matched ranges as character offsets, for a test that holds what is
    /// lit without reading attributes.
    static func matchedText(_ runs: [Run], query: String) -> [String] {
        let plain = runs.map(\.text).joined()
        return ClipboardSearch.ranges(of: query, in: plain).map { String(plain[$0]) }
    }
}

// MARK: - Swatch and icons

enum ClipSwatch {
    /// The colour a value stands for, parsed from the same grammar the detector
    /// accepts. Nil for anything it cannot draw — the swatch is then empty
    /// rather than wrong.
    static func color(for value: String) -> Color? {
        guard let rgba = rgba(for: value) else { return nil }
        return Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    static func rgba(for raw: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") {
            var digits = String(value.dropFirst())
            if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6 || digits.count == 8, let number = UInt64(digits, radix: 16) else { return nil }
            let hasAlpha = digits.count == 8
            let shift: (UInt64) -> Double = { Double((number >> $0) & 0xFF) / 255 }
            return hasAlpha
                ? (shift(24), shift(16), shift(8), shift(0))
                : (shift(16), shift(8), shift(0), 1)
        }
        guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") else { return nil }
        let name = String(value[..<open])
        let parts = value[value.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == "/" || $0.isWhitespace }).map(String.init)
        func number(_ part: String, scale: Double) -> Double? {
            part.hasSuffix("%") ? Double(part.dropLast()).map { $0 / 100 } : Double(part).map { $0 / scale }
        }
        let alpha = parts.count > 3 ? number(parts[3], scale: 1) ?? 1 : 1
        switch name {
        case "rgb", "rgba":
            guard parts.count >= 3, let r = number(parts[0], scale: 255), let g = number(parts[1], scale: 255),
                  let b = number(parts[2], scale: 255) else { return nil }
            return (r, g, b, alpha)
        case "hsl", "hsla":
            guard parts.count >= 3, let h = Double(parts[0].replacingOccurrences(of: "deg", with: "")),
                  let s = number(parts[1], scale: 100), let l = number(parts[2], scale: 100) else { return nil }
            let (r, g, b) = hslToRGB(h: h, s: s, l: l)
            return (r, g, b, alpha)
        default:
            return nil
        }
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360) / 60)
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = l - c / 2
        return (r1 + m, g1 + m, b1 + m)
    }
}

/// A file's real icon, asked once per path: `icon(forFile:)` is a Launch
/// Services lookup, and a list of forty redrawn twice a minute would ask forty
/// times.
@MainActor
enum ClipFileIcons {
    private static var cache: [String: NSImage] = [:]

    static func first(of item: ClipItem) -> URL? {
        switch item.payload {
        case .file(let url): return url
        case .files(let urls): return urls.first
        default: return nil
        }
    }

    static func icon(for url: URL) -> NSImage {
        if let known = cache[url.path] { return known }
        if cache.count > 200 { cache.removeAll() }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[url.path] = icon
        return icon
    }
}
