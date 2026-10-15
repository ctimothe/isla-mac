import SwiftUI

/// The Translate header's trailing tools (redesign 2026-10-15, spec §11):
/// **History** (`clock.arrow.circlepath`, on the selected fill while the list is
/// up) at (`bw − 67`, 8), and Expand / Collapse at (`bw − 39`, 8).
///
/// Laid over the header strip after its accessibility element, as the lyric tools,
/// the Shelf's Expand and the Clipboard's tools are (`ExpandHeaderTool`): an
/// inline control would be swallowed by the strip's `.ignore` and unreachable to
/// VoiceOver, and each is placed by its own offset so the rest of the strip keeps
/// its click-to-close. History is there only while Keep History is on — it is off
/// by default, and a person who never asked to be remembered is not offered a
/// list — and Expand never moves for it.
struct TranslateHeaderTools: ViewModifier {
    let isShown: Bool
    let bodyWidth: CGFloat
    /// Keep History, observed: the Settings row writes this key and the header
    /// follows it live. It was read from `UserDefaults` inside the parent's
    /// `body`, which nothing re-evaluates when a switch in another tab flips, so
    /// History stayed hidden (or stayed offered) until something else redrew the
    /// panel. Read through the translator's own defaults, like the pane's.
    @AppStorage private var keepHistory: Bool
    @Binding var isHistoryOpen: Bool
    @Binding var isExpanded: Bool

    init(
        isShown: Bool, bodyWidth: CGFloat, defaults: UserDefaults,
        isHistoryOpen: Binding<Bool>, isExpanded: Binding<Bool>
    ) {
        self.isShown = isShown
        self.bodyWidth = bodyWidth
        _keepHistory = AppStorage(wrappedValue: false, NotchViewModel.translateKeepHistoryKey, store: defaults)
        _isHistoryOpen = isHistoryOpen
        _isExpanded = isExpanded
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if isShown, TranslateHeader.showsHistory(keepHistory: keepHistory) {
                    HeaderIconButton(
                        symbol: "clock.arrow.circlepath", label: localized("History"), isOn: isHistoryOpen
                    ) { isHistoryOpen.toggle() }
                    .offset(x: TranslateHeader.history(bodyWidth: bodyWidth).minX, y: HeaderToolFrames.top)
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if isShown {
                    ExpandCollapseButton(isExpanded: $isExpanded)
                        .offset(x: HeaderToolFrames.expand(bodyWidth: bodyWidth).minX, y: HeaderToolFrames.top)
                        .transition(.opacity)
                }
            }
    }
}
