import SwiftUI

/// The pressed state `.plain` does not give.
///
/// Apple's rule is feedback on press-down, not on release: a control that
/// shows nothing until the click is let go feels dead for the length of the
/// press. `.buttonStyle(PanelButtonStyle())` on macOS leaves a custom label untouched while
/// it is held, so every plain button in the panel — rows, chips, glyphs, the
/// rail — went through the press with no answer. This dims the label the same
/// way `NotchButtonStyle` and `TransportGlyphStyle` already do, so one press
/// looks like one press everywhere.
struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(Theme.contentAnimation, value: configuration.isPressed)
    }
}

/// The toolbar push button (spec §2.2): a word on a 0.14 white plate, 22 tall,
/// radius 6, 10 pt either side — the Shelf's bar, and Translate's in R4.
///
/// Text only, as the push buttons in a Finder window's bottom bar are: with a
/// glyph beside each word the Shelf's five verbs ran 40 points into the count
/// (the board's own note). `danger` is for the one confirmation that destroys
/// something — Remove All — and is `Theme.danger` on the same plate; a
/// button that merely removes a selection (decision 9) is the normal kind.
/// Pressed it dims as every panel button does, and disabled it steps back to
/// 0.4 so a verb with nothing to act on reads as such.
struct ToolbarPushButtonStyle: ButtonStyle {
    enum Kind { case normal, danger }
    var kind: Kind = .normal
    /// A square plate (the Shelf's "…" is 22 × 22) instead of one that follows
    /// its word.
    var width: CGFloat? = nil

    static let height: CGFloat = 22
    static let radius: CGFloat = 6
    static let horizontalPadding: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        PlateLabel(configuration: configuration, kind: kind, width: width)
    }

    private struct PlateLabel: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let width: CGFloat?
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .islandFont(.body, weight: .regular)
                .foregroundStyle(kind == .danger ? Theme.danger : Color.white)
                .lineLimit(1)
                .padding(.horizontal, width == nil ? ToolbarPushButtonStyle.horizontalPadding : 0)
                .frame(width: width, height: ToolbarPushButtonStyle.height)
                .background(
                    RoundedRectangle(cornerRadius: ToolbarPushButtonStyle.radius, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                        // The plate's lit top edge: the board draws a half-point
                        // inset highlight, which is what makes a flat grey read
                        // as a button rather than a well.
                        .overlay(alignment: .top) {
                            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: ToolbarPushButtonStyle.radius, style: .continuous))
                )
                .contentShape(RoundedRectangle(cornerRadius: ToolbarPushButtonStyle.radius, style: .continuous))
                .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.4)
                .animation(Theme.contentAnimation, value: configuration.isPressed)
        }
    }
}

/// The panel's one-action pill: a word in a capsule of `Theme.surface` edged
/// with the hairline, dimmed on press the way `PanelButtonStyle` dims.
///
/// It was hand-copied three times — Music's "Open Spotify", the lyrics page's
/// "Look Up Online", the welcome page's "Get Started" — while Translate's
/// remedies, the only way forward from the first error a newcomer meets, were
/// bare bold caption text that did not look clickable at all (H-007). One
/// style now, so an offer looks like an offer wherever it appears.
///
/// The parameters exist so the copies could move onto it without a pixel
/// changing: Music's empty state is 2 pt narrower on each side, and the
/// welcome page's primary sits one step brighter on `Theme.surfaceHover`.
/// A new offer takes the defaults.
struct OfferButtonStyle: ButtonStyle {
    var fill: Color = Theme.surface
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 5
    /// A height of its own, for a row of them the board measures — the empty
    /// player's buttons are 22 tall (spec §4.8). Nil takes the padding's.
    var fixedHeight: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .islandFont(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            // Never a caption-sized target, whatever the word. At the body
            // role and these paddings every label is already larger, so this
            // changes no existing button; it is the floor for a short one.
            .frame(minWidth: Theme.minimumHitSize.width, minHeight: Theme.minimumHitSize.height)
            .frame(height: fixedHeight)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(Theme.contentAnimation, value: configuration.isPressed)
    }
}

