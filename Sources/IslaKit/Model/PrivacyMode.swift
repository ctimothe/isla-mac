import AppKit
import Combine

/// Hides what the panel holds behind a field of drifting dots, for screens that
/// somebody else is watching.
///
/// Chosen per section rather than one switch for everything: the tabs hold
/// different things, and somebody streaming their desk may care about the
/// clipboard and not about their notes, or the other way round. The menu still
/// offers "All" first, because that is the answer most of the time and the one
/// nobody has to think about.
///
/// The choice outlives launches — forgetting to turn covering *on* is what
/// costs something, so it must not depend on remembering.
///
/// Nothing here decides *what* is a secret. Guessing at addresses and card
/// numbers with a regular expression fails silently and tells the user about it
/// only afterwards, on the recording; covering everything in a chosen section
/// is predictable, and predictability is the feature.
@MainActor
final class PrivacyMode: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        /// Translate is here because ⌥⌘T puts the clipboard's contents into it
        /// verbatim. Covering the clipboard tab while leaving the pane that
        /// displays the same text in full view was a hole in the promise the
        /// covers make.
        case clipboard, translate

        var id: String { rawValue }

        /// The tab's own name — the menu and the panel must not disagree about
        /// what a section is called.
        var title: String {
            switch self {
            case .clipboard: return localized("Clipboard")
            case .translate: return localized("Translate")
            }
        }
    }

    static let key = "privacyMode.sections"
    /// What the first version of this stored: one bool for everything. Read
    /// once, so a panel that was already covering keeps covering after an
    /// update instead of quietly opening up.
    static let legacyKey = "privacyMode"

    @Published private(set) var sections: Set<Section>

    /// What the user has uncovered by hand, by row id. Cleared whenever the
    /// panel folds: a row uncovered once must not still be uncovered the next
    /// time the panel opens, which would be exactly when nobody is looking at
    /// it and the camera is.
    @Published private(set) var revealed: Set<String> = []

    private let defaults: UserDefaults

    /// Sections that existed when the stored list was last written. A section
    /// added later cannot be absent from an older list on purpose — nobody was
    /// ever offered it — so "everything that existed then" upgrades to
    /// "everything that exists now" rather than quietly leaving the new one
    /// uncovered. Adding `.translate` without this un-covered every user who
    /// had chosen to cover everything.
    private static let knownSectionsKey = "privacyKnownSections"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.array(forKey: Self.key) as? [String] {
            var restored = Set(stored.compactMap(Section.init(rawValue:)))
            let known = Set(defaults.array(forKey: Self.knownSectionsKey) as? [String] ?? [])
            let existed = Set(Section.allCases.map(\.rawValue)).intersection(known.isEmpty ? Set(stored) : known)
            // Covered everything that was on offer at the time: keep it that way.
            if !restored.isEmpty, restored.count == existed.count {
                restored = Set(Section.allCases)
            }
            sections = restored
        } else if defaults.bool(forKey: Self.legacyKey) {
            sections = Set(Section.allCases)
        } else {
            sections = []
        }
        defaults.set(Section.allCases.map(\.rawValue).sorted(), forKey: Self.knownSectionsKey)
    }

    // MARK: - Sections

    /// Whether this section covers its contents at all — also what decides if
    /// the eye is offered on its rows.
    func covers(_ section: Section) -> Bool {
        sections.contains(section)
    }

    var coversAll: Bool { sections.count == Section.allCases.count }
    var coversAny: Bool { !sections.isEmpty }

    func setCovering(_ section: Section, _ on: Bool) {
        if on { sections.insert(section) } else { sections.remove(section) }
        persist()
    }

    func setCoveringAll(_ on: Bool) {
        sections = on ? Set(Section.allCases) : []
        persist()
    }

    private func persist() {
        defaults.set(sections.map(\.rawValue).sorted(), forKey: Self.key)
        // Kept in step so that rolling back to an older build finds the switch
        // where it left it, rather than off.
        defaults.set(coversAny, forKey: Self.legacyKey)
        if !coversAny { revealed.removeAll() }
    }

    // MARK: - Rows

    /// True when this particular row has to be covered right now.
    func hides(_ section: Section, _ id: String) -> Bool {
        covers(section) && !revealed.contains(id)
    }

    func reveal(_ id: String) {
        revealed.insert(id)
    }

    func toggle(_ id: String) {
        if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
    }

    /// Back to covered — called when the panel folds.
    func coverEverything() {
        guard !revealed.isEmpty else { return }
        revealed.removeAll()
    }
}
