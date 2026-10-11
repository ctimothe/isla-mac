import AppKit
import SwiftUI

/// The Prompter's stage: the session's view in the panel (spec 5.2, 10; the
/// T7 design note's layout at 208 pt).
///
/// It owns the whole body while a session holds the panel and the rail is
/// gone, as the lyrics page owns its body. Top to bottom: the text column,
/// centred under the camera, then a 24 pt row of controls. The physical notch
/// row above keeps its place and carries the capture chip and the elapsed time
/// in its wings (`PrompterStageWings`, drawn by the header).
///
/// Everything it decides is somewhere else and tested there: where lines
/// break (`PromptFlowLayout`), where the page sits and when it may move
/// (`PromptScrollPlanner`, through `PrompterStageModel`), what each word looks
/// like (`PrompterStageStyle`, `PromptWordStates`), what VoiceOver hears
/// (`PrompterStageSpeech`). The view places what they say.
///
/// The stage never takes key status (5.2) and nothing in it needs the
/// keyboard: Stop and pause have hot keys, and a press here is a click.
struct PrompterStage: View {
    @ObservedObject var session: PrompterSession
    @ObservedObject var settings: PrompterSettings
    @ObservedObject var stage: PrompterStageModel
    let reduceMotion: Bool
    let increaseContrast: Bool
    let reduceTransparency: Bool
    /// The panel's Stop (`NotchViewModel.stopPrompter()`), never the
    /// session's own, so the panel lets go exactly as it does for the hot key.
    let stop: () -> Void

    private var style: PrompterStageStyle {
        PrompterStageStyle(
            settings: settings.values, increaseContrast: increaseContrast, reduceTransparency: reduceTransparency
        )
    }