/// A Settings row that is one switch: the label across the row, the track at
/// its trailing edge, and the whole of it the target.
///
/// Two things were wrong with `Toggle("", isOn:).toggleStyle(.switch)` and a
/// title beside it. AppKit draws its switch's on-state only in a key window,
/// and the panel is not key outside Translate, so on and off were told apart
/// by the knob's side alone (H-002). And the title was detached, so a click on
/// "Launch at Login" — the words — did nothing; only the 24×14 capsule at the
/// far edge flipped it (owner decision 2). Forcing the panel key to get the
/// active switch back would take the keyboard from whatever app the person is
/// typing in each time the pointer crossed the notch; the drawn switch asks
/// nothing of key status at all.
///
/// To an assistive client the row is still a plain switch: the drawn one is
/// replaced by a native `Toggle`, so VoiceOver reads its title, "switch" and
/// on or off, and its press is the same flip a click makes.
struct PanelSwitchStyle: ToggleStyle {
    /// What a state looks like, apart from any drawing, so the rule — that
    /// colour and edge depend on the state and Increase Contrast and on
    /// nothing else — is something a test can read.
    struct Look: Equatable {
        enum Track: Equatable { case accent, well }
        enum Knob: Equatable { case leading, trailing }
        var track: Track
        var knob: Knob
        var outlineWidth: CGFloat
    }

    static func look(isOn: Bool, increaseContrast: Bool) -> Look {
        Look(
            track: isOn ? .accent : .well,
            knob: isOn ? .trailing : .leading,
            outlineWidth: increaseContrast ? 1 : 0
        )
    }

    /// The row's own height and inset, so the hit target is the row the card
    /// draws rather than the label's text. A height is a floor: Settings' grouped
    /// form wraps a long label (Russian at 480) onto a second line before it
    /// shrinks the switch, so the row grows with its words.
    var rowHeight: CGFloat = 26
    var horizontalInset: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        PanelSwitch(configuration: configuration, rowHeight: rowHeight, horizontalInset: horizontalInset)
    }
}

private struct PanelSwitch: View {
    let configuration: ToggleStyleConfiguration
    let rowHeight: CGFloat
    let horizontalInset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let look = PanelSwitchStyle.look(
            isOn: configuration.isOn, increaseContrast: SystemAppearance.shared.increaseContrast
        )
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                configuration.label
                Spacer(minLength: 8)
                track(look)
            }
            .padding(.horizontal, horizontalInset)
            .frame(minHeight: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        // A plain `Toggle`, not one styled `.switch`: that one is AppKit's
        // NSSwitch again, which the probe found as a 56 pt checkbox with no
        // name beside a separate text, refusing the press. This one is a
        // single AXCheckBox (subrole AXToggle) the width of the row, named by
        // the label and carrying 0 or 1.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }

    private func track(_ look: PanelSwitchStyle.Look) -> some View {
        let size = Theme.switchTrackSize
        let travel = (size.width - size.height) / 2
        return Capsule(style: .continuous)
            .fill(look.track == .accent ? Theme.switchOnFill : Theme.switchOffFill)
            .overlay {
                // The hairline is the off well's edge, the only thing that
                // makes a recess read as a shape; on, the accent is its own.
                // Increase Contrast replaces either with a defined border.
                if look.outlineWidth > 0 {
                    Capsule(style: .continuous)
                        .strokeBorder(Theme.switchContrastOutline, lineWidth: look.outlineWidth)
                } else if look.track == .well {
                    Capsule(style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1)
                }
            }
            .overlay {
                Circle()
                    .fill(Theme.switchKnob)
                    .frame(width: Theme.switchKnobDiameter, height: Theme.switchKnobDiameter)
                    .shadow(color: Theme.switchKnobShadow, radius: 1, y: 0.5)
                    .offset(x: look.knob == .trailing ? travel : -travel)
            }
            .frame(width: size.width, height: size.height)
            // Reduce Motion keeps the change and drops the travel: the knob
            // is simply on the other side.
            .animation(reduceMotion ? nil : Theme.contentAnimation, value: configuration.isOn)
    }
}

