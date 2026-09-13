import Foundation

/// The local rights boundary around the broker. A local override or a
/// still-authorized licensed entry wins before any metadata leaves the Mac.
@MainActor
final class CachedLyricsResolver: LyricsResolving {
    private let cache: LicensedLyricsCache
    private let remote: any LyricsResolving

    init(cache: LicensedLyricsCache, remote: any LyricsResolving) {
        self.cache = cache
        self.remote = remote
    }

    func resolve(_ identity: LyricIdentity) async -> LyricsResolution {
        if let timeline = cache.read(for: identity) {
            return .available(timeline)
        }
        let resolution = await remote.resolve(identity)
        if case .available(let timeline) = resolution,
           timeline.source != "local",
           timeline.cacheExpiry > Date() {
            try? cache.writeLicensed(timeline, for: identity)
        }
        return resolution
    }
}
