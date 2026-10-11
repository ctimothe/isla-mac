import SwiftUI

// The Prompter's rows in Settings (spec 5.3, 12.2), kept out of `SettingsPane`
// so the largest pane in the app does not grow by another screenful. The pane
// owns the section card and its always-present switch; this file owns what is
// drawn only while the switch is on, and the Quit button that has to know
// whether a session is holding the panel (spec 11.7).

// MARK: - Option vocabulary

extension PrompterFontSize: Identifiable { var id: String { rawValue } }
extension PrompterFontFamily: Identifiable { var id: String { rawValue } }
extension PrompterTint: Identifiable { var id: String { rawValue } }
extension PrompterCueBrightness: Identifiable { var id: String { rawValue } }
extension PrompterReadingPosition: Identifiable { var id: String { rawValue } }

/// The words for the settings' options. Each literal sits inside `localized`
/// so `test-localizations.sh` sees it used, and they are functions of the
/// option so a new case is a compile error here and not a blank capsule.
enum PrompterSettingsCopy {
    static func title(_ size: PrompterFontSize) -> String {
        switch size {
        case .xs: return localized("Extra Small")
        case .sm: return localized("Small")
        case .lg: return localized("Large")
        case .xl: return localized("Extra Large")
        }
    }

    /// OpenDyslexic is a font the user installs themselves. Missing, the stage
    /// uses the rounded system face without a word (design note, type), so the
    /// option stays choosable and the row is where the absence is said.
    static func title(_ family: PrompterFontFamily, installed: Bool) -> String {
        switch family {
        case .sans: return localized("Sans")
        case .serif: return localized("Serif")
        case .mono: return localized("Mono")
        case .dyslexia:
            return installed ? localized("OpenDyslexic") : localized("OpenDyslexic (not installed)")
        }
    }

    static func title(_ tint: PrompterTint) -> String {
        switch tint {
        case .white: return localized("White")
        case .yellow: return localized("Yellow")
        case .green: return localized("Green")
        case .blue: return localized("Blue")
        case .pink: return localized("Pink")
        case .orange: return localized("Orange")
        }
    }

    static func title(_ brightness: PrompterCueBrightness) -> String {
        switch brightness {
        case .dim: return localized("Dim")
        case .low: return localized("Low")
        case .medium: return localized("Medium")
        case .bright: return localized("Bright")
        }
    }

    static func title(_ position: PrompterReadingPosition) -> String {
        switch position {
        case .centered: return localized("Centered")
        case .nearTop: return localized("Near Top")
        }
    }

    /// 0 is the next page at once; the others are seconds of countdown.
    static func delayTitle(_ seconds: Int) -> String {
        seconds == 0 ? localized("At Once") : localized("%d s", seconds)
    }

    static var autoNextReason: String { localized("Needs Auto-Next Page") }

    /// Release 1 has no Word Tracking, the one mode that shows the last words
    /// heard, so the row the spec lists is drawn dimmed with this reason
    /// rather than live and inert (and rather than absent, which would hide a
    /// setting the spec promises).
    static var lastSpokenReason: String { localized("Needs Word Tracking, which is not available yet") }
}

// MARK: - Rows

/// The Prompter settings that exist in release 1, one row each, in the order
/// of spec 5.3. The microphone and speech rows are releases 2 and 3 and arrive
/// with their engines: a control for something that does not work is worse
/// than none (`PrompterSettingsValues`).
///
/// Observes the settings, not the pane: a change here must redraw these rows
/// and nothing else of Settings.
struct PrompterSettingsRows: View {
    @ObservedObject var settings: PrompterSettings
    /// Asked once per draw for the one face that can be missing.
    var fontInstalled: (PrompterFontFamily) -> Bool = PrompterFontResolver.isInstalled

    /// The slider's ends are the settings' own clamp, so the two cannot drift.
    static let columnWidthRange = PrompterSettingsValues.columnWidthRange

    private struct DelayOption: Identifiable, Hashable {
        let seconds: Int
        var id: Int { seconds }
    }