/// Flat, focus-free button used for every control in the panel.
struct NotchButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(prominent ? Theme.TypeRole.title.font(weight: .medium) : Theme.TypeRole.subhead.font())
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                Circle().fill(prominent ? Theme.surfaceHover : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.55 : 1)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// One end of a travelling object, when there is a namespace to travel in.
    ///
    /// The namespace is optional because the views that carry these ids are also
    /// rendered on their own — `MediaPane` by the layout tests, with no panel
    /// around it and nothing to travel to. `matchedGeometryEffect` has no
    /// tolerant form: it takes a `Namespace.ID`, not an optional, so the choice
    /// has to be made here rather than at every call site.
    ///
    /// Apply this **inside** the fixed frame that declares the end's size, never
    /// outside it. Outside, the effect proposes the other end's size to a frame
    /// that is already pinned to its own, so the cover moves without ever
    /// growing — a hero animation that silently loses half its job.
    @ViewBuilder
    func morph(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Replaces one SF Symbol with the next whenever `value` changes: the old
    /// glyph shrinks out as the new one grows in, and under Reduce Motion the
    /// two cross-fade.
    ///
    /// This was a symbol content transition, Apple's own replace
    /// (`.replace.downUp`), until the hitch lab found what it cost (2026-10-29).
    /// SwiftUI draws a symbol content transition into an `RBDrawingLayer`,
    /// even `.identity`, and every frame that layer's display waited in
    /// `-[CAContext waitForCommitId:]` for the render server to finish the
    /// frame before: the main thread sat blocked through the effect. The gear
    /// turns into Settings' X in the same transaction that swaps the pane, so
    /// player to Settings missed 27 frames of 125 with lyrics live; with this
    /// transition, 4 (Settings back to the player: 7 to 4). A plain transition on an
    /// image keyed by the value is ordinary layers, and the shape is the
    /// same as the effect's.
    ///
    /// The transition only plays inside an animated transaction; in a plain
    /// one the glyph is simply swapped. Play/pause flips when the player says
    /// so (the helper's stream, a media key) and the Liked Songs heart when
    /// the library answers, both outside any `withAnimation`, so the
    /// most-watched control in the app could hard-cut beside a comment saying
    /// it was replaced (F-046). The repeat toggle animated `isOn`, which stays
    /// true from "all" to "one" while the glyph changes. Carrying the
    /// animation here, on the value that moves the glyph, means a caller
    /// cannot ask for the swap without the transaction that runs it.
    ///
    /// A tint that changes with the same value goes with its glyph. The value
    /// is the view's identity here, so `self` must hold no state of its own:
    /// every caller hands it a bare `Image`. `SymbolSwapLayerTests` holds the
    /// layers; `MotionValuesTests.testEverySymbolSwapCarriesItsAnimation`
    /// keeps the symbol effect out of the sources.
    func symbolSwap<Value: Hashable>(value: Value, reduceMotion: Bool) -> some View {
        ZStack {
            self.id(value)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
        }
        .animation(Theme.contentAnimation, value: value)
    }
}

extension View {
    /// The system font at a size, with the tracking that size actually wants.
    ///
    /// Everything drawn here used `.system(size:weight:)` bare, which takes
    /// Apple's font and leaves its tracking table behind — the one thing that
    /// keeps type looking deliberate as it changes size.
    func islandFont(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight))
            .tracking(Theme.tracking(forSize: size))
    }

    /// The same, by role. An explicit weight wins; left out, the role's own
    /// weight applies — which means a call site that used to say nothing, and
    /// so read as regular, must keep saying `.regular` out loud.
    func islandFont(_ role: Theme.TypeRole, weight: Font.Weight? = nil) -> some View {
        islandFont(role.size, weight: weight ?? role.weight)
    }

    /// Sets a line of text on a baseline `y` below the top of a `.topLeading`
    /// stack: the reference measures an alert's text by its baseline, and a
    /// frame's top would move with the font's ascent.
    func islandBaseline(_ y: CGFloat) -> some View {
        alignmentGuide(.top) { $0[.firstTextBaseline] - y }
    }
}
