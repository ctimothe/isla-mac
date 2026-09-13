import Foundation

/// HTTPS adapter for the Isla broker. Vendor credentials never reach this
/// process; the only credential here is an anonymous installation token.
@MainActor
final class BrokerLyricsResolver: LyricsResolving {
    private enum InstallationToken {
        case value(String)
        case failed(LyricsFailure)
    }

    private let endpoint: URL
    private let session: URLSession
    private let tokenStore: TokenStore
    private let installationAccount = "anonymous-installation"

    init(endpoint: URL, session: URLSession = .shared, tokenStore: TokenStore) {
        self.endpoint = endpoint
        self.session = session
        self.tokenStore = tokenStore
    }

    func resolve(_ identity: LyricIdentity) async -> LyricsResolution {
        let token: String
        switch await installationToken() {
        case .value(let value):
            token = value
        case .failed(let failure):
            return .failed(failure)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Isla-Installation-Token")
        do {
            request.httpBody = try JSONEncoder().encode(ResolveRequest(identity: identity))
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(LyricsFailure(kind: .service, retryable: true))
            }
            switch http.statusCode {
            case 200:
                return decode(data)
            case 401:
                tokenStore.delete(installationAccount)
                return .failed(LyricsFailure(kind: .service, retryable: true))
            case 429:
                return failure(from: data, fallback: LyricsFailure(kind: .rateLimited, retryable: true))
            case 500...599:
                return failure(from: data, fallback: LyricsFailure(kind: .service, retryable: true))
            default:
                return .failed(LyricsFailure(kind: .service, retryable: false))
            }
        } catch is CancellationError {
            return .failed(LyricsFailure(kind: .service, retryable: true))
        } catch {
            return .failed(LyricsFailure(kind: .connection, retryable: true))
        }
    }

    private func installationToken() async -> InstallationToken {
        if let existing = tokenStore.read(installationAccount), !existing.isEmpty {
            return .value(existing)
        }
        var request = URLRequest(url: installationEndpoint)
        request.httpMethod = "POST"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(LyricsFailure(kind: .service, retryable: true))
            }
            switch http.statusCode {
            case 201:
                guard let enrolled = try? JSONDecoder().decode(InstallationResponse.self, from: data),
                      !enrolled.token.isEmpty,
                      tokenStore.write(installationAccount, enrolled.token) != .unavailable else {
                    return .failed(LyricsFailure(kind: .service, retryable: false))
                }
                return .value(enrolled.token)
            case 429:
                return .failed(LyricsFailure(kind: .rateLimited, retryable: true))
            case 500...599:
                return .failed(LyricsFailure(kind: .service, retryable: true))
            default:
                return .failed(LyricsFailure(kind: .service, retryable: false))
            }
        } catch is CancellationError {
            return .failed(LyricsFailure(kind: .service, retryable: true))
        } catch {
            return .failed(LyricsFailure(kind: .connection, retryable: true))
        }
    }

    private var installationEndpoint: URL {
        endpoint
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("installations")
    }

    private func decode(_ data: Data) -> LyricsResolution {
        guard let response = try? JSONDecoder().decode(ResolveResponse.self, from: data) else {
            return .failed(LyricsFailure(kind: .service, retryable: true))
        }
        guard response.status == "available", response.territory == "allowed" else {
            return .unavailable
        }
        guard let timeline = response.timeline,
              timeline.matchConfidence >= 0.85,
              !timeline.lines.isEmpty else {
            return .unavailable
        }
        guard !timeline.attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !timeline.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              timeline.cacheExpiresAt > Date().timeIntervalSince1970 else {
            return .failed(LyricsFailure(kind: .service, retryable: true))
        }
        return .available(timeline.value)
    }

    private func failure(from data: Data, fallback: LyricsFailure) -> LyricsResolution {
        guard let response = try? JSONDecoder().decode(FailureResponse.self, from: data) else {
            return .failed(fallback)
        }
        let kind: LyricsFailure.Kind
        switch response.errorClass {
        case "connection": kind = .connection
        case "rate_limited": kind = .rateLimited
        case "service": kind = .service
        default: return .failed(fallback)
        }
        return .failed(LyricsFailure(kind: kind, retryable: response.retryable))
    }

    private struct ResolveRequest: Encodable {
        let playerID: String
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let spotifyID: String?
        let isrc: String?
        let appLocale: String

        init(identity: LyricIdentity) {
            playerID = identity.playerID
            title = identity.title
            artist = identity.artist
            album = identity.album
            duration = identity.duration
            spotifyID = identity.spotifyID
            isrc = identity.isrc
            appLocale = identity.locale
        }
    }

    private struct InstallationResponse: Decodable {
        let token: String
    }

    private struct FailureResponse: Decodable {
        let errorClass: String
        let retryable: Bool
    }

    private struct ResolveResponse: Decodable {
        let status: String
        let territory: String?
        let timeline: WireTimeline?
    }

    private struct WireTimeline: Decodable {
        let granularity: LyricTimeline.Granularity
        let attribution: String
        let source: String
        let matchConfidence: Double
        let cacheExpiresAt: TimeInterval
        let lines: [WireLine]

        var value: LyricTimeline {
            LyricTimeline(
                lines: lines.map(\.value),
                granularity: granularity,
                attribution: attribution,
                source: source,
                matchConfidence: matchConfidence,
                cacheExpiry: Date(timeIntervalSince1970: cacheExpiresAt)
            )
        }
    }

    private struct WireLine: Decodable {
        let at: TimeInterval
        let text: String
        let words: [WireWord]?
        let isCredit: Bool?

        var value: LyricsStore.Line {
            LyricsStore.Line(
                at: at,
                text: text,
                words: (words ?? []).map(\.value),
                isCredit: isCredit ?? false
            )
        }
    }

    private struct WireWord: Decodable {
        let at: TimeInterval
        let text: String
        let end: TimeInterval?

        var value: WordSyncedLyrics.Word {
            WordSyncedLyrics.Word(at: at, text: text, end: end)
        }
    }
}
