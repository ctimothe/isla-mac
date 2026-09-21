import Foundation
import NaturalLanguage

/// A language the Translate tab offers.
///
/// A short, deliberate list rather than every locale Foundation knows: the
/// languages people around this Mac actually move between, each one something
/// at least one engine here can really translate. It was English and Russian
/// only, decided by script, until the owner asked on 2026-09-21 for a choice
/// of languages, a swap, and Uzbek.
struct TranslationLanguage: Hashable, Identifiable, Sendable {
    /// BCP 47, as the Translation framework and the language model take it.
    let code: String
    var id: String { code }

    var locale: Locale.Language { Locale.Language(identifier: code) }

    /// The two-letter code alone — what language detection and the online
    /// service speak, and what "is this the same language" is decided on.
    var baseCode: String { String(code.prefix { $0 != "-" }) }

    /// "English", "Узбекский" — named in the panel's own language, not the
    /// system's, so a header never reads in one language above a button worded
    /// in another.
    var name: String { Self.name(forCode: baseCode, in: appLanguage) }

    /// Always in English, for the one reader that is not a person: the
    /// on-device model's instructions are written in English, and a language
    /// named to it in Russian is one more thing for it to misread.
    var englishName: String { Self.name(forCode: baseCode, in: "en") }

    private static func name(forCode code: String, in language: String) -> String {
        guard let name = Locale(identifier: language).localizedString(forLanguageCode: code) else {
            return code.uppercased()
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static let english = TranslationLanguage(code: "en")
    static let russian = TranslationLanguage(code: "ru")
    static let uzbek = TranslationLanguage(code: "uz")
    static let kazakh = TranslationLanguage(code: "kk")
    static let turkish = TranslationLanguage(code: "tr")
    static let ukrainian = TranslationLanguage(code: "uk")
    static let german = TranslationLanguage(code: "de")
    static let french = TranslationLanguage(code: "fr")
    static let spanish = TranslationLanguage(code: "es")
    static let italian = TranslationLanguage(code: "it")
    static let portuguese = TranslationLanguage(code: "pt")
    static let arabic = TranslationLanguage(code: "ar")
    static let hindi = TranslationLanguage(code: "hi")
    static let chinese = TranslationLanguage(code: "zh-Hans")
    static let japanese = TranslationLanguage(code: "ja")
    static let korean = TranslationLanguage(code: "ko")

    /// Every language on offer, in the order the menus list them: the panel's
    /// alphabet, so the list reads the way the reader's own language sorts.
    static var all: [TranslationLanguage] {
        [
            english, russian, uzbek, kazakh, turkish, ukrainian, german, french,
            spanish, italian, portuguese, arabic, hindi, chinese, japanese, korean,
        ]
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func withCode(_ code: String) -> TranslationLanguage? {
        all.first { $0.code == code }
    }
}

/// Which of the offered languages a piece of text is in.
///
/// Apple's recognizer does the heavy lifting and does not know Uzbek at all:
/// Latin Uzbek comes back as Swedish or Indonesian, and Cyrillic Uzbek as
/// Russian — measured on this Mac on 2026-09-21. Uzbek is therefore recognised
/// first, by what only Uzbek writes; everything else goes to the recognizer,
/// held to the languages on offer; and text too short to call falls back to
/// the rule this tab always used — Cyrillic is Russian, anything else English.
enum LanguageDetection {
    static func language(of text: String) -> TranslationLanguage {
        let sample = String(text.prefix(400))
        if let certain = byLetters(sample) { return certain }
        let hypothesis = recognized(sample)
        // The Latin signs come after the letters because they are weaker
        // evidence, and each gives way to a recognizer sure it is reading
        // English: "four o'clock" has the mark, "the men" has the word.
        let confidentlyEnglish = hypothesis?.language == .english && (hypothesis?.confidence ?? 0) >= 0.8
        let lower = sample.lowercased()
        if !confidentlyEnglish {
            let marks = uzbekDigraphCount(sample)
            let words = uzbekWordCount(lower)
            if marks >= 2 || (marks == 1 && words >= 1) { return .uzbek }
            if words >= 2, !lower.contains(where: { "çşğıöü".contains($0) }) { return .uzbek }
        }
        if let hypothesis, hypothesis.confidence >= 0.5 { return hypothesis.language }
        return containsCyrillic(sample) ? .russian : .english
    }

    /// Letters that settle it on their own.
    ///
    /// Cyrillic Uzbek writes ў and ҳ, which no other language on offer does;
    /// Kazakh writes ә ө ү ұ ң һ, which Uzbek does not. Қ and ғ are shared by
    /// the two, so they count as Uzbek only when nothing Kazakh is present. І
    /// is Kazakh *and* Ukrainian, so it decides nothing on its own — the
    /// recognizer tells those two apart well.
    static func byLetters(_ text: String) -> TranslationLanguage? {
        let lower = text.lowercased()
        if lower.contains(where: { "әөүұңһ".contains($0) }) { return .kazakh }
        if lower.contains(where: { "ўҳқғ".contains($0) }) { return .uzbek }
        return nil
    }

    private static let apostrophes: Set<Character> = ["'", "‘", "’", "ʻ", "ʼ", "`"]

    /// Latin Uzbek's o‘ and g‘ before a letter — "yo'q", "bo'ladi", "g'alaba" —
    /// with whatever apostrophe the keyboard had. Read from the text as typed:
    /// an O' before a capital is a surname (O'Brien, O'Neil), not a letter of
    /// Uzbek, and o'clock is English wherever it stands.
    private static func uzbekDigraphCount(_ text: String) -> Int {
        let characters = Array(text)
        guard characters.count >= 3 else { return 0 }
        var count = 0
        for index in 0..<(characters.count - 2)
        where (characters[index].lowercased() == "o" || characters[index].lowercased() == "g")
            && apostrophes.contains(characters[index + 1])
            && characters[index + 2].isLetter {
            let wordStart = index == 0 || !characters[index - 1].isLetter
            if wordStart, characters[index + 2].isUppercase { continue }
            let rest = String(characters[index...].prefix(7)).lowercased()
            if rest.hasPrefix("o'clock") || rest.hasPrefix("o’clock") { continue }
            count += 1
        }
        return count
    }

    /// Everyday Uzbek words that do not also read as English or Turkish words.
    private static let uzbekWords: Set<String> = [
        "va", "men", "sen", "siz", "ular", "uchun", "bilan", "emas", "edi",
        "qanday", "nima", "nega", "yaxshi", "rahmat", "salom", "kerak", "lekin",
        "juda", "endi", "qachon", "qayerda", "bugun", "ertaga", "kecha", "mening",
        "sizning", "xayr", "iltimos", "ham", "shu", "qilish", "boraman", "uyga",
        "ishga", "havo", "bormi", "yoʻq", "yo'q",
    ]

    private static func uzbekWordCount(_ lower: String) -> Int {
        let words = lower.split { !$0.isLetter && !apostrophes.contains($0) }.map(String.init)
        return Set(words).intersection(uzbekWords).count
    }

    private static func recognized(_ text: String) -> (language: TranslationLanguage, confidence: Double)? {
        let recognizer = NLLanguageRecognizer()
        var constraints: [NLLanguage] = []
        var byLanguage: [NLLanguage: TranslationLanguage] = [:]
        for language in TranslationLanguage.all where language != .uzbek {
            let nl = NLLanguage(rawValue: language == .chinese ? "zh-Hans" : language.baseCode)
            constraints.append(nl)
            byLanguage[nl] = language
        }
        constraints.append(.traditionalChinese)
        byLanguage[.traditionalChinese] = .chinese
        recognizer.languageConstraints = constraints
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              let offered = byLanguage[language] else { return nil }
        return (offered, confidence)
    }

    private static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }
}
