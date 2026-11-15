import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Every `IslandGlyph` beside the SF Symbol it replaced, white on the panel's
/// black, at the two sizes the island draws most (15.5 pt, where a 13 pt
/// symbol stood, and islandcn's 22 pt compact glyph). Slice S1 of
/// plan 2026-11-15-islandcn-identical is judged from this one picture.
@MainActor
final class VisualLabGlyphsTests: VisualLabCase {
    private static func sheet() -> some View {
        let columns = Array(repeating: GridItem(.fixed(108), spacing: 4), count: 8)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(IslandGlyph.allCases, id: \.self) { glyph in
                VStack(spacing: 3) {
                    HStack(spacing: 10) {
                        Image(nsImage: NSImage(systemSymbolName: glyph.rawValue, accessibilityDescription: nil) ?? NSImage())
                            .font(.system(size: 13))
                            .frame(width: 22, height: 22)
                            .opacity(0.45)
                        GlyphImage(glyph, pointSize: 13)
                        GlyphImage(glyph, size: 22)
                    }
                    Text(glyph.rawValue)
                        .font(.system(size: 8))
                        .lineLimit(1)
                        .opacity(0.6)
                }
                .foregroundStyle(.white)
                .frame(width: 108, height: 40)
            }
        }
        .padding(10)
        .frame(width: 8 * 112 + 20)
        .background(Color.black)
    }

    func testGlyphSheet() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "glyphs")
        let rows = CGFloat((IslandGlyph.allCases.count + 7) / 8)
        try await shoot.shoot("all", variants: [.base], size: CGSize(width: 8 * 112 + 20, height: rows * 46 + 20)) { _ in
            AnyView(Self.sheet())
        }
    }
}
