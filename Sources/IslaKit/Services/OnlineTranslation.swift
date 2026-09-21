import Foundation

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

    enum Failure: Error, Equatable {
        /// No answer: offline, a timeout, the service down.
        case unreachable
        /// The anonymous daily allowance is spent.
        case quotaExhausted
        /// The service answered and declined, with its own reason.
        case refused(String)
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

    /// Translates `text`, a piece at a time when it is longer than one query.
    static func translate(_ text: String, from source: TranslationLanguage, to target: TranslationLanguage,
                          session: URLSession = .shared) async throws -> String {
        var translated: [String] = []
        for piece in chunks(of: text) {
            try Task.checkCancellation()
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
        }
        // Scripts written without spaces between sentences are joined without.
        let separator = [TranslationLanguage.chinese, .japanese].contains(target) ? "" : " "
        return translated.joined(separator: separator)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
