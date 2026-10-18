import AppKit
import SwiftUI

/// How far a `TextEditor` is scrolled, read from AppKit when it is asked.
///
/// Translate's editor stands down while the pages travel and a drawn copy of
/// its text takes its place (`TranslatePane.standIn`). The copy drew from the
/// first line, so a card scrolled down to its last lines jumped to its top for
/// the length of a swipe and back as the pages came to rest (R8c review, Codex
/// and Opus). SwiftUI reports no scroll geometry for a `TextEditor` —
/// `onScrollGeometryChange` never fires for one, tried on macOS 27 — so the
/// offset comes from the editor's own clip view, found once and read only when
/// the copy is drawn: nothing here is observed, and nothing re-renders as the
/// editor scrolls.
@MainActor
final class EditorScrollMemory {
    fileprivate weak var probe: NSView?
    private weak var clip: NSClipView?

    /// The editor's vertical scroll, in points from its first line; 0 until an
    /// editor is found.
    var offset: CGFloat {
        if clip == nil, let probe { clip = Self.editorClip(near: probe) }
        return max(0, clip?.bounds.origin.y ?? 0)
    }

    /// The clip view of the text editor drawn where `probe` is: of every text
    /// view's scroll view in the window, the one whose frame overlaps the
    /// probe's the most. The probe is the editor's background, so it is the
    /// editor's frame; another editor elsewhere in the window does not overlap
    /// it.
    static func editorClip(near probe: NSView) -> NSClipView? {
        guard let root = probe.window?.contentView else { return nil }
        let target = probe.convert(probe.bounds, to: nil)
        var best: (clip: NSClipView, area: CGFloat)?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.documentView is NSTextView {
                let overlap = scroll.convert(scroll.bounds, to: nil).intersection(target)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                if area > (best?.area ?? 0) { best = (scroll.contentView, area) }
                return
            }
            for subview in view.subviews { visit(subview) }
        }
        visit(root)
        return best?.clip
    }
}

/// Placed as a text editor's background, so `EditorScrollMemory` can find the
/// editor. Draws nothing, takes no clicks and is not an accessibility element.
struct EditorScrollProbe: NSViewRepresentable {
    let memory: EditorScrollMemory

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        memory.probe = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        memory.probe = view
    }

    private final class ProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
