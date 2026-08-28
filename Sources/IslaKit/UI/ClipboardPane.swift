import SwiftUI

struct ClipboardPane: View {
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var privacy: PrivacyMode

    var body: some View {
        VStack(spacing: 0) {
            if clipboard.items.isEmpty {
                Image(systemName: "list.clipboard")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    // One clock for every covered row in the list — see
                    // `SpoilerClock`.
                    SpoilerClock {
                        LazyVStack(spacing: 3) {
                            ForEach(clipboard.items) { item in
                                ClipRow(item: item, clipboard: clipboard, privacy: privacy)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                footer
            }
        }
        .padding(.top, 2)
    }

    private var footer: some View {
        HStack {
            Spacer()
            ConfirmTextButton(
                title: localized("Clear"),
                armedTitle: localized("Clear Everything?")
            ) { clipboard.clear() }
        }
        .padding(.top, 2)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var privacy: PrivacyMode
    @State private var hovering = false
    @State private var justCopied = false

    private var hidden: Bool { privacy.hides(.clipboard, item.id.uuidString) }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: justCopied ? "checkmark" : item.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(justCopied ? Color.green : Theme.tertiary)
                .frame(width: 14)
            SpoilerText(
                text: item.preview,
                hidden: hidden,
                seed: UInt64(bitPattern: Int64(item.id.uuidString.hashValue))
            )
            Spacer(minLength: 6)
            if hovering {
                if privacy.covers(.clipboard) {
                    RevealEye(hidden: hidden) { privacy.toggle(item.id.uuidString) }
                }
                Button { clipboard.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        // A 9pt glyph is a ~10pt target sitting beside the
                        // reveal eye, inside a row whose own background
                        // copies to the pasteboard — missing it by two
                        // points overwrote what the user had copied.
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localized("Remove Entry"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Theme.surfaceHover : Theme.surface)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            clipboard.copy(item)
            flash($justCopied)
        }
        // The row's primary action is a tap gesture, which carries no role
        // and no action for assistive tech. Declared explicitly so copying
        // is reachable without the pointer.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(localized("Copy Entry"))
        .accessibilityAction { 
            clipboard.copy(item)
            flash($justCopied)
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: justCopied)
    }
}
