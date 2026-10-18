import Foundation

/// The one session every request to a third party goes through: LRCLIB,
/// MyMemory, Spotify's Web API and image server, and GitHub's release feed.
///
/// It keeps nothing. Every caller used to go through `URLSession.shared`,
/// whose `URLCache` stores cacheable GET responses on disk, keyed by the full
/// URL, in `~/Library/Caches/com.ctimothe.isla/Cache.db` — and Translate
/// Online sends the user's text as the `q=` item of a GET, so the text and its
/// translation could sit there indefinitely, while the Translate pane hid the
/// same words behind a privacy cover (audit G-016). The shared session also
/// kept a persistent cookie jar and credential store, which would let one
/// service tie every request to the next across launches.
///
/// `.ephemeral` alone is not quite enough: it still keeps an in-memory cache,
/// cookie jar and credential store for the life of the process. Each is nil'd
/// outright. Nothing here needed any of them — LRCLIB and MyMemory are
/// anonymous GETs, the update check is one GET, and Spotify's PKCE exchange
/// and refresh carry everything in a POST body and a bearer header. The lyric
/// layer keeps its own cache of what it found, so losing HTTP caching costs a
/// repeat lookup nothing it did not already have.
///
/// Each caller still sets its own headers (LRCLIB's User-Agent, the update
/// check's Accept); the session adds none of its own.
enum PrivateNetwork {
    static let session = URLSession(configuration: makeConfiguration())

    /// A session of the same private configuration for a caller that needs
    /// delegate callbacks (a download with progress and a redirect rule), which
    /// only a session of its own can have. This is the one place besides
    /// `session` that builds a `URLSession`; nothing else may, or a `.default`
    /// configuration would bring the cache back (`PrivateNetworkTests`).
    /// `protocolClasses` is the seam a test answers the wire through.
    static func makeSession(
        delegate: URLSessionDelegate, requestTimeout: TimeInterval? = nil, resourceTimeout: TimeInterval? = nil,
        protocolClasses: [AnyClass]? = nil
    ) -> URLSession {
        let configuration = makeConfiguration()
        if let requestTimeout { configuration.timeoutIntervalForRequest = requestTimeout }
        if let resourceTimeout { configuration.timeoutIntervalForResource = resourceTimeout }
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// The configuration `session` is made from, fresh each time. A download
    /// that wants progress needs a delegate, which only a session of its own
    /// can have; it takes this so it keeps every one of these rules.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// Set once the shared cache and cookie jar that earlier builds filled
    /// have been emptied. Versioned, so a later change that needs another
    /// clean slate can take a new key rather than reuse this one.
    static let purgedKey = "network.cachePurged.1"

    /// Empties what `URLSession.shared` left behind, once. A build that no
    /// longer writes to the shared cache does not make the rows already in it
    /// go away: a translation done last month would stay in `Cache.db` until
    /// the system happened to evict it. Run at launch, before any request.
    ///
    /// Everything is injected so a test can run it against a cache and a jar
    /// of its own; the app passes the shared ones. Never reached from tests
    /// with the real ones — that would wipe the owner's cache as a side effect
    /// of running the suite.
    static func purgeLegacyStorage(
        defaults: UserDefaults = .standard,
        cache: URLCache = .shared,
        cookies: HTTPCookieStorage = .shared
    ) {
        guard !defaults.bool(forKey: purgedKey) else { return }
        cache.removeAllCachedResponses()
        cookies.cookies?.forEach(cookies.deleteCookie)
        defaults.set(true, forKey: purgedKey)
    }
}
