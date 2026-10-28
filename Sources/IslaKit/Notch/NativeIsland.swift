import Foundation

/// Macs whose built-in display carries Apple's own island (announced
/// 2026-10-28, a MacBook Pro with a centre camera cutout), and the one switch
/// that decides whether Isla draws on that display at all.
///
/// The problem it exists for: where macOS reports no top safe area for a
/// cutout, `NotchGeometry` takes the display for a notch-less one and draws its
/// synthetic island at the top centre — on top of Apple's. On such a Mac the
/// built-in display is left to the hardware, and Isla lives on an external
/// display when one is plugged in (`NotchGeometry.pick`) or steps aside
/// entirely when none is.
enum NativeIsland {
    /// `hw.model` identifiers of Macs whose built-in display has Apple's island.
    ///
    /// Empty until Apple names them (support.apple.com/108052 lists the
    /// identifiers per model); filled then, and nowhere else. Until it is
    /// filled the switch below is the only way to stand aside, which is why it
    /// is in Settings on every laptop.
    static let models: Set<String> = []

    /// This Mac's model identifier, read once. Empty if the kernel refuses,
    /// which matches no entry in `models` and so changes nothing.
    static let modelIdentifier: String = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }()

    static var onThisMac: Bool { models.contains(modelIdentifier) }

    /// "Show on Built-in Display" (Settings › General). True means show, which
    /// is also what an absent key meant before this existed.
    nonisolated static let showOnBuiltInKey = "showOnBuiltInDisplay"

    /// Posted when the switch changes, so the controller re-picks its display
    /// now and not at the next display change.
    nonisolated static let changedNotification = Notification.Name("\(ProductIdentity.bundleIdentifier).showOnBuiltInDisplayChanged")

    /// Whether Isla keeps off the built-in display. Pure, so each branch is a
    /// test: a choice the person made wins either way; with none, a Mac that
    /// has Apple's island avoids it and every other Mac shows as it always did.
    nonisolated static func avoidsBuiltIn(stored: Bool?, nativeIsland: Bool) -> Bool {
        if let stored { return !stored }
        return nativeIsland
    }

    /// The live reading, taken whenever the geometry is built.
    static var avoidsBuiltInNow: Bool {
        avoidsBuiltIn(
            stored: UserDefaults.standard.object(forKey: showOnBuiltInKey) as? Bool,
            nativeIsland: onThisMac
        )
    }
}
