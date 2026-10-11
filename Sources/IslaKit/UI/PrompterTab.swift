import SwiftUI

/// The Prompter's tab. A placeholder: an empty container that holds the pane's
/// place so the rail, the keyboard hand-off and the pane switch can be built
/// and tested ahead of the tab itself (plan T5). T10 builds the script row,
/// the editor and the control row inside it.
///
/// It carries no user-facing string on purpose. The rail icon's label is the
/// tab's title, and the pane's group takes its name from there; anything
/// else said here would have to be translated twice for a screen nobody sees.
struct PrompterTab: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
