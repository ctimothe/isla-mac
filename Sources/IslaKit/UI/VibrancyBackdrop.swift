import AppKit
import SwiftUI

/// A pane of real window-server glass.
///
/// SwiftUI's `Material` offers two settings and neither is the one the lock
/// screen wants: the light one lets the wallpaper through as near-white, where
/// white type cannot be read, and the dark one resolves to near-black over
/// anything bright — a slab, which is the opposite of glass. `NSVisualEffectView`
/// has the material the system uses for its own lock-screen widgets, so it is
/// asked for by name.
///
/// `.behindWindow` blending is what does the sampling. It needs the window to
/// be transparent behind this view, which the panel already is.
struct VibrancyBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var appearance: NSAppearance.Name = .vibrantDark

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // Active regardless of key status: this panel never becomes key, and
        // `.followsWindowActiveState` would leave the glass permanently
        // inactive — flat grey, every time.
        view.state = .active
        view.appearance = NSAppearance(named: appearance)
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
        if view.appearance?.name != appearance {
            view.appearance = NSAppearance(named: appearance)
        }
        view.state = .active
    }
}
