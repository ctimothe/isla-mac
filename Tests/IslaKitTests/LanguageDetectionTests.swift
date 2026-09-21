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
        XCTAssertEqual(LanguageDetection.language(of: "Привет, как дела? Давно не виделись."), .russian)
        XCTAssertEqual(LanguageDetection.language(of: "Привіт, як справи? Давно не бачилися."), .ukrainian)
        XCTAssertEqual(LanguageDetection.language(of: "Merhaba, nasılsın? Bugün hava çok güzel."), .turkish)
        XCTAssertEqual(LanguageDetection.language(of: "Guten Morgen, wie geht es dir heute?"), .german)
        XCTAssertEqual(LanguageDetection.language(of: "こんにちは、お元気ですか"), .japanese)
        XCTAssertEqual(LanguageDetection.language(of: "你好，你今天怎么样？"), .chinese)
    }

    /// Too short to call: the old rule, by script.
    func testTooShortFallsBackToTheScript() {
        XCTAssertEqual(LanguageDetection.language(of: "ок"), .russian)
        XCTAssertEqual(LanguageDetection.language(of: "ok"), .english)
    }
}