    var body: some View {
        VStack(spacing: PrompterStageMetrics.controlRowGap) {
            PrompterTextRegion(
                session: session, settings: settings, stage: stage,
                style: style, reduceMotion: reduceMotion
            )
            PrompterControlRow(session: session, settings: settings, stop: stop)
                .frame(height: PrompterStageMetrics.controlRowHeight)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Spec 10.5: the stage's ground is the panel's one glass, never a
        // gradient of its own. Drawn, not sampled: the panel behind it is
        // opaque black and there is nothing to sample (the lyrics page's
        // sync pill makes the same call). `PrompterStageStyle` measures every
        // reading state on this glass's brightest point.
        .glassSurface(
            cornerRadius: PrompterStageMetrics.cornerRadius, elevation: .card, samplesBackdrop: false
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Prompter"))
    }
}

// MARK: - Text

/// The column of text, clipped to its region and faded where it continues.
private struct PrompterTextRegion: View {
    @ObservedObject var session: PrompterSession
    @ObservedObject var settings: PrompterSettings
    @ObservedObject var stage: PrompterStageModel
    let style: PrompterStageStyle
    let reduceMotion: Bool

    var body: some View {
        let values = settings.values
        let size = values.fontSize.points
        let font = Font(stage.displayFont(for: PrompterTypeface(family: values.fontFamily, size: size)) as CTFont)
        GeometryReader { geo in
            let height = Double(geo.size.height)
            ZStack(alignment: .topLeading) {
                if let layout = stage.layout, let script = session.script {
                    let offset = stage.offset
                    let uniform = session.mode.drawsUniformly
                    PrompterFlowLayout(
                        layout: layout,
                        layoutStamp: stage.layoutStamp,
                        script: script,
                        lines: layout.lines(
                            intersecting: -offset - PrompterStageMetrics.cullBuffer,
                            -offset + height + PrompterStageMetrics.cullBuffer
                        ),
                        style: style,
                        font: font,
                        tracking: Theme.tracking(forSize: CGFloat(size)),
                        current: uniform ? nil : PromptWordStates.currentWord(in: script, progress: session.progress),
                        atEnd: uniform ? false : session.progress >= Double(script.words.count),
                        uniform: uniform,
                        tap: { stage.tapWord($0) }
                    )
                    .equatable()
                    .offset(x: (geo.size.width - CGFloat(layout.columnWidth)) / 2, y: CGFloat(offset))
                    // Spec 10.3's curve for whatever moved the page, or no
                    // curve at all under Reduce Motion: the page travelling is
                    // the one motion on the stage, and an immediate move is
                    // what the setting asks of it.
                    .animation(stage.motion.animation(reduceMotion: reduceMotion), value: stage.offset)
                    // No `layoutDirection` here for a right-to-left page. The
                    // layout already set its lines from the right edge, in
                    // left-origin coordinates; flipping the environment
                    // mirrored those offsets a second time and pushed every
                    // Hebrew line off the column's left side. Each word's own
                    // glyphs run right to left by themselves.
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .edgeFade(fadedEdges(height: height), length: geo.size.height * PrompterStageMetrics.fadeFraction)
            .contentShape(Rectangle())
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { stage.setViewport($0) }
        // The hand on the wheel moves the page (8.5); the model decides
        // whether it may and when the hand has let go.
        .onScrollWheelDelta { delta, ended in stage.wheel(deltaY: Double(delta), final: ended) }
        // One element for the page: the line being read and how far in.
        // Assistive technology reads the script here; the words themselves
        // are not stops (15).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("Script"))
        .accessibilityValue(stage.accessibilityValue)
        // A role, or the element is an AXUnknown that vends no value at all
        // (the lyric timing readout found the same). Static text is what the
        // page is to someone reading it.
        .accessibilityAddTraits([.isStaticText, .updatesFrequently])
    }

    private func fadedEdges(height: Double) -> Edge.Set {
        guard let layout = stage.layout else { return [] }
        return ScrollEdgeFade.edges(
            offset: CGFloat(-stage.offset), content: CGFloat(layout.height), container: CGFloat(height)
        )
    }
}

// MARK: - Controls

/// The 24 pt row under the text (5.2, design note): a status on the left,
/// then the page chip, play or pause, slower, faster and Stop. Always
/// visible; the panel never relies on hover.
private struct PrompterControlRow: View {
    @ObservedObject var session: PrompterSession
    @ObservedObject var settings: PrompterSettings
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Equal flexible room either side, so the controls sit centred
            // under the camera and the status, when there is one, has the
            // left side to itself without pushing them.
            Color.clear
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) { status }
            if session.pages.count > 1 {
                pageChip
            }
            control(
                symbol: session.state == .running ? "pause.fill" : "play.fill",
                label: session.state == .running ? localized("Pause") : localized("Resume"),
                enabled: session.state == .running || isPaused
            ) {
                session.togglePlayback()
            }
            control(symbol: "tortoise.fill", label: localized("Slower"), value: speedValue,
                    enabled: settings.speed > PromptClock.speedRange.lowerBound) {
                settings.speed -= PromptClock.speedStep
            }
            control(symbol: "hare.fill", label: localized("Faster"), value: speedValue,
                    enabled: settings.speed < PromptClock.speedRange.upperBound) {
                settings.speed += PromptClock.speedStep
            }
            // Ends a session; nothing is lost, so no confirmation and no red
            // (design note).
            control(symbol: "stop.fill", label: localized("Stop"), enabled: true, action: stop)
            Color.clear
                .frame(maxWidth: .infinity)
        }
    }

    private var isPaused: Bool {
        if case .paused = session.state { return true }
        return false
    }

    private var speedValue: String {
        localized("%@ words per second", session.speed.formatted(.number.precision(.fractionLength(0...1))))
    }

    /// The end of a page, said where the eye already is: the countdown to
    /// the next page, or that this was the end (8.6).
    @ViewBuilder
    private var status: some View {
        if session.state == .finished {
            Group {
                if let countdown = session.countdown {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        let seconds = Int((session.countdownRemaining ?? 0).rounded(.up))
                        Text(localized("Next page in %d", max(seconds, 0)))
                    }
                    .id(countdown.endsAt)
                } else {
                    Text(session.hasNextPage ? localized("End of page") : localized("End of script"))
                }
            }
            .islandFont(.caption)
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
        }
    }

    /// "2 / 5". A press goes to the next page (5.2); refused while paused and
    /// on the last page, as the session refuses it.
    private var pageChip: some View {
        Button {
            session.nextPage()
        } label: {
            Text(verbatim: "\(session.pageIndex + 1) / \(session.pages.count)")
                .font(Theme.TypeRole.caption.font().monospacedDigit())
                .padding(.horizontal, 8)
                .frame(minWidth: PrompterStageMetrics.controlSize, minHeight: PrompterStageMetrics.controlSize)
                .background(Capsule().fill(Theme.surface))
                .contentShape(Capsule())
        }
        .buttonStyle(PrompterControlStyle())
        .disabled(!session.hasNextPage || isPaused)
        .help(localized("Next Page"))
        .accessibilityLabel(localized("Next Page"))
        .accessibilityValue(localized("Page %d of %d", session.pageIndex + 1, session.pages.count))
    }

    private func control(
        symbol: String, label: String, value: String = "", enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .islandFont(.caption, weight: .semibold)
                .frame(width: PrompterStageMetrics.controlSize, height: PrompterStageMetrics.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PrompterControlStyle())
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// The stage's controls: quiet at rest, full white the moment they are
/// pressed (the response rule: feedback on the way down, not on release),
/// and visibly unavailable when they are.
private struct PrompterControlStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Color.white : Theme.secondary)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(Theme.contentAnimation, value: configuration.isPressed)
    }
}

