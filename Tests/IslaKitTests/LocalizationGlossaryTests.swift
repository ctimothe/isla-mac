import XCTest

/// The Russian table's chosen words for terms that appear in more than one
/// place (H-027). Read from the source file, not the bundle, so it holds in a
/// test host that has no app resources, and fails the moment a later task
/// reintroduces a second name for the same thing.
final class LocalizationGlossaryTests: XCTestCase {

    private func russian() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ru.lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(
            pattern: #"^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";"#,
            options: .anchorsMatchLines
        )
        var table: [String: String] = [:]
        let whole = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: whole) {
            guard let key = Range(match.range(at: 1), in: text),
                  let value = Range(match.range(at: 2), in: text) else { continue }
            table[String(text[key])] = String(text[value])
        }
        return table
    }

    func testRussianFollowsTheGlossary() throws {
        let ru = try russian()
        XCTAssertEqual(ru["Clipboard"], "Буфер обмена", "one name for the clipboard, as in the rest of the table")
        XCTAssertEqual(ru["Output"], "Выход", "Apple's Control Center Sound table")
        XCTAssertEqual(ru["Sound Output"], "Выход звука", "Apple's Control Center Sound table")
        XCTAssertEqual(ru["%d pt"], "%d пт", "AppKit's Ruler and FontManager tables")
    }
}