    var body: some View {
        VStack(spacing: 1) {
            speedRow
            SettingsChoiceRow(
                symbol: SettingsIcon.prompterTextSize, title: localized("Text Size"),
                options: PrompterFontSize.allCases, selection: binding(\.fontSize),
                optionTitle: { PrompterSettingsCopy.title($0) }
            )
            SettingsChoiceRow(
                symbol: SettingsIcon.prompterFont, title: localized("Font"),
                options: PrompterFontFamily.allCases, selection: binding(\.fontFamily),
                optionTitle: { PrompterSettingsCopy.title($0, installed: fontInstalled($0)) }
            )
            SettingsChoiceRow(
                symbol: SettingsIcon.prompterHighlight, title: localized("Highlight Color"),
                options: PrompterTint.allCases, selection: binding(\.highlight),
                optionTitle: { PrompterSettingsCopy.title($0) },
                swatch: { $0.rgb.color }
            )
            SettingsChoiceRow(
                symbol: SettingsIcon.prompterCueColor, title: localized("Cue Color"),
                options: PrompterTint.allCases, selection: binding(\.cueColor),
                optionTitle: { PrompterSettingsCopy.title($0) },
                swatch: { $0.rgb.color }
            )
            SettingsChoiceRow(
                symbol: SettingsIcon.prompterCueBrightness, title: localized("Cue Brightness"),
                options: PrompterCueBrightness.allCases, selection: binding(\.cueBrightness),
                optionTitle: { PrompterSettingsCopy.title($0) }
            )
            SettingsChoiceRow(
                symbol: SettingsIcon.prompterReadingPosition, title: localized("Reading Position"),
                options: PrompterReadingPosition.allCases, selection: binding(\.readingPosition),
                optionTitle: { PrompterSettingsCopy.title($0) }
            )
            SettingsSliderRow(
                symbol: SettingsIcon.prompterColumnWidth,
                title: localized("Column Width"),
                value: Binding(
                    get: { settings.columnWidth },
                    // Whole points: a drag writes on every tick, and a width
                    // finer than a point is no different to look at.
                    set: { settings.columnWidth = $0.rounded() }
                ),
                range: Self.columnWidthRange,
                drawnValue: localized("%d pt", Int(settings.columnWidth)),
                spokenValue: localized("%d points", Int(settings.columnWidth))
            )
            toggle(SettingsIcon.prompterDividers, localized("Paragraph Dividers"), binding(\.paragraphDividers))
            toggle(
                SettingsIcon.prompterLastSpoken, localized("Last Spoken Words"), binding(\.showLastSpoken),
                reason: PrompterSettingsCopy.lastSpokenReason
            )
            toggle(SettingsIcon.prompterElapsed, localized("Elapsed Time"), binding(\.showElapsed))
            toggle(SettingsIcon.prompterKeepAwake, localized("Keep Display Awake"), binding(\.keepAwake))
            toggle(SettingsIcon.prompterAutoNext, localized("Auto-Next Page"), binding(\.autoNext))
            SettingsChoiceRow(
                symbol: SettingsIcon.prompterAutoNextDelay, title: localized("Auto-Next Delay"),
                options: PrompterSettingsValues.autoNextDelays.map(DelayOption.init(seconds:)),
                selection: Binding(
                    get: { DelayOption(seconds: settings.autoNextDelay) },
                    set: { settings.autoNextDelay = $0.seconds }
                ),
                optionTitle: { PrompterSettingsCopy.delayTitle($0.seconds) },
                reason: settings.autoNext ? nil : PrompterSettingsCopy.autoNextReason
            )
            .disabledWithReason(settings.autoNext ? nil : PrompterSettingsCopy.autoNextReason)
            ConfirmRow(
                symbol: SettingsIcon.resetTiming,
                title: localized("Reset Prompter Settings"),
                armedTitle: localized("Reset")
            ) {
                settings.reset()
            }
            Text(localized("Puts these settings back to their defaults. Your scripts are not touched."))
                .islandFont(.body, weight: .regular)
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.top, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A binding to one setting. The setters clamp and write only a change.
    private func binding<T>(_ path: ReferenceWritableKeyPath<PrompterSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: path] }, set: { settings[keyPath: path] = $0 })
    }

    private func toggle(_ symbol: String, _ title: String, _ isOn: Binding<Bool>, reason: String? = nil) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                RowIcon(symbol: symbol)
                Text(title)
                    .islandFont(.body)
                    .foregroundStyle(.white)
            }
        }
        .toggleStyle(PanelSwitchStyle())
        .accessibilityLabel(title)
        .disabledWithReason(reason)
    }

    /// The tab's own stepper rule (0.5 to 8 in halves), called and not copied,
    /// so Settings and the tab cannot disagree about what a press does.
    private var speedRow: some View {
        HStack(spacing: 8) {
            RowIcon(symbol: SettingsIcon.prompterSpeed)
            Text(localized("Speed"))
                .islandFont(.body)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            step("minus", localized("Slower"), by: -1)
            Text(localized("%@ words/s", String(format: "%.1f", settings.speed)))
                .font(Theme.TypeRole.caption.font().monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .frame(minWidth: 64)
                .accessibilityLabel(localized("%@ words per second", String(format: "%.1f", settings.speed)))
            step("plus", localized("Faster"), by: 1)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .accessibilityElement(children: .contain)
    }

    private func step(_ symbol: String, _ title: String, by steps: Int) -> some View {
        let can = PrompterTabModel.canStep(settings.speed, by: steps)
        return Button {
            settings.speed = PrompterTabModel.steppedSpeed(settings.speed, by: steps)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
        }
        .buttonStyle(NotchButtonStyle(size: 22))
        .disabled(!can)
        .opacity(can ? 1 : 0.4)
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Quit

/// Settings' Quit (spec 11.7). It always asked twice (a footer is where a stray
/// click lands); during a Prompter session the armed word also says what the
/// second press does, because quitting ends the session and a speaker in the
/// middle of a script should read that before confirming, not after.
///
/// Two shapes of one button: the plain one while the Prompter does not exist
/// or is idle, and one that observes the session while it can hold the panel.
/// The session is observed only here, by the footer, so a running clock never
/// redraws the rest of Settings.
struct SettingsQuitButton: View {
    let session: PrompterSession?
    let quit: () -> Void

    var body: some View {
        if let session {
            Observing(session: session, quit: quit)
        } else {
            ConfirmTextButton(title: localized("Quit"), armedTitle: localized("Quit Isla"), action: quit)
        }
    }

    private struct Observing: View {
        @ObservedObject var session: PrompterSession
        let quit: () -> Void

        var body: some View {
            ConfirmTextButton(
                title: localized("Quit"),
                armedTitle: session.holdsPanel ? localized("Stop Prompter and Quit") : localized("Quit Isla"),
                action: quit
            )
        }
    }
}
