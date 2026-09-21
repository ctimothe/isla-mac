import XCTest
@testable import IslaKit

/// Which language text is in, for a source left on Detect.
///
/// Apple's recognizer does not know Uzbek: measured on 2026-09-21, Latin Uzbek
/// came back as Swedish and Indonesian and Cyrillic Uzbek as Russian. These
/// hold the letters-and-words rules that stand in for it, and the English that
/// must not be mistaken for it.
final class LanguageDetectionTests: XCTestCase {
    func testUzbekIsRecognisedInEitherScript() {
        for text in [
            "Men ertaga ertalab ishga boraman.",
            "Bugun havo juda issiq, suv ichishni unutmang.",
            "Yo'q, bu juda qiyin bo'ladi.",
            "Oʻzbekiston goʻzal mamlakat.",
            "Ўзбекистон гўзал мамлакат.",
            "Раҳмат, яхши кўрдим.",
        ] {
            XCTAssertEqual(LanguageDetection.language(of: text), .uzbek, text)
        }
    }

    func testEnglishThatLooksUzbekStaysEnglish() {
        for text in [
            "Tell O'Brien the meeting moved to four o'clock.",
            "The men went home early.",
            "Where is the nearest train station?",
        ] {
            XCTAssertEqual(LanguageDetection.language(of: text), .english, text)
        }
    }

    func testTheNeighboursAreToldApart() {
        XCTAssertEqual(LanguageDetection.language(of: "Сәлем, қалайсың? Бүгін ауа райы жақсы."), .kazakh)
        // Қ and ғ are both Kazakh and Uzbek; і and ы are Kazakh only. The
        // recognizer calls both of these Kazakh at 1.00.
        XCTAssertEqual(LanguageDetection.language(of: "Сіз қалайсыз?"), .kazakh)
        XCTAssertEqual(LanguageDetection.language(of: "Қаерга борасиз?"), .uzbek)
        XCTAssertEqual(LanguageDetection.language(of: "Қандай яхши кун"), .uzbek)
        XCTAssertEqual(LanguageDetection.language(of: "Привет, как дела? Давно не виделись."), .russian)
        XCTAssertEqual(LanguageDetection.language(of: "Привіт, як справи? Давно не бачилися."), .ukrainian)
        XCTAssertEqual(LanguageDetection.language(of: "Merhaba, nasılsın? Bugün hava çok güzel."), .turkish)
        XCTAssertEqual(LanguageDetection.language(of: "Guten Morgen, wie geht es dir heute?"), .german)
        XCTAssertEqual(LanguageDetection.language(of: "こんにちは、お元気ですか"), .japanese)
        XCTAssertEqual(LanguageDetection.language(of: "你好，你今天怎么样？"), .chinese)
    }

    /// A word or two is too little for the recognizer at its ordinary
    /// confidence: it called these Ukrainian, Turkish, Portuguese and French
    /// at 0.50–0.83. Short text keeps the tab's old rule unless the recognizer
    /// is all but certain — as it is for real short phrases.
    func testShortTextNeedsCertaintyOrKeepsTheOldRule() {
        for word in ["Да", "Так", "Друг", "Завтра", "Молоко", "Банк", "ок"] {
            XCTAssertEqual(LanguageDetection.language(of: word), .russian, word)
        }
        for word in ["Hi", "No", "Apple", "table", "ok", "hello"] {
            XCTAssertEqual(LanguageDetection.language(of: word), .english, word)
        }
        XCTAssertEqual(LanguageDetection.language(of: "Guten Morgen"), .german)
        XCTAssertEqual(LanguageDetection.language(of: "Merci beaucoup"), .french)
        XCTAssertEqual(LanguageDetection.language(of: "Дякую"), .ukrainian)
    }

    /// Scripts only one offered language writes settle it at any length —
    /// where the recognizer is least sure.
    func testAScriptOfItsOwnDecidesEvenOneWord() {
        XCTAssertEqual(LanguageDetection.language(of: "你好"), .chinese)
        XCTAssertEqual(LanguageDetection.language(of: "こんにちは"), .japanese)
        XCTAssertEqual(LanguageDetection.language(of: "東京へ行きます"), .japanese, "kana beside kanji is Japanese")
        XCTAssertEqual(LanguageDetection.language(of: "안녕"), .korean)
        XCTAssertEqual(LanguageDetection.language(of: "مرحبا"), .arabic)
        XCTAssertEqual(LanguageDetection.language(of: "नमस्ते"), .hindi)
    }
}
