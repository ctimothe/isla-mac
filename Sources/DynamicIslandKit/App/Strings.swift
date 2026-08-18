import Foundation

/// Looks a string up in the app's own tables.
///
/// SwiftUI's `Text` localises string literals by itself, so views mostly need
/// nothing. This is for the places that need a `String` before it reaches a
/// view: menu titles, tooltips, messages assembled with a value in them.
///
/// The keys are the English text. A missing table then degrades to English
/// rather than to a bare identifier — which matters when running straight from
/// SwiftPM, where the `.lproj` folders are not around at all.
func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// The same, with values filled in.
func localized(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}

/// The language the app actually ended up in, which is not the same as the
/// system's: macOS picks the first of the user's preferred languages that this
/// bundle happens to carry. Everything the app formats for itself — a weekday
/// name, the name of a language — has to follow that choice, or the panel ends
/// up half in one language and half in another.
var appLanguage: String {
    Bundle.main.preferredLocalizations.first ?? "en"
}

extension String {
    /// First character upper-cased, the rest left alone.
    ///
    /// A label starts with a capital in both languages, but the words it starts
    /// with may not carry one: English weekday and month names are proper nouns
    /// and come out of a formatter capitalised wherever they stand, Russian ones
    /// are ordinary words and come out lower-case. So "Friday, 7 August" needs
    /// nothing and "пятница, 7 августа" needs a capital — same position, same
    /// rule, different starting material. The capital belongs to the position,
    /// not to the word, which is why it is applied where the label is built and
    /// not written into the translations.
    ///
    /// Not `capitalized`: that upper-cases every word and would give
    /// "Пятница, 7 Августа".
    var sentenceCased: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
