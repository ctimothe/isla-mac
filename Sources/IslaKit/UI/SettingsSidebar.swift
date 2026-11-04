import AppKit
import SwiftUI

/// The sidebar of Settings (redesign 2026-10-15, spec §10; native pass
/// 2026-10-25): ten rows 32 apart, a 20 pt tile — System Settings' own pane
/// icon where the system has one — a 13 pt label in `labelColor`, and the
/// selected row filled with the system accent under a white label, as System
/// Settings draws its selection while you use it.
///
/// A long name truncates at its tail and says the whole of itself in a tooltip:
/// the label is cut to `SettingsLayout.sidebarLabelWidth` so it can never run
/// under the form. To an assistive client the column is one group named "Settings
/// sections", and each row is a button that says whether it is the selected one.
struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    var icons: AppIcons = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.sidebarRowPitch - SettingsLayout.sidebarRowHeight) {
            ForEach(SettingsSection.allCases) { section in
                row(section)
            }
        }
        .frame(width: SettingsLayout.sidebarWidth, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Settings sections"))
    }

    private func row(_ section: SettingsSection) -> some View {
        let isSelected = section == selection
        return Button {
            selection = section
        } label: {
            HStack(spacing: SettingsLayout.sidebarLabelInset - SettingsLayout.sidebarIconInset - SettingsLayout.sidebarIconSide) {
                SettingsSectionIcon(glyph: section.glyph, icons: icons)
                    .padding(.leading, SettingsLayout.sidebarIconInset)
                // Regular whether selected or not: System Settings does not
                // bolden its selection, the fill says it.
                Text(section.title)
                    .islandFont(SettingsLayout.labelRole, weight: .regular)
                    .foregroundStyle(isSelected ? Color.white : Theme.settingsLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: SettingsLayout.sidebarLabelWidth, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(width: SettingsLayout.sidebarWidth, height: SettingsLayout.sidebarRowHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsLayout.sidebarSelectionRadius, style: .continuous)
                    .fill(isSelected ? Theme.settingsSidebarSelection : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: SettingsLayout.sidebarSelectionRadius, style: .continuous))
        }
        .buttonStyle(PanelButtonStyle())
        // The whole name, where a pointer rests on a truncated one.
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The tile at the head of a sidebar row (native pass, 2026-10-25).
///
/// System Settings' own pane icon, read from the system at runtime and drawn
/// so its tile is `side` (`Theme.systemPaneIconOpticalScale`); where the
/// system has none, a tile drawn the way IconServices draws its own — the
/// system colour as a top-to-bottom gradient, a white symbol, no lit edge —
/// so drawn and system tiles line up; Isla's own icon for About.
/// Decoration: the row's label already says what it is.
struct SettingsSectionIcon: View {
    let glyph: SettingsSection.Glyph
    var side: CGFloat = SettingsLayout.sidebarIconSide
    /// `.shared` in the app; injected by a test that renders the sidebar.
    @ObservedObject var icons: AppIcons = .shared

    var body: some View {
        Group {
            switch glyph {
            case .symbol(let name, let tint):
                DrawnPaneTile(symbol: name, tint: tint, side: side)
            case .system(let source, let fallback, let tint):
                if let image = icons.systemIcon(source) {
                    SystemPaneIconImage(image: image, side: side)
                } else {
                    DrawnPaneTile(symbol: fallback, tint: tint, side: side)
                }
            case .isla:
                // Isla's icon carries the same transparent margin every macOS
                // icon does, so it sat visibly smaller than the tiles above it.
                AppIconImage(image: AppIcons.islaIcon, side: side)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// A System Settings pane icon drawn so its tile, 832 of the 1024 canvas,
/// fills `side`; the margin and the icon's own shadow spill outside, as
/// `AppIconImage` lets an app icon's.
struct SystemPaneIconImage: View {
    let image: NSImage
    var side: CGFloat

    var body: some View {
        let drawn = side * Theme.systemPaneIconOpticalScale
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: drawn, height: drawn)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// A section tile drawn the System Settings way, where the system has no icon
/// of its own to lend: the enclosure colour as a gentle top-to-bottom
/// gradient (IconServices' General grey measured 153 → 177 at 20–128 pt) and
/// a white symbol.
struct DrawnPaneTile: View {
    let symbol: String
    let tint: Theme.SettingsTint
    var side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: side * SettingsLayout.sidebarIconRadius / SettingsLayout.sidebarIconSide, style: .continuous)
            .fill(LinearGradient(
                colors: [tint.color.opacity(0.88), tint.color],
                startPoint: .top, endPoint: .bottom
            ))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: side * 0.56, weight: .medium))
                    .foregroundStyle(Theme.settingsIconGlyph)
            }
            // Decoration: the row's title says what it is, and the symbol's
            // own name ("Song") was one more stop for VoiceOver.
            .accessibilityHidden(true)
    }
}

/// The fallback for Spotify's icon, drawn when Spotify is not installed: a green
/// disc and three arcs. Connections lists Spotify whether or not it is
/// installed, because its row is where the account is connected.
///
/// It used to be the only Spotify mark Settings had and it looked fake — the
/// owner said so — next to the real icons of the apps on his Mac. Now the real
/// icon comes from the person's own copy of the app (`AppIcons`,
/// `InstalledAppIcon`), and this stays as the stand-in for a Mac that has none. It is drawn rather than shipped as an
/// image on purpose: this is the one place the app names a brand it does not
/// own, so no asset of the brand's travels in the bundle (and
/// `test-branding.sh` has nothing to look at). The real icons never do either:
/// they are read from `/Applications` at runtime and never copied.
struct SpotifyMark: View {
    var body: some View {
        Circle()
            .fill(Theme.spotifyMark)
            .overlay {
                SpotifyArcs()
                    .stroke(Theme.spotifyMarkInk, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 4)
            }
    }
}

private struct SpotifyArcs: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<3 {
            let y = rect.minY + rect.height * (0.18 + 0.30 * CGFloat(index))
            let half = rect.width * (0.5 - 0.08 * CGFloat(index))
            path.move(to: CGPoint(x: rect.midX - half, y: y + rect.height * 0.09))
            path.addQuadCurve(
                to: CGPoint(x: rect.midX + half, y: y + rect.height * 0.09),
                control: CGPoint(x: rect.midX, y: y - rect.height * 0.10)
            )
        }
        return path
    }
}
