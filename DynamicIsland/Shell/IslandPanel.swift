import AppKit

/// boring.notch's proven window config (locked decision #1) — level/collectionBehavior
/// predates Stage Manager but has multiple shipping precedents; `.canJoinAllApplications`
/// (macOS 13+, Stage-Manager-aware) is deliberately not used yet, see checklist.md.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .mainMenu + 3
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isMovable = false
    }
}
