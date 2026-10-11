import AppKit
import SwiftUI

/// The Prompter's tab (spec 5.1, plan T10, the T7 design note): the script,
/// its pages, the page's text, and one control that starts a session.
///
/// Thin on purpose. What each press does, which message a limit leaves on
/// which control, when Start is available and why not, and how tall each row
/// is are decided by `PrompterTabModel` and `PrompterTabMetrics` and tested
/// there; this view draws them. Every row has its height from the metrics, so
/// the stack cannot outgrow the 208 pt body, and the editor takes what is
/// left.
///
/// The panel becomes key only while a tab `needsKeyboard`, and the editing
/// keys (⌘A, X, C, V, Z) reach the text view through `NotchPanel.sendEvent`
/// for any text view, so the editor needs nothing of its own for them: this
/// is the same plain `TextEditor` the Translate tab types into, with the same
/// I-beam rectangle reported up for the panel's cursor.
struct PrompterTab: View {
    @ObservedObject var model: PrompterTabModel
    /// Observed as well as held by the model: the model computes from the
    /// library, but only an observed object redraws the view when it changes.
    @ObservedObject var library: PrompterLibrary
    @ObservedObject var session: PrompterSession
    @ObservedObject var settings: PrompterSettings
    /// Script text is covered like a clipboard row (`PrivacyMode.Section.prompter`).
    @ObservedObject var privacy: PrivacyMode
    /// A big script is being tokenized: Start waits with a stated reason.
    let isPreparing: Bool
    /// The Hide from Screen Sharing setting, as `NotchViewModel` reads it.
    let captureHidden: Bool
    let start: () -> Void
    let resume: () -> Void
    let openSettings: () -> Void
    @Binding var wantsKeyboard: Bool

    /// The one reveal id for the tab: uncovering the editor uncovers the
    /// titles with it, since one without the other hides nothing.
    static let revealID = "prompter.script"

    @FocusState private var editorFocused: Bool
    @FocusState private var renameFocused: Bool
    @State private var selection: TextSelection?
    @State private var renaming = false
    @State private var draftTitle = ""

    private var covered: Bool {
        privacy.hides(.prompter, Self.revealID) && !model.pageText.isEmpty
    }

    private var titlesCovered: Bool {
        privacy.hides(.prompter, Self.revealID)
    }

    private var availability: PrompterStartAvailability {
        model.startAvailability(isPreparing: isPreparing)
    }

