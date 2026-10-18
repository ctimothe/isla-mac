import Foundation

/// Whether MyMemory's anonymous daily allowance is spent, remembered for the
/// rest of its day so that nothing keeps asking a service that has said no.
///
/// Set by `OnlineTranslation.translate` the moment the service answers that the
/// allowance is gone — whichever surface asked, the Translate tab or a lyric
/// batch — and read by the lyric batches, which are the callers that would
/// otherwise go on sending a song's lines one after another into a refusal, and
/// would spend the little a Translate-tab paste needs (review 2026-10-15). In
/// memory only: a relaunch asks once, is told, and sets it again. The day is
/// taken to turn over at midnight UTC, the service's own and the only one it
/// publishes; a guess that is a few hours early costs a few refused requests
/// and one that is late costs a few hours without lyric translation.
final class OnlineAllowance: @unchecked Sendable {
    static let shared = OnlineAllowance()

    private let lock = NSLock()
    private var until: Date?
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// True from the service's refusal until its day turns over.
    var isExhausted: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until else { return false }
        if now() >= until {
            self.until = nil
            return false
        }
        return true
    }

    func markExhausted() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let current = now()
        let midnight = calendar.nextDate(
            after: current, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime
        ) ?? current.addingTimeInterval(24 * 3600)
        lock.lock(); defer { lock.unlock() }
        until = midnight
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        until = nil
    }
}

/// The one part of Translate that reaches the network, and only when **Translate
/// Online** is switched on in Settings. It is off by default.
///
/// It exists for the languages this Mac cannot translate on its own. Uzbek is
/// the one that asked for it: Apple's Translation framework does not offer it,
/// and the on-device language model, tried on 2026-09-21, answered English with
/// Uzbek-looking nonsense, refused ordinary sentences as unsafe, and once ran
/// for 218 seconds until it blew its context window. A pair either engine on
/// this Mac offers is never sent here, whether or not that engine can run right
/// now; see `Translator.engines(given:)`.
///
/// The service is MyMemory (translated.net): free, no account, no key, and it
/// published its terms for exactly this — anonymous use up to a daily character
/// allowance. It receives the text being translated and the two language codes,
/// over an ordinary web request, so also the Mac's address and a user agent
/// naming the app. Google's free endpoint was tried first and answered this Mac
/// with a bot check.
enum OnlineTranslation {
    static let endpoint = "https://api.mymemory.translated.net/get"

    /// The service refuses a query over 500 characters — characters, not
    /// bytes: measured with 481 Cyrillic characters (845 bytes), which it took.
    /// A little under, so a sentence boundary has room to land.
    static let maximumQuery = 480

    /// The most of one text that is ever sent: ten queries. MyMemory's
    /// published anonymous allowance is 5,000 characters a day (its usage
    /// limits page, read 2026-10-11), and a translation used to send all of
    /// whatever was in the field — 100 KB pasted by mistake went out as 209
    /// requests one after another, the day's allowance gone on the first
    /// eleven and the rest refused (F-042). Under the allowance, so one long
    /// paste cannot spend it all and leave nothing for the next sentence.
    static let maximumOnlineCharacters = 4_800

    /// What one translation sent and got back.
    struct Reply: Equatable {
        var text: String
        /// How many characters went, when the text was longer than
        /// `maximumOnlineCharacters` and the rest stayed here; nil when all of
        /// it went.
        var sentCharacters: Int?
    }

    enum Failure: Error, Equatable {
        /// No answer: offline, a timeout, the service down.
        case unreachable
        /// The anonymous daily allowance is spent.
        case quotaExhausted
        /// The service answered and declined, with its own reason.
        case refused(String)
        /// A later piece failed after earlier ones came back. Their
        /// translation is kept — it was already paid for out of the
        /// allowance — together with why the rest did not come.
        indirect case partial(text: String, cause: Failure)

        /// Whether this is the spent allowance, directly or as the reason a
        /// later piece did not come.
        var isQuotaExhausted: Bool {
            switch self {
            case .quotaExhausted: return true
            case .partial(_, let cause): return cause.isQuotaExhausted
            case .unreachable, .refused: return false
            }
        }
    }

    /// The service's name for a language. Its Chinese is a region, not a
    /// script; everything else here is the plain two-letter code.
    static func serviceCode(for language: TranslationLanguage) -> String {
        language == .chinese ? "zh-CN" : language.baseCode
    }

