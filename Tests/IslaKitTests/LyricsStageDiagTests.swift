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

    /// Renders the view and proves the render produced real pixels.
    ///
    /// This used to write into a hardcoded absolute path under `/private/tmp`
    /// belonging to one long-dead session, and asserted nothing about what it
    /// wrote — so it passed only while that directory happened to still exist
    /// and failed the moment `/tmp` was swept, in a suite that had nothing to
    /// do with lyrics. The render is worth keeping: `ImageRenderer` over this
    /// layout is what used to trap. The path is not.
    private func save(_ image: NSImage?, _ name: String) throws {
        let image = try XCTUnwrap(image, "ImageRenderer produced no image for \(name)")
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 1024, "\(name) rendered an empty or near-empty image")

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("isla-diag", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try png.write(to: destination.appendingPathComponent(name))
    }
}
