import XCTest
@testable import IslaKit

/// The one entity decoder every lyric source boundary runs through. The
/// semantics — ampersand last, numerics via Unicode scalar, unknown names
/// untouched — are pinned here; the boundaries' own tests pin that the
/// boundaries actually call it.
final class HTMLEntitiesTests: XCTestCase {
    /// The order is the contract: `&amp;apos;` is the *text* `&apos;` — one
    /// level of escaping — and only an ampersand-last pass leaves it that way.
    /// The TTML copy decoded `&amp;` first and turned it into `'`, twice as far
    /// as the source meant.
    func testAmpersandDecodesLastSoEscapesStayOneLevelDeep() {
        XCTAssertEqual(HTMLEntities.decode("&amp;apos;"), "&apos;")
        XCTAssertEqual(HTMLEntities.decode("&amp;"), "&")
    }

    /// Decimal and hex numerics decode through Unicode scalars; anything the
    /// scalar model cannot name — zero, surrogates, past U+10FFFF — and any
    /// unknown name stays exactly as it arrived rather than mangled. Some KRC
    /// payloads carry no entities at all, so pass-through is the norm, not
    /// the exception.
    func testNumericEntitiesDecodeAndTheUndecodableStayUntouched() {
        XCTAssertEqual(HTMLEntities.decode("&#39;"), "'")
        XCTAssertEqual(HTMLEntities.decode("&#x27;"), "'")
        XCTAssertEqual(HTMLEntities.decode("&bogus;"), "&bogus;")
        XCTAssertEqual(HTMLEntities.decode("&#0;"), "&#0;")
        XCTAssertEqual(HTMLEntities.decode("&#xD800;"), "&#xD800;")
        XCTAssertEqual(HTMLEntities.decode("&#99999999999;"), "&#99999999999;")
    }
}
