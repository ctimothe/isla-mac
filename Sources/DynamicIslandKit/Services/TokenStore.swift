import Foundation
import Security

/// Where the Spotify tokens live, and why it depends on how the app was signed.
///
/// There are two honest places to put a credential on macOS, and which one is
/// available is decided entirely by the build's signature:
///
/// **Signed builds** — anything with a Developer ID, which is every release —
/// use the *data-protection* keychain. Items there are scoped to the team
/// identity carried in the app's entitlements, so the app can always read what
/// it wrote, across updates and re-signings, and nothing else can. No prompt,
/// ever, and proper isolation. This is the path users are on.
///
/// **Unsigned local builds** — what you get from cloning the repository and
/// running `Scripts/bundle.sh` — cannot use it: the data-protection keychain
/// needs a `keychain-access-groups` entitlement, that entitlement needs a team
/// prefix, and an ad-hoc signature has no team. The obvious fallback, the
/// login keychain, is the worst of both worlds here: it protects each item with
/// an ACL naming the exact binary that created it, and an ad-hoc signature
/// changes with every rebuild, so the app becomes a stranger to the token it
/// wrote itself and macOS asks for the login password again. Answering does not
/// help; the next build is a different stranger. That is not security, it is
/// an interruption with no benefit — the token is not protected from anything,
/// it is merely inconvenient for its owner.
///
/// So unsigned builds keep the token in a file in the app's own Application
/// Support directory, `0600`, owner-only. That is the same protection the login
/// keychain would actually be providing here (any process running as you could
/// read either), minus the prompts. It is stated plainly in Settings rather
/// than hidden, and it never applies to a build anybody ships.
///
/// The legacy login keychain is read in exactly one situation: the user asks
/// for it, from Settings, to bring an account across from an older build. It is
/// never read on its own, so it can never prompt on its own.
struct TokenStore: Sendable {
    let service: String
    private let fileURL: URL?

    init(service: String, paths: AppPaths = .live) {
        self.service = service
        self.fileURL = paths.supportFile("spotify-credentials.json")
    }

    enum Backing: String, Sendable {
        case keychain
        case file
        case unavailable
    }

    // MARK: - Reading

    func read(_ account: String) -> String? {
        if let value = keychainRead(account, dataProtection: true) { return value }
        return fileValues()[account]
    }

    /// Whether an older build left an account in the login keychain.
    ///
    /// Asks for attributes only, never for the data. An attributes query does
    /// not touch the item's contents, so it does not need the ACL's permission
    /// and cannot raise the password prompt — which is what makes it safe to
    /// call on launch to decide whether to offer the import at all.
    func legacyAccountExists(_ account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnAttributes: true,
        ]
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }

    /// Reads the login keychain, which *will* ask for the password if this
    /// build is not the one that wrote the item. Only ever called because
    /// somebody pressed a button asking for exactly that.
    func readLegacy(_ account: String) -> String? {
        keychainRead(account, dataProtection: false)
    }

    // MARK: - Writing

    @discardableResult
    func write(_ account: String, _ value: String) -> Backing {
        if keychainWrite(account, value) { return .keychain }
        return writeFile(account, value) ? .file : .unavailable
    }

    func delete(_ account: String) {
        SecItemDelete(keychainQuery(account, dataProtection: true) as CFDictionary)
        SecItemDelete(keychainQuery(account, dataProtection: false) as CFDictionary)
        var values = fileValues()
        values.removeValue(forKey: account)
        writeFileValues(values)
    }

    /// Which backing this build actually gets, for Settings to state honestly.
    var backing: Backing {
        // A probe write, immediately removed: the answer depends on
        // entitlements the app cannot introspect directly.
        let probe = "__backing_probe__"
        defer { SecItemDelete(keychainQuery(probe, dataProtection: true) as CFDictionary) }
        if keychainWrite(probe, "probe") { return .keychain }
        return fileURL == nil ? .unavailable : .file
    }

    // MARK: - Keychain

    private func keychainQuery(_ account: String, dataProtection: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain] = true }
        return query
    }

    private func keychainRead(_ account: String, dataProtection: Bool) -> String? {
        var query = keychainQuery(account, dataProtection: dataProtection)
        query[kSecReturnData] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainWrite(_ account: String, _ value: String) -> Bool {
        SecItemDelete(keychainQuery(account, dataProtection: true) as CFDictionary)
        var add = keychainQuery(account, dataProtection: true)
        add[kSecValueData] = Data(value.utf8)
        // Needed only while somebody is using this Mac, and never on another.
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - File

    private func fileValues() -> [String: String] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }

    private func writeFile(_ account: String, _ value: String) -> Bool {
        var values = fileValues()
        values[account] = value
        return writeFileValues(values)
    }

    @discardableResult
    private func writeFileValues(_ values: [String: String]) -> Bool {
        guard let fileURL, let data = try? JSONEncoder().encode(values) else { return false }
        do {
            try data.write(to: fileURL, options: [.atomic])
            // Owner-only, set after the write: an atomic write replaces the
            // file, so permissions applied beforehand would be replaced with it.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            NSLog("Dynamic Island: cannot store credentials: \(error.localizedDescription)")
            return false
        }
    }
}
