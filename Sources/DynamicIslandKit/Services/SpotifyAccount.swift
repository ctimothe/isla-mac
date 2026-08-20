import AppKit
import CryptoKit

/// The one Spotify feature that has no local API: Liked Songs.
///
/// Every scriptable route was probed and is dead — the AppleScript `starred`
/// property errors on read and write both, a corpse left in the dictionary —
/// so saving a track goes the way Spotify actually sanctions: the Web API,
/// authorized once by the user in their browser with PKCE. No client secret
/// exists anywhere; the tokens live in the keychain, never in defaults; and
/// the only scopes requested are the library ones the heart needs.
@MainActor
final class SpotifyAccount: ObservableObject {
    static let shared = SpotifyAccount()

    /// The registration made for this install — created in the user's own
    /// Spotify developer dashboard, at their request, so Connect is one
    /// click. A client id is public information by design in PKCE: there is
    /// no secret to protect, the id only names the app on the consent page.
    /// A different id pasted into defaults still overrides it.
    static let builtInClientID = "358067117334450d8cd1c09f689ffeec"
    static let clientIDKey = "spotifyClientID"
    static let redirectURI = "dynamicisland://spotify-callback"

    @Published private(set) var isConnected = false
    /// Track id → saved?, so hearts answer instantly and survive re-renders.
    @Published private(set) var saved: [String: Bool] = [:]

    private var verifier: String?
    private let keychain = KeychainStore(service: "dev.dynamicisland.spotify")

    private init() {
        isConnected = keychain.read("refreshToken") != nil
    }

    var clientID: String? {
        let value = UserDefaults.standard.string(forKey: Self.clientIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? Self.builtInClientID : value
    }

    // MARK: - Authorization (PKCE)

    func beginAuthorization() {
        guard let clientID else { return }
        let raw = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        let verifier = raw.base64URLEncoded()
        self.verifier = verifier
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: "user-library-read user-library-modify"),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]
        NSWorkspace.shared.open(components.url!)
    }

    /// The browser lands back here through the app's URL scheme.
    func handleCallback(_ url: URL) {
        guard url.host == "spotify-callback" || url.path.contains("spotify-callback"),
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "code" })?.value,
              let verifier, let clientID else { return }
        Task {
            await exchange(code: code, verifier: verifier, clientID: clientID)
        }
    }

    private func exchange(code: String, verifier: String, clientID: String) async {
        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(Self.redirectURI)",
            "client_id=\(clientID)",
            "code_verifier=\(verifier)",
        ].joined(separator: "&")
        guard let tokens = await tokenRequest(body: body) else { return }
        store(tokens)
    }

    private struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private func tokenRequest(body: String) async -> Tokens? {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    private func store(_ tokens: Tokens) {
        keychain.write("accessToken", tokens.access_token)
        if let refresh = tokens.refresh_token { keychain.write("refreshToken", refresh) }
        keychain.write("expiresAt", String(Date().timeIntervalSince1970 + Double(tokens.expires_in) - 60))
        isConnected = true
    }

    func disconnect() {
        keychain.delete("accessToken")
        keychain.delete("refreshToken")
        keychain.delete("expiresAt")
        saved = [:]
        isConnected = false
    }

    private func freshAccessToken() async -> String? {
        if let expires = keychain.read("expiresAt").flatMap(Double.init),
           Date().timeIntervalSince1970 < expires,
           let token = keychain.read("accessToken") {
            return token
        }
        guard let refresh = keychain.read("refreshToken"), let clientID else { return nil }
        let body = "grant_type=refresh_token&refresh_token=\(refresh)&client_id=\(clientID)"
        guard let tokens = await tokenRequest(body: body) else { return nil }
        store(tokens)
        return tokens.access_token
    }

    // MARK: - Liked Songs

    func refreshSavedState(trackID: String) {
        guard isConnected, saved[trackID] == nil else { return }
        Task {
            guard let token = await freshAccessToken(),
                  let url = URL(string: "https://api.spotify.com/v1/me/tracks/contains?ids=\(trackID)") else { return }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let flags = try? JSONDecoder().decode([Bool].self, from: data),
                  let flag = flags.first else { return }
            saved[trackID] = flag
        }
    }

    func toggleSaved(trackID: String) {
        guard isConnected else { return }
        let wants = !(saved[trackID] ?? false)
        // Optimistic: the heart answers the tap now; a failed request puts
        // it back rather than leaving the tap looking ignored.
        saved[trackID] = wants
        Task {
            guard let token = await freshAccessToken(),
                  let url = URL(string: "https://api.spotify.com/v1/me/tracks?ids=\(trackID)") else {
                saved[trackID] = !wants
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = wants ? "PUT" : "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let status = (try? await URLSession.shared.data(for: request))
                .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
            if !(status.map { (200..<300).contains($0) } ?? false) {
                saved[trackID] = !wants
            }
        }
    }
}

/// Minimal generic-password keychain wrapper: tokens are credentials and do
/// not belong in UserDefaults.
struct KeychainStore {
    let service: String

    func read(_ account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ account: String, _ value: String) {
        delete(account)
        let add: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(value.utf8),
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    func delete(_ account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
