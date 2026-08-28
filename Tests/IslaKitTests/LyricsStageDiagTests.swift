// Appended diagnostic: render the stage's pieces in isolation.
import SwiftUI
import XCTest
@testable import IslaKit

@MainActor
final class LyricsStageDiagTests: XCTestCase {
    func testRowsAloneRender() throws {
        let lines = (0..<6).map { LyricsStore.Line(at: Double($0 * 4 + 1), text: "Line number \($0) with words") }
        // Rows only, no ScrollView, no GeometryReader.
        let rows = VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(lines.enumerated()), id: \.element.at) { _, line in
                Text(line.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).opacity(0.5)
            }
        }
        .frame(width: 620, height: 208)
        .background(Color.black)
        let image = ImageRenderer(content: rows).nsImage
        try save(image, "diag_rows.png")
    }

    func testOffsetColumnRenders() throws {
        let lines = (0..<10).map { LyricsStore.Line(at: Double($0 * 4 + 1), text: "Line number \($0) with words") }
        let anchor = 4
        let column = GeometryReader { geo in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.element.at) { index, line in
                    Text(line.text)
                        .font(.system(size: index == anchor ? 15 : 13, weight: index == anchor ? .bold : .semibold))
                        .foregroundStyle(.white)
                        .opacity(index == anchor ? 1 : 0.4)
                        .frame(height: 40, alignment: .leading)
                }
            }
            .offset(y: geo.size.height / 2 - (CGFloat(anchor) * 48 + 20))
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .frame(width: 620, height: 174)
        .background(Color.black)
        let image = ImageRenderer(content: column).nsImage
        try save(image, "diag_offset.png")
    }

    private func save(_ image: NSImage?, _ name: String) throws {
        let image = try XCTUnwrap(image)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/claude-501/-Users-ctimothe-code-projects-dynamic-island/518a0e07-9288-4a58-8703-b43facaf658f/scratchpad/\(name)"))
    }
}
