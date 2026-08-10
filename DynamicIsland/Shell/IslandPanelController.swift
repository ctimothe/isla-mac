import AppKit
import IslandCore
import SwiftUI

/// Owns panel lifecycle. Never uses NSScreen.main (irrelevant — the panel never
/// becomes key/main); filters NSScreen.screens for the one reporting a notch.
/// Re-runs detection on every screen-parameter change (built-in disconnect,
/// lid reopen, resolution change, external display added/removed) per the plan.
@MainActor
final class IslandPanelController {
    private var panel: IslandPanel?
    // NotificationCenter tokens are safe to remove from any thread; deinit is
    // nonisolated even on a @MainActor class, so this can't be MainActor-isolated.
    private nonisolated(unsafe) var screenObserver: NSObjectProtocol?
    private let registry: ModuleRegistry

    init(registry: ModuleRegistry) {
        self.registry = registry
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleScreenChange() }
        }
        handleScreenChange()
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    private func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    private func handleScreenChange() {
        guard
            let screen = notchedScreen(),
            let geometry = NotchGeometry.detect(for: screen)
        else {
            panel?.orderOut(nil)
            return
        }

        if panel == nil {
            let viewModel = IslandShellViewModel(registry: registry)
            let hostingView = NSHostingView(rootView: IslandShellView(registry: registry, viewModel: viewModel))
            let newPanel = IslandPanel(contentRect: geometry.frameInScreen)
            newPanel.contentView = hostingView
            panel = newPanel
        }

        panel?.setFrame(geometry.frameInScreen, display: true)
        panel?.orderFrontRegardless()
    }
}
