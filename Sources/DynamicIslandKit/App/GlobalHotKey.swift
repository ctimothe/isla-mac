import AppKit
import Carbon.HIToolbox

/// A system-wide key combination, registered without Accessibility.
///
/// `RegisterEventHotKey` is the one route to a global shortcut that asks for
/// no permission at all: it reserves the combination with the window server
/// rather than watching the event stream, so unlike a `CGEventTap` or an
/// `NSEvent` global monitor it neither sees nor needs to see anything the user
/// types. Keeping the app permission-free is a deliberate product position,
/// and this is the only mechanism that preserves it.
///
/// The panel is otherwise unreachable from the keyboard: it never activates,
/// so nothing routes a key press to it and assistive tech has no way in.
@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Identifies our registration in the Carbon callback, which is C and gets
    /// no context pointer of its own worth trusting across a process.
    private static let signature = OSType(0x444E4953) // 'DNIS'
    private static var live: GlobalHotKey?

    /// - Parameters:
    ///   - keyCode: a virtual key code, so the binding survives a layout
    ///     change. A Cyrillic layout answers the same physical key with a
    ///     different character, and matching on characters fails exactly for
    ///     the person typing Russian.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                MainActor.assumeIsolated { GlobalHotKey.live?.action() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handler
        )
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let registered = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard registered == noErr, reference != nil else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
        Self.live = self
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}

extension GlobalHotKey {
    /// ⌥⌘I — free in macOS's own shortcut set, and mnemonic for the island.
    static let defaultKeyCode = UInt32(kVK_ANSI_I)
    static let defaultModifiers = UInt32(optionKey | cmdKey)
}
