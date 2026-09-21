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
    /// Sorted once — the panel's language is settled for the life of the
    /// process, and this is read on every render of both menus.
    static let all: [TranslationLanguage] = [
        english, russian, uzbek, kazakh, turkish, ukrainian, german, french,
        spanish, italian, portuguese, arabic, hindi, chinese, japanese, korean,
    ]
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    static func withCode(_ code: String) -> TranslationLanguage? {
        all.first { $0.code == code }
    }
}

/// Which of the offered languages a piece of text is in.
///
/// Apple's recognizer does the heavy lifting and does not know Uzbek at all:
/// Latin Uzbek comes back as Swedish or Indonesian, and Cyrillic Uzbek as
/// Kazakh at full confidence — measured on this Mac on 2026-09-21. So the
/// letters that settle a language go first, then the scripts only one offered
/// language writes, then Uzbek's Latin signs, and only then the recognizer,
/// held to the languages on offer. A word or two is too little for it: it
/// called "Друг" Ukrainian at 0.60 and "Hi" Turkish at 0.65, while real short
/// phrases — "Guten Morgen", "Merci beaucoup" — come back at 0.97 and above.
/// Short text therefore needs that certainty, and without it falls back to the
/// rule this tab always used: Cyrillic is Russian, anything else English.
enum LanguageDetection {
    /// Fewer words than this is too little for the recognizer to be trusted
    /// at its ordinary confidence.
    static let shortTextWords = 3
    static let shortTextConfidence = 0.95
    static let confidence = 0.5

    static func language(of text: String) -> TranslationLanguage {
        let sample = String(text.prefix(400))
        if let certain = byLetters(sample) { return certain }
        if let script = byScript(sample) { return script }
        let hypothesis = recognized(sample)
        // The Latin signs come after the letters because they are weaker
        // evidence, and each gives way to a recognizer sure it is reading
        // English: "four o'clock" has the mark, "the men" has the word.
        let confidentlyEnglish = hypothesis?.language == .english && (hypothesis?.confidence ?? 0) >= 0.8
        let lower = sample.lowercased()
        if !confidentlyEnglish {
            let marks = uzbekDigraphCount(sample)
            let words = uzbekWordCount(lower)
            let turkish = lower.contains(where: { "çşğıöü".contains($0) })
            if marks >= 2 || (marks == 1 && words >= 1) { return .uzbek }
            if words >= 2, !turkish { return .uzbek }
            // One word is enough when it could only be Uzbek: "salom" alone
            // used to fall through to the English fallback and come back as
            // itself, which is most of what a person types to try the tab.
            if unmistakablyUzbekWordCount(lower) >= 1, !turkish { return .uzbek }
        }
        let words = sample.split { !$0.isLetter }.count
        let needed = words < shortTextWords ? shortTextConfidence : confidence
        if let hypothesis, hypothesis.confidence >= needed { return hypothesis.language }
        return containsCyrillic(sample) ? .russian : .english
    }

    /// Letters that settle it on their own.
    ///
    /// Cyrillic Uzbek writes ў and ҳ, which no other language on offer does;
    /// Kazakh writes ә ө ү ұ ң һ, which Uzbek does not. Қ and ғ are shared by
    /// the two, and there і and ы decide: Kazakh writes both constantly, and
    /// Uzbek Cyrillic has neither ("Сіз қалайсыз?" is Kazakh, "Қаерга
    /// борасиз?" Uzbek). І alone is also Ukrainian, so without қ or ғ it
    /// decides nothing — the recognizer tells those two apart well.
    static func byLetters(_ text: String) -> TranslationLanguage? {
        let lower = text.lowercased()
        if lower.contains(where: { "әөүұңһ".contains($0) }) { return .kazakh }
        if lower.contains(where: { "ўҳ".contains($0) }) { return .uzbek }
        if lower.contains(where: { "қғ".contains($0) }) {
            return lower.contains(where: { "іы".contains($0) }) ? .kazakh : .uzbek
        }
        return nil
    }

    /// Scripts only one offered language writes, which settle it at any
    /// length — a two-character greeting included, where the recognizer is
    /// least sure. Kana means Japanese even beside kanji; Han alone, Chinese.
    static func byScript(_ text: String) -> TranslationLanguage? {
        var kana = false, hangul = false, han = false, arabic = false, devanagari = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: kana = true
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul = true
            case 0x3400...0x4DBF, 0x4E00...0x9FFF: han = true
            case 0x0600...0x06FF, 0x0750...0x077F: arabic = true
            case 0x0900...0x097F: devanagari = true
            default: break
            }
        }
        if kana { return .japanese }
        if hangul { return .korean }
        if han { return .chinese }
        if arabic { return .arabic }
        if devanagari { return .hindi }
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
        Set(words(of: lower)).intersection(uzbekWords).count
    }

    /// The subset no offered language also writes as a word of its own —
    /// unlike "men", "ham" or "sen", which English and Turkish do.
    private static let unmistakablyUzbekWords: Set<String> = [
        "salom", "assalomu", "alaykum", "rahmat", "raxmat", "yaxshi", "yaxshimisiz",
        "qalaysiz", "qalaysan", "qalay", "xayr", "iltimos", "kerak", "qanday",
        "qayerda", "qachon", "ertaga", "bugun", "kecha", "sizning", "mening",
        "uchun", "bilan", "emas", "lekin", "juda", "bormi", "yoʻq", "yo'q",
        "xush", "kelibsiz",
    ]

    private static func unmistakablyUzbekWordCount(_ lower: String) -> Int {
        Set(words(of: lower)).intersection(unmistakablyUzbekWords).count
    }

    private static func words(of lower: String) -> [String] {
        lower.split { !$0.isLetter && !apostrophes.contains($0) }.map(String.init)
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
