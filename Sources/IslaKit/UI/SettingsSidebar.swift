import AppKit
import SwiftUI

/// The sidebar of Settings (redesign 2026-10-15, spec §10): ten rows 26 apart,
/// an 18 pt rounded-square icon in the section's colour, a 12.5 pt label, the
/// selected row on white 0.12 at radius 6.
///
/// A long name truncates at its tail and says the whole of itself in a tooltip
/// (Russian's «Конфиденциальность» is the one that needs it at 480): the label
/// is cut to `SettingsLayout.sidebarLabelWidth` so it can never run under the
/// form. To an assistive client the column is one group named "Settings
/// sections", and each row is a button that says whether it is the selected one.
struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

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
                SettingsSectionIcon(glyph: section.glyph)
                    .padding(.leading, SettingsLayout.sidebarIconInset)
                Text(section.title)
                    .islandFont(.reading, weight: isSelected ? .medium : .regular)
                    .foregroundStyle(.white)
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

/// The 18 pt tile at the head of a sidebar row.
///
/// A symbol in white on the section's colour with the half-point lit top edge
/// the boards draw, or — for Spotify and About — the app's own icon, drawn at
/// the optical size of the tiles beside it (`AppIconImage`). Decoration: the
/// row's label already says what it is.
struct SettingsSectionIcon: View {
    let glyph: SettingsSection.Glyph
    var side: CGFloat = SettingsLayout.sidebarIconSide

    var body: some View {
        Group {
            switch glyph {
            case .symbol(let name, let tint):
                RoundedRectangle(cornerRadius: SettingsLayout.sidebarIconRadius, style: .continuous)
                    .fill(tint.color)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Theme.settingsIconEdge).frame(height: 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sidebarIconRadius, style: .continuous))
                    .overlay {
                        Image(systemName: name)
                            .font(.system(size: side * 0.58, weight: .semibold))
                            .foregroundStyle(Theme.settingsIconGlyph)
                    }
            case .spotify:
                // The real Spotify, from this Mac's own copy of the app; the
                // drawn disc only where Spotify is not installed.
                InstalledAppIcon(bundleID: PlayerApp.spotify.bundleID, side: side) { SpotifyMark() }
            case .isla:
                // Isla's icon carries the same transparent margin every macOS
                // icon does, so it sat visibly smaller than the tiles above it.
                AppIconImage(image: NSApplication.shared.applicationIconImage, side: side)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// The fallback for Spotify's icon, drawn when Spotify is not installed: a green
/// disc and three arcs.
///
/// It used to be the only Spotify mark Settings had, in the sidebar and the
/// 40 pt section head, and it looked fake — the owner said so — next to the
/// real icons of the apps on his Mac. Now the real icon comes from the person's
/// own copy of the app (`AppIcons`, `InstalledAppIcon`), and this stays as the
/// stand-in for a Mac that has none. It is drawn rather than shipped as an
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
