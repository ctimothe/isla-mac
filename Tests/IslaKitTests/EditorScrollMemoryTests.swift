import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Translate's stand-in text draws where the editor was scrolled to (R8c
/// review): a card scrolled to its last lines used to jump to its first for
/// the length of a swipe. SwiftUI reports no scroll for a `TextEditor`, so the
/// memory reads the editor's clip view; this hosts one, off screen, and
/// scrolls it.
@MainActor
final class EditorScrollMemoryTests: XCTestCase {
    func testTheMemoryReadsHowFarTheEditorIsScrolled() async throws {
        let memory = EditorScrollMemory()
        XCTAssertEqual(memory.offset, 0, "nothing found yet")
        let text = (1...80).map { "line \($0)" }.joined(separator: "\n")
        let editor = TextEditor(text: .constant(text))
            .background(EditorScrollProbe(memory: memory))
            .frame(width: 200, height: 100)
        let window = NSWindow(
            contentRect: NSRect(x: -40_000, y: -40_000, width: 200, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: editor)
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(memory.offset, 0, "at its first line")
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(scrollView(in:)).first
        }
        let scroll = try XCTUnwrap(scrollView(in: hosting))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(memory.offset, 300, accuracy: 0.5, "read live, when the copy is drawn")
    }
}
