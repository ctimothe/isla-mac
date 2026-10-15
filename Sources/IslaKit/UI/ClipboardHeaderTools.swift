import SwiftUI

/// The Clipboard header's tools (spec §9.3): the segmented "Kind" filter, Search
/// and Expand — and, while Search is open, the field that replaces them.
///
/// Laid over the header strip after its accessibility element, as the lyric
/// tools and the Shelf's Expand are (`ExpandHeaderTool`): an inline control
/// would be swallowed by the strip's `.ignore` and unreachable to VoiceOver,
/// and each piece is placed by its own offset so the rest of the strip keeps its
/// click-to-close.
struct ClipboardHeaderTools: ViewModifier {
    let isShown: Bool
    let bodyWidth: CGFloat
    let itemCount: Int
    @ObservedObject var browser: ClipboardBrowser
    @Binding var isExpanded: Bool
    /// Whether the panel holds the keyboard, the way Translate's field reads it:
    /// the field follows the claim, so the caret stops blinking here when the
    /// keyboard has genuinely gone elsewhere.
    @Binding var wantsKeyboard: Bool
    let openSearch: () -> Void
    let closeSearch: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if isShown, !browser.isSearching, itemCount > 0 {
                    ClipboardKindControl(selection: $browser.filter, bodyWidth: bodyWidth)
                        .offset(
                            x: ClipboardHeader.filter(bodyWidth: bodyWidth).minX,
                            y: ClipboardHeader.filter(bodyWidth: bodyWidth).minY
                        )
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if isShown, !browser.isSearching, ClipboardHeader.showsSearch(itemCount: itemCount) {
                    HeaderIconButton(
                        symbol: "magnifyingglass", label: localized("Search"), action: openSearch
                    )
                    .offset(
                        x: ClipboardHeader.search(bodyWidth: bodyWidth).minX,
                        y: ClipboardHeader.search(bodyWidth: bodyWidth).minY
                    )
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if isShown, browser.isSearching {
                    ClipboardSearchField(
                        browser: browser, wantsKeyboard: $wantsKeyboard, close: closeSearch
                    )
                    .frame(
                        width: ClipboardHeader.searchField(bodyWidth: bodyWidth).width,
                        height: ClipboardHeader.searchField(bodyWidth: bodyWidth).height
                    )
                    .offset(
                        x: ClipboardHeader.searchField(bodyWidth: bodyWidth).minX,
                        y: ClipboardHeader.searchField(bodyWidth: bodyWidth).minY
                    )
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                // Not while the field is open: it takes the corner (the board
                // draws its ⓧ where Expand sits), and Escape closes it.
                if isShown, !browser.isSearching,
                   ClipboardHeader.showsTools(itemCount: itemCount, isExpanded: isExpanded, isSearching: false) {
                    ExpandCollapseButton(isExpanded: $isExpanded)
                        .offset(x: HeaderToolFrames.expand(bodyWidth: bodyWidth).minX, y: HeaderToolFrames.top)
                        .transition(.opacity)
                }
            }
    }
}

// MARK: - The Kind filter

/// All · Text · Links · Images · Files, 270 × 20 (or five symbols, 150 × 20,
/// below 540) on a 0.08 track, the chosen segment on a lighter plate (spec §9.3).
///
/// Drawn by hand like the Settings choice rows, for the same reason — a native
/// segmented control looks like AppKit on the dark pane — and vended to an
/// assistive client as what it is: a radio group named "Kind", a radio button
/// per segment. With symbols the names are the tooltips and the accessibility
/// labels, so narrowing the panel never makes the control nameless.
struct ClipboardKindControl: View {
    @Binding var selection: ClipFilter
    let bodyWidth: CGFloat

    private var usesSymbols: Bool { ClipboardHeader.usesSymbolSegments(bodyWidth: bodyWidth) }
    private var size: CGSize { ClipboardHeader.filterSize(bodyWidth: bodyWidth) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ClipFilter.allCases, id: \.self) { filter in
                let isSelected = filter == selection
                Button { selection = filter } label: {
                    Group {
                        if usesSymbols {
                            Image(systemName: filter.symbol)
                                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        } else {
                            Text(filter.title)
                                .islandFont(.body, weight: isSelected ? .medium : .regular)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(isSelected ? Color.white : Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Theme.surfaceHover)
                                .shadow(color: Color.black.opacity(0.25), radius: 1, x: 0, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PanelButtonStyle())
                .help(filter.title)
            }
        }
        .padding(2)
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.clipboardWell))
        .animation(Theme.contentAnimation, value: selection)
        .accessibilityRepresentation {
            Picker(localized("Kind"), selection: $selection) {
                ForEach(ClipFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}

// MARK: - The search field

/// The field that replaces the filter while Search is open (spec §9.3): 294 × 22,
/// radius 7, fill 0.10, a magnifier, the caret in the accent, and Clear Search ⓧ.
///
/// Typing needs the keyboard, which the panel only has while somebody asks —
/// `NotchPanel.canBecomeKey` is false except for Translate. The field asks
/// the way Translate does: opening it raised `wantsKeyboard`
/// (`NotchViewModel.openClipboardSearch`), the controller made the panel key
/// from that, and this follows the claim in both directions.
struct ClipboardSearchField: View {
    @ObservedObject var browser: ClipboardBrowser
    @Binding var wantsKeyboard: Bool
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            TextField("", text: $browser.query, prompt: Text(localized("Search")).foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain)
                .islandFont(.reading, weight: .regular)
                .foregroundStyle(.white)
                .tint(Theme.accent)
                .focused($focused)
                .accessibilityLabel(localized("Search"))
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: ClipboardHeader.clearSide + 6, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PanelButtonStyle())
            .help(localized("Clear Search"))
            .accessibilityLabel(localized("Clear Search"))
        }
        .padding(.leading, 9)
        .padding(.trailing, 2)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: ClipboardHeader.searchFieldRadius, style: .continuous)
                .fill(Theme.searchFieldFill)
        )
        .onAppear { focused = wantsKeyboard }
        .onChange(of: wantsKeyboard) { _, wants in focused = wants }
    }
}
