import SwiftUI

/// Raises a flag and lowers it again a moment later.
///
/// The moment is 1.1 s everywhere in the panel, and it is a compromise between
/// two failures: shorter and the checkmark is gone before the eye returns from
/// wherever the copy was going, longer and a second copy lands while the first
/// is still being confirmed, so the tick never appears to move.
@MainActor
func flash(_ flag: Binding<Bool>) {
    flag.wrappedValue = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
        flag.wrappedValue = false
    }
}

/// Copies, then says so.
///
/// The panel has no other way to confirm a copy: the pasteboard is invisible,
/// and the thing that was copied is usually going somewhere the panel cannot
/// see. Turning the icon into a tick for a moment is the whole feedback, which
/// is why it is worth having in one place rather than four.
struct CopyButton: View {
    let copy: () -> Void

    @State private var copied = false

    var body: some View {
        Button {
            copy()
            flash($copied)
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(copied ? Color.green : Theme.secondary)
        }
        .buttonStyle(.plain)
        .help(localized("Copy"))
        .animation(Theme.contentAnimation, value: copied)
    }
}
