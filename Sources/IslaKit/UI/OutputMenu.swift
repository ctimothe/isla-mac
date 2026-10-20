import AppKit
import CoreAudio
import SwiftUI

/// What the player's Output menu lists, apart from AppKit (spec §4.5), so the
/// order and the content of the menu are something a test reads.
enum OutputMenuEntry: Equatable {
    case header(String)
    case device(AudioOutputs.Output, isCurrent: Bool)
    case separator
    case soundSettings
}

enum OutputMenuModel {
    /// The menu, top to bottom: "Output", one row per device, a separator and
    /// "Sound Settings…". Never a volume row: the volume is the Mac's, not the
    /// island's (owner, 2026-10-16), and a slider folded into this menu below
    /// 540 pt was the last place the island still drew one.
    ///
    /// The devices are in the lock card's order — the one playing first, the
    /// rest as the system lists them (`LockScreenCard.orderedOutputs`, F-032):
    /// a Mac with more devices than rows must still show the one that answers
    /// "where is this going".
    static func entries(outputs: [AudioOutputs.Output], current: AudioDeviceID?) -> [OutputMenuEntry] {
        var entries: [OutputMenuEntry] = []
        entries.append(.header(localized("Output")))
        for device in LockScreenCard.orderedOutputs(outputs, current: current) {
            entries.append(.device(device, isCurrent: device.id == current))
        }
        entries.append(.separator)
        entries.append(.soundSettings)
        return entries
    }
}

/// Builds the Output menu and acts on it.
///
/// An `NSMenu` and not a SwiftUI `Menu`, because the menu has rows a SwiftUI
/// `Menu` cannot draw — a symbol in a 26 pt circle beside the name — and because it has to be popped up
/// *under the button, right-aligned to it* (the board puts the menu's right edge
/// on the button's). The panel is a non-activating `NSPanel`, which an NSMenu
/// pops up from like any other window; `MenuTracking` already listens for every
/// menu's begin and end, so the panel is held open while this one is up exactly
/// as it is for the Translate tab's language lists.
///
/// The machine is injected: `select` and `openURL` default to CoreAudio and
/// `NSWorkspace` and are replaced by the tests, so choosing a row in a test
/// moves nothing on the owner's Mac. Nothing is selected or opened until a row
/// is chosen.
@MainActor
final class OutputMenuController: NSObject {
    /// System Settings › Sound (spec §4.5).
    static let soundSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!

    /// The menu's least width — the board's 262 — so a short device list does
    /// not draw a narrow menu under a wide button.
    static let menuWidth: CGFloat = 262

    private let audio: AudioWatch
    private let select: (AudioDeviceID) -> Bool
    private let openURL: (URL) -> Void
    private let haptic: @MainActor () -> Void

    init(
        audio: AudioWatch,
        select: @escaping (AudioDeviceID) -> Bool = { AudioOutputs.select($0) },
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        haptic: @escaping @MainActor () -> Void = { Haptics.levelChange() }
    ) {
        self.audio = audio
        self.select = select
        self.openURL = openURL
        self.haptic = haptic
    }

    /// The menu for the machine as the watch last read it.
    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: localized("Output"))
        // Nothing is set on the menu itself. An NSMenu takes the appearance of
        // the view it pops up in, and NotchPanel forces .darkAqua, so this
        // menu is dark on every Mac, Light Mode included. That was measured
        // on 2026-10-20 with a test panel forced to each appearance; spec §13
        // is amended to match.
        menu.minimumWidth = Self.menuWidth
        menu.autoenablesItems = false
        for entry in OutputMenuModel.entries(outputs: audio.outputs, current: audio.current) {
            switch entry {
            case .header(let title):
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            case .device(let device, let isCurrent):
                let item = NSMenuItem(title: device.name, action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: device.id)
                item.image = Self.rowImage(symbol: device.symbol, isCurrent: isCurrent)
                // A checkmark on the one playing — the row says "selected" in
                // words as well as in colour, which a colour-blind person or a
                // yellow accent would not otherwise get (see `outputRowMarks`).
                item.state = isCurrent ? .on : .off
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            case .soundSettings:
                let item = NSMenuItem(
                    title: localized("Sound Settings…"), action: #selector(openSoundSettings), keyEquivalent: ""
                )
                item.target = self
                menu.addItem(item)
            }
        }
        return menu
    }

    /// A device row was chosen: make it the default, and re-read so the list's
    /// checkmark and the button's glyph follow the machine in one pass.
    @objc func choose(_ item: NSMenuItem) {
        guard let id = (item.representedObject as? NSNumber)?.uint32Value else { return }
        guard select(id) else { return }
        // A discrete value committed, which is what this pattern is for.
        haptic()
        audio.systemAudioChanged()
    }

    @objc func openSoundSettings() {
        openURL(Self.soundSettingsURL)
    }

    /// The row's picture: the device's symbol, white, in a 26 pt circle — the
    /// accent's red on the device that is playing, white 0.16 on the rest
    /// (spec §4.5).
    static func rowImage(symbol: String, isCurrent: Bool) -> NSImage {
        let side: CGFloat = 26
        let glyph = (NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil))?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            )
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            (isCurrent ? Theme.accentNSColor : NSColor.white.withAlphaComponent(0.16)).setFill()
            NSBezierPath(ovalIn: rect).fill()
            if let glyph {
                let size = glyph.size
                glyph.draw(in: NSRect(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                    width: size.width, height: size.height
                ))
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Pops an `OutputMenuController`'s menu up under a view.
///
/// The anchor is a flipped, empty `NSView` laid behind the button, so "under
/// the button" is its bottom edge in its own coordinates; the menu's right edge
/// is put on the button's right edge by shifting the pop-up point left by the
/// menu's width.
@MainActor
final class OutputMenuPresenter {
    weak var anchor: NSView?
    let controller: OutputMenuController

    init(controller: OutputMenuController) { self.controller = controller }

    /// Where the menu's top-left goes, in the anchor's flipped coordinates: its
    /// right edge on the anchor's, a hair under its bottom.
    static func popUpPoint(anchorSize: CGSize, menuWidth: CGFloat) -> NSPoint {
        NSPoint(x: anchorSize.width - menuWidth, y: anchorSize.height + 2)
    }

    func present() {
        guard let anchor else { return }
        let menu = controller.makeMenu()
        let width = max(menu.size.width, OutputMenuController.menuWidth)
        _ = menu.popUp(
            positioning: nil,
            at: Self.popUpPoint(anchorSize: anchor.bounds.size, menuWidth: width),
            in: anchor
        )
    }
}

/// Shared with the lyric More menu's anchor (`MenuAnchor`).
final class FlippedAnchorView: NSView {
    override var isFlipped: Bool { true }
    /// Never in the way of the button laid over it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The empty view the menu is popped up from. Lives in the button's background.
struct OutputMenuAnchor: NSViewRepresentable {
    let presenter: OutputMenuPresenter

    func makeNSView(context: Context) -> NSView {
        let view = FlippedAnchorView()
        presenter.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        presenter.anchor = nsView
    }
}