// MARK: - Wings

/// The notch row during a session (design note): the capture chip in the
/// left wing and the elapsed time in the right, both at the tertiary level
/// and neither a control.
enum PrompterStageWings {
    /// Spec 11.5 as the setting stands, never as a promise: capture hiding
    /// is honored only by capture apps that honor it, and never by a hardware
    /// mirror.
    static func captureChip(hidden: Bool) -> String {
        hidden ? localized("Hidden from screen sharing") : localized("Visible in screen sharing")
    }
}

/// The left wing: whether the panel is hidden from screen sharing.
struct PrompterCaptureChip: View {
    let hidden: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: hidden ? "eye.slash" : "eye")
                .accessibilityHidden(true)
            Text(PrompterStageWings.captureChip(hidden: hidden))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .islandFont(.caption)
        .foregroundStyle(Theme.tertiary)
        .accessibilityElement(children: .combine)
    }
}

/// The right wing: running time only (ruling 20.4), once a second.
struct PrompterElapsedReadout: View {
    @ObservedObject var session: PrompterSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(formatTime(session.elapsedTime()))
                .font(Theme.TypeRole.caption.font().monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localized("Elapsed time"))
        .accessibilityValue(formatTime(session.elapsedTime()))
    }
}

// MARK: - The shared-display question

/// Spec 11.6, inline and never an alert: the question, an arm-then-confirm
/// Start Anyway (`ConfirmTextButton`, on `ConfirmationArming`), and Cancel.
/// Shown in the Prompter tab's body while a start waits for the answer; no
/// session exists yet, so the rail is still there, and leaving the tab takes
/// the question back (ruling 20.3 #8).
struct PrompterShareQuestion: View {
    let share: PrompterDisplayShare
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(share.message)
                .islandFont(.body)
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                ConfirmTextButton(
                    title: PrompterDisplayShare.confirmTitle,
                    armedTitle: localized("Start Prompter"),
                    action: confirm
                )
                Button(action: cancel) {
                    Text(localized("Cancel"))
                        .islandFont(.caption)
                        .foregroundStyle(Theme.secondary)
                        .frame(minWidth: Theme.minimumHitSize.width, minHeight: Theme.minimumHitSize.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelButtonStyle())
                .accessibilityLabel(localized("Cancel"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
