import Foundation

enum ProductIdentity {
    static let displayName = "Isla"
    static let executableName = "Isla"
    static let bundleIdentifier = "com.ctimothe.isla"
    static let supportDirectoryName = "Isla"
    static let screenshotDirectoryName = "Isla"
    static let helperResourceName = "libislamedia"
    static let internalPasteboardType = "com.ctimothe.isla.internal"
    /// Said out loud to the one service Isla talks to, so its operators can
    /// tell this app's traffic from anything else. Read from the bundle where
    /// there is one, so a release identifies itself as the version it is.
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
    static let homepage = "https://github.com/ctimothe/isla-mac"
}
