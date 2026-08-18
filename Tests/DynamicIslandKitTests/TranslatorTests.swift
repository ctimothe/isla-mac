import XCTest
@testable import DynamicIslandKit

@MainActor
final class TranslatorTests: XCTestCase {
    func testRouteUsesCyrillicToChooseDirection() {
        XCTAssertEqual(Translator.route(for: "hello").source, Translator.english)
        XCTAssertEqual(Translator.route(for: "привет").source, Translator.russian)
        XCTAssertEqual(Translator.route(for: "hello").target, Translator.russian)
        XCTAssertEqual(Translator.route(for: "привет").target, Translator.english)
    }
}
