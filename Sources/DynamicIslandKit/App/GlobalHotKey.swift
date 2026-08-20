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
    private let action: () -> Void

    /// Identifies our registrations in the Carbon callback, which is C and gets
    /// no context pointer of its own worth trusting across a process. Each
    /// registration takes an id and the callback looks the instance back up,
    /// so more than one shortcut can coexist.
    private static let signature = OSType(0x444E4953) // 'DNIS'
    private static var live: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var sharedHandler: EventHandlerRef?
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: a virtual key code, so the binding survives a layout
    ///     change. A Cyrillic layout answers the same physical key with a
    ///     different character, and matching on characters fails exactly for
    ///     the person typing Russian.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.id = Self.nextID
        Self.nextID += 1

        // One handler for every shortcut, installed once: Carbon dispatches
        // all hot-key presses through it and the id says which one fired.
        if Self.sharedHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            var installed: EventHandlerRef?
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, _ in
                    var fired = EventHotKeyID()
                    GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &fired
                    )
                    MainActor.assumeIsolated { GlobalHotKey.live[fired.id]?.action() }
                    return noErr
                },
                1,
                &eventType,
                nil,
                &installed
            )
            guard status == noErr else { return nil }
            Self.sharedHandler = installed
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let registered = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard registered == noErr, reference != nil else { return nil }
        Self.live[id] = self
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
    }
}

extension GlobalHotKey {
    /// ⌥⌘I — free in macOS's own shortcut set, and mnemonic for the island.
    static let defaultKeyCode = UInt32(kVK_ANSI_I)
    static let defaultModifiers = UInt32(optionKey | cmdKey)

    /// ⌥⌘T translates whatever is on the clipboard.
    static let translateKeyCode = UInt32(kVK_ANSI_T)
}