    static func request(for text: String, from source: TranslationLanguage,
                        to target: TranslationLanguage) -> URLRequest? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "\(serviceCode(for: source))|\(serviceCode(for: target))"),
            // Machine translation only. The service's default answer is its
            // best match from a public, crowd-filled translation memory, and
            // that memory holds junk: "salom" came back as "Google TRANSLEÓN",
            // ranked 0.98 above the right "Привет" (2026-09-21). With no
            // private memory to consult, `onlyprivate` leaves the machine
            // translation as the only answer — "salom" is "привет".
            URLQueryItem(name: "onlyprivate", value: "1"),
            URLQueryItem(name: "mt", value: "1"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Translates `text`, a piece at a time when it is longer than one query,
    /// and no more than `maximumOnlineCharacters` of it.
    ///
    /// The pieces go one after another, never in parallel: parallel requests
    /// spend the allowance just as fast and the service throttles them.
    static func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage,
                          session: URLSession = PrivateNetwork.session,
                          allowance: OnlineAllowance = .shared) async throws -> Reply {
        do {
            return try await send(text, from: source, to: target, session: session)
        } catch let failure as Failure where failure.isQuotaExhausted {
            allowance.markExhausted()
            throw failure
        }
    }

    private static func send(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage,
                             session: URLSession) async throws -> Reply {
        let pieces = chunks(of: text)
        // Whole pieces, so the cut lands where a piece ends — on a sentence
        // where there is one — and never mid-word. Each piece is at most one
        // query, so this many of them is at most the cap.
        let sent = Array(pieces.prefix(maximumOnlineCharacters / maximumQuery))
        // Scripts written without spaces between sentences are joined without.
        let separator = [TranslationLanguage.chinese, .japanese].contains(target) ? "" : " "
        func joined(_ parts: [String]) -> String {
            parts.joined(separator: separator).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var translated: [String] = []
        for piece in sent {
            try Task.checkCancellation()
            do {
                guard let request = request(for: piece, from: source, to: target) else {
                    throw Failure.unreachable
                }
                let data: Data
                do {
                    (data, _) = try await session.data(for: request)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch {
                    throw Failure.unreachable
                }
                translated.append(try decode(data))
            } catch let failure as Failure where !translated.isEmpty {
                // Everything before this piece came back and is kept; the
                // first failure used to throw it all away.
                throw Failure.partial(text: joined(translated), cause: failure)
            }
        }
        // Counted from the pieces themselves, so the number the pane shows
        // is what went, not the cap: pieces that end at sentences rarely add
        // up to exactly 4,800.
        let cut = sent.count < pieces.count ? sent.reduce(0) { $0 + $1.count } : nil
        return Reply(text: joined(translated), sentCharacters: cut)
    }

    /// The translated text from one answer, or why there is none.
    static func decode(_ data: Data) throws -> String {
        struct Answer: Decodable {
            struct Payload: Decodable { let translatedText: String? }
            let responseData: Payload?
            let responseStatus: Status?
            let responseDetails: String?
            let quotaFinished: Bool?
        }
        /// Sent as a number on success and, on some refusals, as a string.
        enum Status: Decodable, Equatable {
            case code(Int)
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int.self) {
                    self = .code(number)
                } else {
                    self = .code(Int(try container.decode(String.self)) ?? 0)
                }
            }
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw Failure.unreachable
        }
        if answer.quotaFinished == true { throw Failure.quotaExhausted }
        let details = answer.responseDetails ?? ""
        guard answer.responseStatus == .code(200),
              let text = answer.responseData?.translatedText, !text.isEmpty else {
            if details.localizedCaseInsensitiveContains("free translations") { throw Failure.quotaExhausted }
            throw Failure.refused(details)
        }
        return unescapingEntities(text)
    }

    /// Splits text into pieces the service will take, at the largest boundary
    /// that fits: a line, then a sentence, then a word, and only as a last
    /// resort mid-word — a translation cut mid-sentence comes back as two
    /// fragments that no longer agree with each other.
    static func chunks(of text: String, limit: Int = maximumQuery) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed.isEmpty ? [] : [trimmed] }
        var pieces: [String] = []
        var current = ""
        for unit in sentences(of: trimmed) {
            if current.count + unit.count <= limit {
                current += unit
                continue
            }
            if !current.isEmpty { pieces.append(current) }
            current = ""
            if unit.count <= limit {
                current = unit
            } else {
                // A single sentence longer than a query: by words, then by force.
                for word in unit.split(separator: " ", omittingEmptySubsequences: false).map({ $0 + " " }) {
                    if current.count + word.count > limit, !current.isEmpty {
                        pieces.append(current)
                        current = ""
                    }
                    var word = Substring(word)
                    while word.count > limit {
                        pieces.append(String(word.prefix(limit)))
                        word = word.dropFirst(limit)
                    }
                    current += word
                }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func sentences(of text: String) -> [String] {
        var units: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { _, range, _, _ in
            units.append(String(text[range]))
        }
        // Nothing the enumerator recognised as a sentence — keep the text whole.
        return units.isEmpty ? [text] : units
    }

    /// The service answers with HTML entities in plain text — "yo&#39;l" for
    /// "yo'l" — which would otherwise reach the screen as written.
    static func unescapingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let end = text[index...].firstIndex(of: ";"),
               text.distance(from: index, to: end) <= 10 {
                let entity = String(text[text.index(after: index)..<end])
                if let decoded = decode(entity: entity) {
                    result.append(decoded)
                    index = text.index(after: end)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func decode(entity: String) -> Character? {
        switch entity {
        case "amp": return "&"
        case "quot": return "\""
        case "apos": return "'"
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return " "
        default:
            let scalar: UInt32?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                scalar = UInt32(entity.dropFirst(2), radix: 16)
            } else if entity.hasPrefix("#") {
                scalar = UInt32(entity.dropFirst())
            } else {
                scalar = nil
            }
            return scalar.flatMap(Unicode.Scalar.init).map(Character.init)
        }
    }
}
