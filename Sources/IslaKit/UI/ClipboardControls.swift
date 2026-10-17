import SwiftUI

// MARK: - The Kind filter (§19.8)

/// All, Text, Links and Images, as a segmented control. Files show under All,
/// which is where a copied file has always been looked for.
///
/// Drawn by hand like the Settings choice rows, for the same reason — a native
/// segmented control looks like AppKit on the dark panel — and vended to an
/// assistive client as what it is: a radio group named "Kind", a radio button
/// per segment. With symbols the names are the tooltips and the accessibility
/// labels, so narrowing the panel never makes the control nameless.
struct ClipboardKindControl: View {
    @Binding var selection: ClipFilter
    let bodyWidth: CGFloat

    private var usesSymbols: Bool { ClipboardHeader.usesSymbolSegments(bodyWidth: bodyWidth) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ClipboardBrowser.filters, id: \.self) { filter in
                let isSelected = filter == selection
                Button { selection = filter } label: {
                    Group {
                        if usesSymbols {
                            Image(systemName: filter.symbol)
                                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                        } else {
                            Text(filter.title)
                                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(isSelected ? Color.white : Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
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
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.clipboardWell))
        .animation(Theme.contentAnimation, value: selection)
        .accessibilityRepresentation {
            Picker(localized("Kind"), selection: $selection) {
                ForEach(ClipboardBrowser.filters, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}

// MARK: - The search field (§19.8)

/// The search field, always on Clipboard: 270 × 28, radius 8, white 0.10, a
/// magnifier, "Search" as its placeholder, and Clear Search ⓧ once something
/// is typed. It has the keyboard when the surface opens, with a 1.5 pt blue
/// ring while it does: typing searches from the first key.
///
/// Typing needs the keyboard, which the panel has only while a surface asks —
/// `NotchPanel.canBecomeKey` follows `wantsKeyboard`, which opening Clipboard
/// raises (`NotchViewModel.open`). The field follows the claim both ways.
/// ↑, ↓ and Return never reach it: the panel hands them to the list first
/// (`NotchPanel.listKeyHandled`).
struct ClipboardSearchField: View {
    @ObservedObject var browser: ClipboardBrowser
    @Binding var wantsKeyboard: Bool
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ClipboardHeader.searchFieldRadius, style: .continuous)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.secondary)
                .accessibilityHidden(true)
            TextField("", text: $browser.query, prompt: Text(localized("Search")).foregroundStyle(Theme.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white)
                .tint(Theme.shelfBlue)
                .focused($focused)
                .accessibilityLabel(localized("Search"))
            if !browser.query.isEmpty {
                Button { browser.clearQuery() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: ClipboardHeader.clearSide + 6, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelButtonStyle())
                .help(localized("Clear Search"))
                .accessibilityLabel(localized("Clear Search"))
                .transition(.opacity)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 3)
        .background(shape.fill(Color.white.opacity(ClipboardHeader.searchFieldFillOpacity)))
        .overlay {
            if focused {
                shape.strokeBorder(
                    Theme.shelfBlue.opacity(ClipboardHeader.searchRingOpacity),
                    lineWidth: ClipboardHeader.searchRingWidth
                )
            }
        }
        .animation(Theme.contentAnimation, value: focused)
        .animation(Theme.contentAnimation, value: browser.query.isEmpty)
        .onAppear { focused = wantsKeyboard }
        .onChange(of: wantsKeyboard) { _, wants in focused = wants }
        // A click into the field is a request for the keyboard, like a click
        // into Translate's.
        .onChange(of: focused) { _, isFocused in if isFocused, !wantsKeyboard { wantsKeyboard = true } }
    }
}