    var body: some View {
        Group {
            if let notice = model.notice, notice.blocksTheTab {
                PrompterLibraryAlert(notice: notice, model: model)
            } else if model.script == nil {
                emptyState
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            model.prepare()
            editorFocused = wantsKeyboard
        }
        .onChange(of: wantsKeyboard) { _, wants in editorFocused = wants && !renaming }
        .onChange(of: model.inlineError) { _, error in
            // Said once, when it appears: the message is drawn on a quiet
            // line a screen reader would not otherwise visit.
            if let error { Announcer.shared.announce(error.message) }
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: PrompterTabMetrics.rowGap) {
            scriptRow
                .frame(height: PrompterTabMetrics.scriptRowHeight)
            chipRow
                .frame(height: PrompterTabMetrics.chipRowHeight)
            editor
                .frame(maxWidth: .infinity, minHeight: PrompterTabMetrics.minimumEditorHeight, maxHeight: .infinity)
            quietLine
                .frame(height: PrompterTabMetrics.quietLineHeight)
            controlRow
                .frame(height: PrompterTabMetrics.controlRowHeight)
        }
    }

    // MARK: - Script row

    private var scriptRow: some View {
        HStack(spacing: 6) {
            if renaming {
                TextField(localized("Script"), text: $draftTitle)
                    .textFieldStyle(.plain)
                    .islandFont(.subhead, weight: .semibold)
                    .foregroundStyle(.white)
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onChange(of: renameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
                    .accessibilityLabel(localized("Rename Script"))
            } else {
                scriptMenu
            }
            Spacer(minLength: 4)
            Button { model.addScript() } label: {
                Image(systemName: "plus")
                    .islandFont(.caption, weight: .semibold)
                    .foregroundStyle(failed(.newScript) ? Theme.danger : Theme.secondary)
                    .frame(width: PrompterTabMetrics.addButtonWidth, height: PrompterTabMetrics.scriptRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PanelButtonStyle())
            .disabled(!model.canEdit)
            .help(localized("New Script"))
            .accessibilityLabel(localized("New Script"))
            ConfirmTextButton(
                title: localized("Delete Script"),
                armedTitle: localized("Delete This Script")
            ) { model.deleteScript() }
                .disabled(!model.canEdit)
        }
    }

    private var scriptMenu: some View {
        Menu {
            ForEach(Array(library.scripts.enumerated()), id: \.element.id) { position, record in
                Toggle(
                    PrompterTabModel.displayTitle(record, position: position, covered: titlesCovered),
                    isOn: Binding(
                        get: { record.id == model.script?.id },
                        set: { if $0 { model.selectScript(record.id) } }
                    )
                )
            }
            Divider()
            Button(localized("New Script")) { model.addScript() }
            Button(localized("Rename Script")) { beginRename() }
            Button(localized("Duplicate Script")) { model.duplicateScript() }
        } label: {
            let title = currentTitle
            // One `Text`, the chevron an image inside it, as the Translate
            // headings are: two elements in a menu's label became two menu
            // buttons for VoiceOver.
            (Text(title) + Text(" ") + Text(Image(systemName: "chevron.down")).font(.system(size: 7, weight: .bold)))
                .islandFont(.subhead, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.white)
                .frame(minHeight: PrompterTabMetrics.scriptRowHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(PanelButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(library.scripts.isEmpty)
        .accessibilityLabel(localized("Scripts"))
        .accessibilityValue(model.script.map { $0.title } ?? "")
    }

    private var currentTitle: String {
        guard let record = model.script else { return localized("Script") }
        let position = library.scripts.firstIndex { $0.id == record.id } ?? 0
        return PrompterTabModel.displayTitle(record, position: position, covered: titlesCovered)
    }

    private func beginRename() {
        draftTitle = model.script?.title ?? ""
        renaming = true
        renameFocused = true
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        model.renameScript(draftTitle)
        editorFocused = wantsKeyboard
    }

    private func failed(_ target: PrompterInlineError.Target) -> Bool {
        model.inlineError?.target == target
    }

    // MARK: - Page chips

    private var chipRow: some View {
        HStack(spacing: PrompterTabMetrics.chipRowGap) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: PrompterTabMetrics.chipSpacing) {
                        ForEach(model.pages.indices, id: \.self) { index in
                            chip(index)
                                .id(index)
                        }
                    }
                }
                // The selected chip is scrolled to, so a page picked by the
                // add button or by a delete is never off the end of a strip.
                .onChange(of: model.page) { _, page in
                    withAnimation(Theme.contentAnimation) { proxy.scrollTo(page, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(model.page, anchor: .center) }
            }
            Button { model.addPage() } label: {
                Image(systemName: "plus")
                    .islandFont(.caption, weight: .semibold)
                    .foregroundStyle(failed(.addPage) ? Theme.danger : Theme.secondary)
                    .frame(width: PrompterTabMetrics.addButtonWidth, height: PrompterTabMetrics.chipHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PanelButtonStyle())
            .disabled(!model.canEdit)
            .help(localized("Add Page"))
            .accessibilityLabel(localized("Add Page"))
            .accessibilityHint(model.inlineError.flatMap { $0.target == .addPage ? $0.message : nil } ?? "")
            deletePage
        }
    }

    @ViewBuilder
    private var deletePage: some View {
        if model.canDeletePage {
            if model.deletionNeedsConfirmation(page: model.page) {
                ConfirmTextButton(
                    title: localized("Delete Page"),
                    armedTitle: localized("Delete This Page")
                ) { model.deletePage(model.page) }
            } else {
                Button { model.deletePage(model.page) } label: {
                    Text(localized("Delete Page"))
                        .islandFont(.caption)
                        .foregroundStyle(Theme.secondary)
                        .frame(minWidth: Theme.minimumHitSize.width, minHeight: Theme.minimumHitSize.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PanelButtonStyle())
            }
        }
    }

    private func chip(_ index: Int) -> some View {
        let selected = index == model.page
        let read = model.readMarks.contains(index)
        let count = model.pages.count
        return Button { model.selectPage(index) } label: {
            HStack(spacing: 2) {
                Text(verbatim: "\(index + 1)")
                    .monospacedDigit()
                if read {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .islandFont(.caption, weight: .semibold)
            .foregroundStyle(selected ? Color.white : Theme.secondary)
            .frame(width: PrompterTabMetrics.chipWidth(index: index, read: read), height: PrompterTabMetrics.chipHeight)
            .background(Capsule().fill(selected ? Theme.selectedChip : Theme.surface))
            .overlay(Capsule().strokeBorder(selected ? Theme.selectedChipBorder : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PanelButtonStyle())
        .accessibilityLabel(localized("Page %d of %d", index + 1, count))
        .accessibilityValue(read ? localized("Read") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text(localized("Move Earlier"))) { model.movePage(from: index, to: index - 1) }
        .accessibilityAction(named: Text(localized("Move Later"))) { model.movePage(from: index, to: index + 1) }
        // Reordering is a drag of one chip onto another. The payload names
        // its script, so a chip dragged out of another script (or out of the
        // panel altogether) lands on nothing.
        .draggable(Self.dragToken(script: model.script?.id, index: index))
        .dropDestination(for: String.self) { items, _ in
            guard let from = Self.dragSource(items.first, script: model.script?.id) else { return false }
            model.movePage(from: from, to: index)
            return true
        }
    }

    private static let dragPrefix = "isla.prompter.page:"

    static func dragToken(script: UUID?, index: Int) -> String {
        "\(dragPrefix)\(script?.uuidString ?? ""):\(index)"
    }

    static func dragSource(_ token: String?, script: UUID?) -> Int? {
        guard let token, let script, token.hasPrefix(dragPrefix) else { return nil }
        let parts = token.dropFirst(dragPrefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == script.uuidString else { return nil }
        return Int(parts[1])
    }

    // MARK: - Editor

    private struct EditorIdentity: Hashable {
        let script: UUID?
        let page: Int
        let revision: Int
    }

    private var editor: some View {
        let identity = EditorIdentity(script: model.script?.id, page: model.page, revision: model.revision)
        return TextEditor(text: textBinding, selection: $selection)
            // Transparent rather than removed while covered: the editor has to
            // stay in the tree to keep the keyboard focus, so the first
            // keystroke lands here and uncovers what it typed.
            .opacity(covered ? 0 : 1)
            .textEditorStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .tint(Theme.secondary)
            .focused($editorFocused)
            .disabled(!model.canEdit)
            // Recreated after a refused edit and on every page change, so it
            // shows the text the library kept and starts at the caret that
            // page remembers.
            .id(identity)
            .task(id: identity) { restoreSelection() }
            .onChange(of: selection) { _, new in recordSelection(new) }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if covered {
                    dust
                } else if model.pageText.isEmpty {
                    Text(localized("Type or paste text"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .glassSurface(cornerRadius: 8, elevation: .card, samplesBackdrop: false)
            // Where the field is, for the panel's cursor: the panel is never
            // key outside a typing tab, so AppKit's own I-beam does not apply
            // and the root view needs the rectangle (PTR-02). A background
            // layer so that reading it cannot feed back into layout.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: TextInputRectKey.self, value: proxy.frame(in: .global))
                }
            )
            .accessibilityLabel(localized("Script text"))
    }

    /// Keystrokes uncover the editor, as in Translate: the cover is against a
    /// passing camera, not the person typing.
    private var textBinding: Binding<String> {
        Binding(
            get: { model.pageText },
            set: { new in
                guard new != model.pageText else { return }
                if privacy.covers(.prompter) { privacy.reveal(Self.revealID) }
                model.setText(new)
            }
        )
    }

    private var dust: some View {
        SpoilerField(seed: 0x9E3779B97F4A7C15)
            .contentShape(Rectangle())
            .onTapGesture { privacy.reveal(Self.revealID) }
            .accessibilityElement()
            .accessibilityLabel(Text(localized("Hidden")))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { privacy.reveal(Self.revealID) }
    }

    private func restoreSelection() {
        let text = model.pageText
        guard let saved = model.restoredSelection, let range = Range(saved, in: text) else {
            selection = nil
            return
        }
        selection = TextSelection(range: range)
    }

    private func recordSelection(_ selection: TextSelection?) {
        guard let selection else { return }
        let text = model.pageText
        switch selection.indices {
        case .selection(let range):
            model.recordSelection(NSRange(range, in: text))
        case .multiSelection:
            return
        @unknown default:
            return
        }
    }

    // MARK: - Quiet line

    /// The one message there is: a refused edit on its control, or a failed
    /// save. One line, alone, so nothing is truncated to make room for it.
    private var message: String? {
        if let error = model.inlineError { return error.message }
        if let notice = model.notice, !notice.blocksTheTab { return notice.title }
        return nil
    }

    private var quietLine: some View {
        HStack(spacing: PrompterTabMetrics.quietLineGap) {
            if let message {
                Text(message)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .help(message)
            } else {
                Text(quietText)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: PrompterTabMetrics.quietLineGap)
                captureChip
                    .layoutPriority(1)
            }
        }
        .islandFont(.caption)
    }

    /// Why Start is dim, else the first-run hint, else the count and the
    /// time the page takes at the current speed.
    private var quietText: String {
        if let reason = availability.reason { return reason }
        if model.showsFirstRunHint { return localized("This is a sample. Edit it or add a script of your own.") }
        // A covered page shows no figure: the count says how long the secret is.
        if covered { return "" }
        return PrompterTabModel.stats(for: model.pageText, speed: settings.speed).line
    }

    @ViewBuilder
    private var captureChip: some View {
        let chip = PrompterTabModel.captureChip(hidden: captureHidden)
        let label = HStack(spacing: 4) {
            Image(systemName: chip.symbol)
                .frame(width: PrompterTabMetrics.chipIconWidth)
                .accessibilityHidden(true)
            Text(chip.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(Theme.tertiary)
        if chip.opensSettings {
            Button(action: openSettings) { label }
                .buttonStyle(PanelButtonStyle())
                .help(chip.caveat)
                .accessibilityHint(chip.caveat)
        } else {
            label
                .help(chip.caveat)
                .accessibilityElement(children: .combine)
                .accessibilityHint(chip.caveat)
        }
    }

    // MARK: - Control row

    private var controlRow: some View {
        HStack(spacing: PrompterTabMetrics.controlGap) {
            speedStepper
            Spacer(minLength: 0)
            startButton
        }
    }

    private var speedStepper: some View {
        let speed = settings.speed
        return HStack(spacing: 0) {
            stepControl("minus", label: localized("Slower"), by: -1, speed: speed)
            Text(localized("%@ words/s", String(format: "%.1f", speed)))
                .islandFont(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: PrompterTabMetrics.stepperWidth - 2 * PrompterTabMetrics.addButtonWidth)
                .accessibilityLabel(localized("%@ words per second", String(format: "%.1f", speed)))
            stepControl("plus", label: localized("Faster"), by: 1, speed: speed)
        }
        .frame(width: PrompterTabMetrics.stepperWidth)
        .accessibilityElement(children: .contain)
    }

    private func stepControl(_ symbol: String, label: String, by steps: Int, speed: Double) -> some View {
        Button { settings.speed = PrompterTabModel.steppedSpeed(speed, by: steps) } label: {
            Image(systemName: symbol)
                .islandFont(.caption, weight: .semibold)
                .foregroundStyle(Theme.secondary)
                .frame(width: PrompterTabMetrics.addButtonWidth, height: PrompterTabMetrics.controlRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelButtonStyle())
        .disabled(!PrompterTabModel.canStep(speed, by: steps))
        .opacity(PrompterTabModel.canStep(speed, by: steps) ? 1 : 0.4)
        .help(label)
        .accessibilityLabel(label)
    }

    private var startButton: some View {
        let state = availability
        return Button {
            if state == .resume { resume() } else { start() }
        } label: {
            // Fixed size: the word is never truncated, whatever the language;
            // the gap beside it is what gives way.
            Text(state.label)
                .fixedSize()
        }
        .buttonStyle(OfferButtonStyle(fill: Theme.surfaceHover, horizontalPadding: PrompterTabMetrics.startHorizontalPadding))
        .disabled(!state.isEnabled)
        .opacity(state.isEnabled ? 1 : 0.4)
        .layoutPriority(1)
        .help(state.reason ?? "")
        .accessibilityHint(state.reason ?? "")
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(localized("Write or paste a script to read from the island."))
                .islandFont(.body)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: PrompterTabMetrics.alertTextWidth)
            Button(localized("Add a Script")) { model.addScript() }
                .buttonStyle(OfferButtonStyle())
                .disabled(!model.canEdit)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Library alert

/// An unreadable or newer library, in place of the tab (spec 12.1, 14.4: a
/// section-scope failure is an inline alert, never a toast as well). Nothing
/// in the tab could be saved while it stands.
struct PrompterLibraryAlert: View {
    let notice: PrompterLibraryNotice
    @ObservedObject var model: PrompterTabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.danger)
                    .accessibilityHidden(true)
                Text(notice.title)
                    .foregroundStyle(.white)
            }
            .islandFont(.subhead, weight: .semibold)
            .frame(height: 16)
            // A refused Start a New Library says why in the explanation's
            // place, so the block keeps its height (ruling 20.6 #4).
            Text(model.newLibraryRefusal ?? notice.detail)
                .islandFont(.body)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: PrompterTabMetrics.alertTextWidth, height: PrompterTabMetrics.alertDetailHeight, alignment: .topLeading)
            if notice.offersNewLibrary {
                HStack(spacing: 8) {
                    Button(localized("Reveal in Finder")) { reveal() }
                        .buttonStyle(OfferButtonStyle())
                    ConfirmTextButton(
                        title: localized("Start a New Library"),
                        armedTitle: localized("Replace With a New Library")
                    ) { model.startNewLibrary() }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .onChange(of: model.newLibraryRefusal) { _, refusal in
            if let refusal { Announcer.shared.announce(refusal) }
        }
    }

    /// The copy, or the original file when no copy could be made.
    private func reveal() {
        guard case .unreadable(let copy) = notice else { return }
        let url = PrompterTabModel.revealTarget(corruptCopy: copy, directory: FilePrompterFileIO.live.directory)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
