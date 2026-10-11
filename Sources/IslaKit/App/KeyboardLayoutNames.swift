import Carbon.HIToolbox
import Foundation

/// What the keyboard in front of the user prints on a key.
///
/// A shortcut stores a virtual key code, the physical key, so it survives a
/// layout change. Its label used to come from a fixed US table, which on
/// Dvorak, AZERTY and QWERTZ made Settings and the welcome say ⌃⌥⌘I while the
/// key printed "C" fired (G-039). macOS menus ask the layout, so this does.
///
/// The layout is the current ASCII-capable one and never a Cyrillic or Arabic
/// layout, because those have no Latin letters and a shortcut should read the
/// same whichever of the user's layouts is active when it is looked at: the
/// same rule the old table gave, now following the Latin layout the user
/// actually has. Keys the layout cannot print as one visible character (arrows,
/// Return, F-keys, Space) return nil so the caller keeps the glyph from its
/// own table.
enum KeyboardLayoutNames {
    private static let lock = NSLock()
    /// Keyed by the layout's id, so a layout switch needs no invalidation: the
    /// current layout is asked for on every call and a different one is simply
    /// a different entry.
    private nonisolated(unsafe) static var cache: [String: [Int: String?]] = [:]

    /// The name on the current ASCII-capable layout, or nil when it has none
    /// for this key (or the layout cannot be read here).
    static func name(for keyCode: Int) -> String? {
        // The Text Input Sources calls trap off the main queue on current
        // macOS. A label asked for from elsewhere falls back to the table.
        guard Thread.isMainThread else { return nil }
        guard let source = asciiCapableSource() else { return nil }
        return name(for: keyCode, resolved: source)
    }

    /// The name on `source`, falling back to the current ASCII-capable layout
    /// when `source` cannot type Latin letters.
    static func name(for keyCode: Int, in source: TISInputSource) -> String? {
        guard Thread.isMainThread else { return nil }
        if let ascii = property(source, kTISPropertyInputSourceIsASCIICapable) as CFBoolean?,
           CFBooleanGetValue(ascii) {
            return name(for: keyCode, resolved: source)
        }
        guard let fallback = asciiCapableSource() else { return nil }
        return name(for: keyCode, resolved: fallback)
    }

    // MARK: - Private

    private static func asciiCapableSource() -> TISInputSource? {
        TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? T
    }

    private static func name(for keyCode: Int, resolved source: TISInputSource) -> String? {
        let id: String = property(source, kTISPropertyInputSourceID) ?? "?"
        lock.lock()
        if let hit = cache[id]?[keyCode] { lock.unlock(); return hit }
        lock.unlock()

        let computed = translate(keyCode, source: source)
        lock.lock()
        cache[id, default: [:]][keyCode] = .some(computed)
        lock.unlock()
        return computed
    }

    private static func translate(_ keyCode: Int, source: TISInputSource) -> String? {
        guard let layoutData: CFData = property(source, kTISPropertyUnicodeKeyLayoutData),
              let bytes = CFDataGetBytePtr(layoutData)
        else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeys, chars.count, &length, &chars
        )
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length)
        // One visible character: Return, Tab, Space and the cursor keys come
        // back as control or white-space and keep their glyphs.
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return nil }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter, .decimalNumber,
             .otherNumber, .letterNumber, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return text.uppercased()
        default:
            return nil
        }
    }
}
