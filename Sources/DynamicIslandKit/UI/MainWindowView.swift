import SwiftUI

/// The window's content: a sidebar and a page, and nothing that pretends to be
/// more finished than it is.
///
/// The sidebar is driven by an enum rather than hand-built rows, because the
/// point of this window is to be somewhere a later feature can be dropped: add
/// a case, give it a title and a symbol, and answer it in `page`. Two pages
/// ship — the four things the status-bar menu used to do, and an About page.
/// Inventing more would be inventing features.
struct MainWindowView: View {
    /// Opens or closes the island itself. The window can do it because the
    /// menu could, and losing it in the move would be losing a function.
    let togglePanel: () -> Void
    /// Nil only before the island has finished installing, which the window
    /// cannot normally outrun — the section says so rather than lying with a
    /// row of dead switches.
    let privacy: PrivacyMode?

    enum Section: String, CaseIterable, Identifiable {
        case island, about

        var id: String { rawValue }

        var title: String {
            switch self {
            case .island: return localized("Island")
            case .about: return localized("About")
            }
        }

        var symbol: String {
            switch self {
            case .island: return "capsule.fill"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selection: Section = .island

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(28)
        }
    }

    @ViewBuilder
    private var page: some View {
        switch selection {
        case .island: islandPage
        case .about: aboutPage
        }
    }

    // MARK: - Island

    private var islandPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            header(
                localized("Island"),
                localized("The panel at the notch, and what it is allowed to show.")
            )

            Button(action: togglePanel) {
                Label(localized("Open Panel"), systemImage: "chevron.down.circle")
            }
            .controlSize(.large)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text(localized("Hide Contents"))
                    .font(.headline)
                // Wording carried over from the menu: this is the switch people
                // look for in a hurry, with the camera already running.
                Text(localized("Covers what the panel is showing, for a screen somebody else is watching."))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let privacy {
                    PrivacyControls(privacy: privacy)
                } else {
                    Text(localized("Available once the island has started."))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - About

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            header(ProductIdentity.displayName, localized("Version %@", Bundle.main.shortVersion))
            Text(localized("A notch-anchored companion for what is playing, what you copied, and what you are reading."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text(localized("Licenses"))
                .font(.headline)
            Text(localized("This app carries third-party notices in its bundle, under Contents/Resources/Licenses."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// The privacy switches, observing the same object the menu used to drive.
///
/// Split out because `PrivacyMode` reaches the window as an optional, and
/// `@ObservedObject` cannot be optional — the unwrap has to happen before the
/// view that observes it exists.
private struct PrivacyControls: View {
    @ObservedObject var privacy: PrivacyMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(localized("All"), isOn: Binding(
                get: { privacy.coversAll },
                // Anything short of everything means "turn the rest on too";
                // only a full house turns them all off. Same rule the menu had,
                // and the reason it is one switch rather than a count.
                set: { _ in privacy.setCoveringAll(!privacy.coversAll) }
            ))
            .toggleStyle(.switch)

            ForEach(PrivacyMode.Section.allCases) { section in
                Toggle(section.title, isOn: Binding(
                    get: { privacy.covers(section) },
                    set: { privacy.setCovering(section, $0) }
                ))
                .toggleStyle(.switch)
                .padding(.leading, 18)
            }
        }
    }
}
