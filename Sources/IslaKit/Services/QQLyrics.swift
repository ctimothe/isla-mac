import Foundation
import Compression

/// QQ Music word-synced lyrics: search, QRC download, decrypt, parse.
///
/// The tier that rescues tracks the community TTML database never had and
/// Kugou's search misses. Anonymous and keyless like every other tier: QQ's
/// desktop search and the PC client's lyric endpoint need no account, only
/// the browser referer and user agent they expect.
enum QQLyrics {
    struct Song {
        /// Numeric `songid`: what `lyric_download.fcg` takes as `musicid`.
        let songID: String
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval?
        let isrc: String?
    }

    static let searchURL = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
    static let fallbackSearchURL = URL(string: "https://shc.y.qq.com/soso/fcgi-bin/search_for_qq_cp")!
    static let downloadURL = URL(string: "https://c.y.qq.com/qqmusic/fcgi-bin/lyric_download.fcg")!
    static let referer = "https://c.y.qq.com/"
    // QQ's web API turns away non-browser clients; this is the same desktop
    // identifier the PC client sends, not a user impersonation.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /// Desktop search, page one, then page two, then the legacy endpoint —
    /// each step only when the previous answered nothing usable.
    static func searchSongs(title: String, artist: String, session: URLSession) async -> [Song] {
        let query = artist.isEmpty ? title : "\(artist) - \(title)"
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        for page in [1, 2] {
            if let songs = try? await searchPage(query, page: page, session: session), !songs.isEmpty {
                return songs
            }
        }
        return (try? await searchFallback(query, session: session)) ?? []
    }

    private static func searchPage(_ query: String, page: Int, session: URLSession) async throws -> [Song] {
        // The PC client's own search, per the lyricify provider port: one
        // method call carrying page size, page number and query.
        let payload: [String: Any] = [
            "music.search.SearchCgiService": [
                "method": "DoSearchForQQMusicDesktop",
                "module": "music.search.SearchCgiService",
                "param": [
                    "num_per_page": 20,
                    "page_num": page,
                    "query": query,
                    "search_type": 0,
                ],
            ]
        ]
        var request = URLRequest(url: searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parseSearchResponse(data)
    }

    private static func searchFallback(_ query: String, session: URLSession) async throws -> [Song] {
        var components = URLComponents(url: fallbackSearchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "w", value: query),
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "n", value: "20"),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parseSearchResponse(data)
    }

    /// The `musicu.fcg` answer nests the hit list several levels deep and the
    /// nesting has drifted before, so several known paths are tried rather
    /// than one struct that breaks on the next site change.
    static func parseSearchResponse(_ data: Data) -> [Song] {
        let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            ?? Self.rootStrippingCallback(data)
        guard let root else { return [] }
        let paths: [[String]] = [
            ["music.search.SearchCgiService", "data", "body", "song", "list"],
            ["music.search.SearchCgiService", "data", "song", "list"],
            ["data", "body", "song", "list"],
            ["data", "song", "list"],
            ["body", "song", "list"],
        ]
        for path in paths {
            var node: Any? = root
            for key in path { node = (node as? [String: Any])?[key] }
            if let list = node as? [[String: Any]] {
                let songs = list.compactMap(parseSong)
                if !songs.isEmpty { return songs }
            }
        }
        return []
    }

    /// The legacy endpoint sometimes answers JSONP; the payload is still JSON
    /// between the first `{` and the last `}`.
    private static func rootStrippingCallback(_ data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
    }

    private static func parseSong(_ dict: [String: Any]) -> Song? {
        guard let songID = stringField(dict, keys: ["songid", "songId", "id", "musicid", "musicId"]),
              !songID.isEmpty else { return nil }
        return Song(
            songID: songID,
            title: stringField(dict, keys: ["songname", "songName", "title", "name"]) ?? "",
            artist: singerName(dict),
            album: stringField(dict, keys: ["albumname", "albumName", "album"]) ?? "",
            duration: songDuration(dict),
            isrc: stringField(dict, keys: ["isrc", "ISRC"])
        )
    }

    private static func stringField(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let text = dict[key] as? String, !text.isEmpty { return text }
            // QQ's shapes disagree about numbers: an id or duration may
            // arrive numeric or string-encoded, so both decode rather than
            // the hit degrading to absent.
            if let number = dict[key] as? Int { return String(number) }
            if let number = dict[key] as? Double {
                return number.truncatingRemainder(dividingBy: 1) == 0
                    ? String(Int(number)) : String(number)
            }
        }
        return nil
    }

    private static func singerName(_ dict: [String: Any]) -> String {
        if let singers = dict["singer"] as? [[String: Any]] {
            let names = singers.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            if !names.isEmpty { return names.joined(separator: ", ") }
        }
        if let singer = dict["singer"] as? [String: Any],
           let name = singer["name"] as? String, !name.isEmpty { return name }
        return stringField(dict, keys: ["singer", "singername", "singerName", "artist", "artistName"]) ?? ""
    }

    private static func songDuration(_ dict: [String: Any]) -> TimeInterval? {
        // `interval` is the documented seconds field; anything implausibly
        // large is the same number in milliseconds from a variant shape. A
        // string-encoded number is still a number — only a truly absent or
        // unparsable value degrades to nil.
        for key in ["interval", "duration", "playtime"] {
            let raw: Int?
            if let int = dict[key] as? Int {
                raw = int
            } else if let double = dict[key] as? Double {
                raw = Int(double)
            } else if let text = dict[key] as? String,
                      let double = Double(text.trimmingCharacters(in: .whitespaces)) {
                raw = Int(double)
            } else {
                continue
            }
            guard let value = raw else { continue }
            return value >= 20_000 ? TimeInterval(value) / 1000 : TimeInterval(value)
        }
        return nil
    }

    // MARK: - Download

    /// The PC client's lyric download: form-encoded, `lrctype=4` asking for
    /// the word-synced QRC. Answers the decrypted QRC body, ready for
    /// `WordSyncedLyrics.parseQRCBody`.
    static func fetchLyric(songID: String, session: URLSession) async -> String? {
        var request = URLRequest(url: downloadURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("version=15&miniversion=82&lrctype=4&musicid=\(songID)".utf8)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let encrypted = parseDownloadResponse(data),
              let xml = decryptQRC(encrypted) else { return nil }
        return extractQRCBody(from: xml)
    }

    /// The answer is XML with the encrypted payload as hex inside `contentts`
    /// (word-synced), falling back to `content`. QQ wraps the whole answer in
    /// an HTML comment, and newer answers wrap the hex in CDATA.
    static func parseDownloadResponse(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "") else { return nil }
        for tag in ["contentts", "content"] {
            // `[\s>]` after the name: a bare `[^>]*` would also open on
            // `<contentts>` when looking for `content`. The payload is hex
            // but travels wrapped in CDATA and comments that may span lines,
            // so `.` has to match newlines too.
            guard let inner = firstMatch(of: "<\(tag)(?:\\s[^>]*)?>(.*?)</\(tag)>", in: text, dotMatchesLineSeparators: true),
                  !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let hex = inner
                .replacingOccurrences(of: "<![CDATA[", with: "")
                .replacingOccurrences(of: "]]>", with: "")
                .filter(\.isHexDigit)
            guard !hex.isEmpty, hex.count % 2 == 0 else { continue }
            var bytes = Data(capacity: hex.count / 2)
            var cursor = hex.startIndex
            while cursor < hex.endIndex {
                let next = hex.index(cursor, offsetBy: 2)
                guard let byte = UInt8(hex[cursor..<next], radix: 16) else { return nil }
                bytes.append(byte)
                cursor = next
            }
            return bytes
        }
        return nil
    }

    /// The decrypted payload is XML carrying the QRC text in a `LyricContent`
    /// attribute; without one, a plaintext that already looks like QRC is
    /// used as-is rather than dropped.
    static func extractQRCBody(from xml: String) -> String? {
        if let content = firstMatch(of: #"LyricContent="(.*?)""#, in: xml, dotMatchesLineSeparators: true) {
            return decodeEntities(content)
        }
        return xml.range(of: #"\[\d+,\d+\]"#, options: .regularExpression) != nil ? xml : nil
    }

    private static func firstMatch(of pattern: String, in text: String, dotMatchesLineSeparators: Bool = false) -> String? {
        var options: NSRegularExpression.Options = []
        if dotMatchesLineSeparators { options.insert(.dotMatchesLineSeparators) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - QRC decrypt

    /// Triple-DES in the EDE order the PC client applies (decrypt, encrypt,
    /// decrypt) over three static vendor keys, then zlib inflate — a port of
    /// the jixunmoe-go/qrc decoder, whose DES is bit-exact rather than
    /// standard (see `QQDES`). File-shaped payloads additionally carry an
    /// 11-byte QMC header, stripped before the DES pass like the reference.
    static func decryptQRC(_ data: Data) -> String? {
        var bytes = [UInt8](data)
        if startsWithQMCMagic(bytes) {
            bytes = Array(qmcDecode(Array(bytes.dropFirst(qqmcMagic.count))))
        }
        guard !bytes.isEmpty, bytes.count % 8 == 0,
              tripleDES(&bytes, encrypt: false) else { return nil }
        // Apple's ZLIB codec is the raw deflate stream, so a carried zlib
        // header goes before it will inflate — the same strip KRC needs.
        // Raw deflate can itself start with 0x78, so a failed strip is
        // retried unstripped rather than giving up on the payload.
        let attempts = bytes.first == 0x78 ? [Array(bytes.dropFirst(2)), bytes] : [bytes]
        for deflate in attempts {
            if let inflated = inflate(deflate),
               let text = String(bytes: inflated, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    /// The inverse of the above, for fixtures and the round-trip test only:
    /// real payloads arrive pre-padded from QQ. Zero-pads to the DES block,
    /// which the inflate pass never reaches past the stream end.
    static func encryptQRC(_ plaintext: String) -> Data? {
        let input = [UInt8](plaintext.utf8)
        guard !input.isEmpty else { return nil }
        var deflated = [UInt8](repeating: 0, count: input.count * 2 + 64)
        let written = input.withUnsafeBufferPointer { source in
            compression_encode_buffer(
                &deflated, deflated.count, source.baseAddress!, input.count, nil, COMPRESSION_ZLIB
            )
        }
        guard written > 0 else { return nil }
        var bytes = Array(deflated[0..<written])
        bytes += [UInt8](repeating: 0, count: (8 - bytes.count % 8) % 8)
        guard tripleDES(&bytes, encrypt: true) else { return nil }
        return Data(bytes)
    }

    private static func tripleDES(_ bytes: inout [UInt8], encrypt: Bool) -> Bool {
        // Decode is D-E-D over k1/k2/k3, exactly as the PC client and every
        // third-party decoder applies it. Encode is therefore its mirror —
        // E over k3, D over k2, E over k1 — reversing both key order and mode.
        let steps: [([UInt8], Bool)] = encrypt
            ? [(qqDESKey3, true), (qqDESKey2, false), (qqDESKey1, true)]
            : [(qqDESKey1, false), (qqDESKey2, true), (qqDESKey3, false)]
        for (key, mode) in steps {
            guard QQDES.transform(&bytes, key: key, encrypt: mode) else { return false }
        }
        return true
    }

    /// Single-DES pass with an arbitrary key, exposed for the known-answer
    /// test that pins this port to the reference implementation.
    static func desCrypt(_ data: Data, key: Data, encrypt: Bool) -> Data? {
        var bytes = [UInt8](data)
        guard QQDES.transform(&bytes, key: [UInt8](key), encrypt: encrypt) else { return nil }
        return Data(bytes)
    }

    private static let qqDESKey1 = [UInt8]("!@#)(NHL".utf8)
    private static let qqDESKey2 = [UInt8]("123ZXC!@".utf8)
    private static let qqDESKey3 = [UInt8]("!@#)(*$%".utf8)

    private static let qqmcMagic: [UInt8] = [0x98, 0x25, 0xB0, 0xAC, 0xE3, 0x02, 0x83, 0x68, 0xE8, 0xFC, 0x6C]

    private static func startsWithQMCMagic(_ bytes: [UInt8]) -> Bool {
        bytes.count > qqmcMagic.count && bytes.prefix(qqmcMagic.count).elementsEqual(qqmcMagic)
    }

    /// The QMC stream cipher the desktop client wraps files in: a 128-byte
    /// keystream indexed by offset. Untouched network payloads never take
    /// this path; it exists for file-shaped ones, like the reference.
    private static let qmcKey: [UInt8] = [
        0xC3, 0x4A, 0xD6, 0xCA, 0x90, 0x67, 0xF7, 0x52,
        0xD8, 0xA1, 0x66, 0x62, 0x9F, 0x5B, 0x09, 0x00,
        0xC3, 0x5E, 0x95, 0x23, 0x9F, 0x13, 0x11, 0x7E,
        0xD8, 0x92, 0x3F, 0xBC, 0x90, 0xBB, 0x74, 0x0E,
        0xC3, 0x47, 0x74, 0x3D, 0x90, 0xAA, 0x3F, 0x51,
        0xD8, 0xF4, 0x11, 0x84, 0x9F, 0xDE, 0x95, 0x1D,
        0xC3, 0xC6, 0x09, 0xD5, 0x9F, 0xFA, 0x66, 0xF9,
        0xD8, 0xF0, 0xF7, 0xA0, 0x90, 0xA1, 0xD6, 0xF3,
        0xC3, 0xF3, 0xD6, 0xA1, 0x90, 0xA0, 0xF7, 0xF0,
        0xD8, 0xF9, 0x66, 0xFA, 0x9F, 0xD5, 0x09, 0xC6,
        0xC3, 0x1D, 0x95, 0xDE, 0x9F, 0x84, 0x11, 0xF4,
        0xD8, 0x51, 0x3F, 0xAA, 0x90, 0x3D, 0x74, 0x47,
        0xC3, 0x0E, 0x74, 0xBB, 0x90, 0xBC, 0x3F, 0x92,
        0xD8, 0x7E, 0x11, 0x13, 0x9F, 0x23, 0x95, 0x5E,
        0xC3, 0x00, 0x09, 0x5B, 0x9F, 0x62, 0x66, 0xA1,
        0xD8, 0x52, 0xF7, 0x67, 0x90, 0xCA, 0xD6, 0x4A,
    ]

    private static func qmcDecode(_ bytes: [UInt8]) -> [UInt8] {
        bytes.enumerated().map { offset, byte in
            let key = offset > 0x7FFF ? qmcKey[(offset % 0x7FFF) & 0x7F] : qmcKey[offset & 0x7F]
            return byte ^ key
        }
    }

    private static func inflate(_ deflate: [UInt8]) -> [UInt8]? {
        guard !deflate.isEmpty else { return nil }
        var capacity = max(deflate.count * 8, 1 << 16)
        for _ in 0..<4 {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = output.withUnsafeMutableBufferPointer { out in
                deflate.withUnsafeBufferPointer { source in
                    compression_decode_buffer(
                        out.baseAddress!, capacity,
                        source.baseAddress!, deflate.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            // A exactly-full buffer may be truncated output, not a complete
            // stream: grow and retry rather than serve half an XML file.
            if written > 0, written < capacity { return Array(output[0..<written]) }
            capacity *= 2
        }
        return nil
    }
}

/// The vendor DES the QRC format is encrypted with: bit-exact with the
/// jixunmoe-go/qrc port of QQMusicCommon.dll, and deliberately *not* standard
/// DES — the key-schedule rotation keeps its word left-aligned (`& 0xFFFFFFF0`
/// where FIPS-46 would reduce mod 2^28), so CommonCrypto answers a different
/// cipher. Ported operation for operation; the known-answer test pins it.
enum QQDES {
    static func transform(_ bytes: inout [UInt8], key: [UInt8], encrypt: Bool) -> Bool {
        guard !bytes.isEmpty, bytes.count % 8 == 0, key.count >= 8 else { return false }
        var k: UInt64 = 0
        for (index, byte) in key.prefix(8).enumerated() {
            k |= UInt64(byte) << (8 * index)
        }
        let subkeys = schedule(k, encrypt: encrypt)
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            var block: UInt64 = 0
            for index in 0..<8 {
                block |= UInt64(bytes[offset + index]) << (8 * index)
            }
            let encrypted = crypt(block, subkeys: subkeys)
            for index in 0..<8 {
                bytes[offset + index] = UInt8((encrypted >> (8 * index)) & 0xFF)
            }
            offset += 8
        }
        return true
    }

    private static func crypt(_ block: UInt64, subkeys: [UInt64]) -> UInt64 {
        var state = mapU64(block, ip)
        for key in subkeys { state = cryptProc(state, key) }
        return mapU64(swap(state), ipInv)
    }

    private static func cryptProc(_ state: UInt64, _ key: UInt64) -> UInt64 {
        let hi = hi32(state), lo = lo32(state)
        var expanded = mapU64(makeU64(hi, hi), keyExpansion)
        expanded ^= key
        var nextLo = sbox(expanded)
        nextLo = mapU32Bits(nextLo, pBox)
        nextLo ^= lo
        return makeU64(nextLo, hi)
    }

    private static func sbox(_ state: UInt64) -> UInt32 {
        var result: UInt32 = 0
        for (index, shift) in largeStateShifts.enumerated() {
            result = (result << 4) | UInt32(sboxes[index][Int((state >> UInt64(shift)) & 0x3F)])
        }
        return result
    }

    private static func schedule(_ key: UInt64, encrypt: Bool) -> [UInt64] {
        let param = mapU64(key, keyPermutationTable)
        var c = lo32(param), d = hi32(param)
        var subkeys = [UInt64](repeating: 0, count: 16)
        for (round, shift) in keyShifts.enumerated() {
            updateParam(&c, shift: shift)
            updateParam(&d, shift: shift)
            subkeys[encrypt ? round : 15 - round] = mapU64(makeU64(d, c), keyCompression)
        }
        return subkeys
    }

    /// The off-spec rotation: the 28-bit halves live left-aligned and the
    /// wrap keeps them there, instead of reducing into 28 bits.
    private static func updateParam(_ param: inout UInt32, shift: UInt8) {
        let right = 28 - shift
        param = (param &<< UInt32(shift)) | ((param &>> UInt32(right)) & 0xFFFF_FFF0)
    }

    private static func makeU64(_ hi: UInt32, _ lo: UInt32) -> UInt64 {
        UInt64(hi) << 32 | UInt64(lo)
    }

    private static func swap(_ value: UInt64) -> UInt64 {
        (value >> 32) | (value << 32)
    }

    private static func lo32(_ value: UInt64) -> UInt32 { UInt32(value & 0xFFFF_FFFF) }
    private static func hi32(_ value: UInt64) -> UInt32 { UInt32(value >> 32) }

    private static func bitMask(_ index: UInt8) -> UInt64 {
        index < 32
            ? UInt64(0x8000_0000) >> UInt64(index)
            : UInt64(0x8000_0000_0000_0000) >> UInt64(index - 32)
    }

    private static func mapBit(_ result: inout UInt64, _ src: UInt64, check: UInt8, set: UInt8) {
        if bitMask(check & 0x3F) & src != 0 {
            result |= bitMask(set & 0x3F)
        }
    }

    /// First half of the table feeds the low word, second half the high.
    private static func mapU64(_ src: UInt64, _ table: [UInt8]) -> UInt64 {
        let mid = table.count / 2
        var lo: UInt64 = 0, hi: UInt64 = 0
        for (index, entry) in table[..<mid].enumerated() {
            mapBit(&lo, src, check: entry, set: UInt8(index))
        }
        for (index, entry) in table[mid...].enumerated() {
            mapBit(&hi, src, check: entry, set: UInt8(index))
        }
        return makeU64(UInt32(hi), UInt32(lo))
    }

    private static func mapU32Bits(_ src: UInt32, _ table: [UInt8]) -> UInt32 {
        var result: UInt64 = 0
        for (index, entry) in table.enumerated() {
            mapBit(&result, UInt64(src), check: entry, set: UInt8(index))
        }
        return UInt32(result & 0xFFFF_FFFF)
    }

    // MARK: - Tables (standard permutations and S-boxes; the cipher's quirk
    // is in the schedule above, not here)

    private static let keyShifts: [UInt8] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]

    private static let largeStateShifts: [UInt8] = [0x1A, 0x14, 0x0E, 0x08, 0x3A, 0x34, 0x2E, 0x28]

    private static let sboxes: [[UInt8]] = [
        [14, 0, 4, 15, 13, 7, 1, 4, 2, 14, 15, 2, 11, 13, 8, 1, 3, 10, 10, 6, 6, 12, 12, 11, 5, 9, 9, 5, 0, 3, 7, 8, 4, 15, 1, 12, 14, 8, 8, 2, 13, 4, 6, 9, 2, 1, 11, 7, 15, 5, 12, 11, 9, 3, 7, 14, 3, 10, 10, 0, 5, 6, 0, 13],
        [15, 3, 1, 13, 8, 4, 14, 7, 6, 15, 11, 2, 3, 8, 4, 15, 9, 12, 7, 0, 2, 1, 13, 10, 12, 6, 0, 9, 5, 11, 10, 5, 0, 13, 14, 8, 7, 10, 11, 1, 10, 3, 4, 15, 13, 4, 1, 2, 5, 11, 8, 6, 12, 7, 6, 12, 9, 0, 3, 5, 2, 14, 15, 9],
        [10, 13, 0, 7, 9, 0, 14, 9, 6, 3, 3, 4, 15, 6, 5, 10, 1, 2, 13, 8, 12, 5, 7, 14, 11, 12, 4, 11, 2, 15, 8, 1, 13, 1, 6, 10, 4, 13, 9, 0, 8, 6, 15, 9, 3, 8, 0, 7, 11, 4, 1, 15, 2, 14, 12, 3, 5, 11, 10, 5, 14, 2, 7, 12],
        [7, 13, 13, 8, 14, 11, 3, 5, 0, 6, 6, 15, 9, 0, 10, 3, 1, 4, 2, 7, 8, 2, 5, 12, 11, 1, 12, 10, 4, 14, 15, 9, 10, 3, 6, 15, 9, 0, 0, 6, 12, 10, 11, 10, 7, 13, 13, 8, 15, 9, 1, 4, 3, 5, 14, 11, 5, 12, 2, 7, 8, 2, 4, 14],
        [2, 14, 12, 11, 4, 2, 1, 12, 7, 4, 10, 7, 11, 13, 6, 1, 8, 5, 5, 0, 3, 15, 15, 10, 13, 3, 0, 9, 14, 8, 9, 6, 4, 11, 2, 8, 1, 12, 11, 7, 10, 1, 13, 14, 7, 2, 8, 13, 15, 6, 9, 15, 12, 0, 5, 9, 6, 10, 3, 4, 0, 5, 14, 3],
        [12, 10, 1, 15, 10, 4, 15, 2, 9, 7, 2, 12, 6, 9, 8, 5, 0, 6, 13, 1, 3, 13, 4, 14, 14, 0, 7, 11, 5, 3, 11, 8, 9, 4, 14, 3, 15, 2, 5, 12, 2, 9, 8, 5, 12, 15, 3, 10, 7, 11, 0, 14, 4, 1, 10, 7, 1, 6, 13, 0, 11, 8, 6, 13],
        [4, 13, 11, 0, 2, 11, 14, 7, 15, 4, 0, 9, 8, 1, 13, 10, 3, 14, 12, 3, 9, 5, 7, 12, 5, 2, 10, 15, 6, 8, 1, 6, 1, 6, 4, 11, 11, 13, 13, 8, 12, 1, 3, 4, 7, 10, 14, 7, 10, 9, 15, 5, 6, 0, 8, 15, 0, 14, 5, 2, 9, 3, 2, 12],
        [13, 1, 2, 15, 8, 13, 4, 8, 6, 10, 15, 3, 11, 7, 1, 4, 10, 12, 9, 5, 3, 6, 14, 11, 5, 0, 0, 14, 12, 9, 7, 2, 7, 2, 11, 1, 4, 14, 1, 7, 9, 4, 12, 10, 14, 8, 2, 13, 0, 15, 6, 12, 10, 9, 13, 0, 15, 3, 3, 5, 5, 6, 8, 11],
    ]

    private static let pBox: [UInt8] = [
        0x0F, 0x06, 0x13, 0x14, 0x1C, 0x0B, 0x1B, 0x10, 0x00, 0x0E, 0x16, 0x19, 0x04, 0x11, 0x1E, 0x09,
        0x01, 0x07, 0x17, 0x0D, 0x1F, 0x1A, 0x02, 0x08, 0x12, 0x0C, 0x1D, 0x05, 0x15, 0x0A, 0x03, 0x18,
    ]

    private static let ip: [UInt8] = [
        0x39, 0x31, 0x29, 0x21, 0x19, 0x11, 0x09, 0x01, 0x3B, 0x33, 0x2B, 0x23, 0x1B, 0x13, 0x0B, 0x03,
        0x3D, 0x35, 0x2D, 0x25, 0x1D, 0x15, 0x0D, 0x05, 0x3F, 0x37, 0x2F, 0x27, 0x1F, 0x17, 0x0F, 0x07,
        0x38, 0x30, 0x28, 0x20, 0x18, 0x10, 0x08, 0x00, 0x3A, 0x32, 0x2A, 0x22, 0x1A, 0x12, 0x0A, 0x02,
        0x3C, 0x34, 0x2C, 0x24, 0x1C, 0x14, 0x0C, 0x04, 0x3E, 0x36, 0x2E, 0x26, 0x1E, 0x16, 0x0E, 0x06,
    ]

    private static let ipInv: [UInt8] = [
        0x27, 0x07, 0x2F, 0x0F, 0x37, 0x17, 0x3F, 0x1F, 0x26, 0x06, 0x2E, 0x0E, 0x36, 0x16, 0x3E, 0x1E,
        0x25, 0x05, 0x2D, 0x0D, 0x35, 0x15, 0x3D, 0x1D, 0x24, 0x04, 0x2C, 0x0C, 0x34, 0x14, 0x3C, 0x1C,
        0x23, 0x03, 0x2B, 0x0B, 0x33, 0x13, 0x3B, 0x1B, 0x22, 0x02, 0x2A, 0x0A, 0x32, 0x12, 0x3A, 0x1A,
        0x21, 0x01, 0x29, 0x09, 0x31, 0x11, 0x39, 0x19, 0x20, 0x00, 0x28, 0x08, 0x30, 0x10, 0x38, 0x18,
    ]

    private static let keyPermutationTable: [UInt8] = [
        0x38, 0x30, 0x28, 0x20, 0x18, 0x10, 0x08, 0x00, 0x39, 0x31, 0x29, 0x21, 0x19, 0x11, 0x09, 0x01,
        0x3A, 0x32, 0x2A, 0x22, 0x1A, 0x12, 0x0A, 0x02, 0x3B, 0x33, 0x2B, 0x23, 0x3E, 0x36, 0x2E, 0x26,
        0x1E, 0x16, 0x0E, 0x06, 0x3D, 0x35, 0x2D, 0x25, 0x1D, 0x15, 0x0D, 0x05, 0x3C, 0x34, 0x2C, 0x24,
        0x1C, 0x14, 0x0C, 0x04, 0x1B, 0x13, 0x0B, 0x03,
    ]

    private static let keyCompression: [UInt8] = [
        0x0D, 0x10, 0x0A, 0x17, 0x00, 0x04, 0x02, 0x1B, 0x0E, 0x05, 0x14, 0x09, 0x16, 0x12, 0x0B, 0x03,
        0x19, 0x07, 0x0F, 0x06, 0x1A, 0x13, 0x0C, 0x01, 0x2D, 0x38, 0x23, 0x29, 0x33, 0x3B, 0x22, 0x2C,
        0x37, 0x31, 0x25, 0x34, 0x30, 0x35, 0x2B, 0x3C, 0x26, 0x39, 0x32, 0x2E, 0x36, 0x28, 0x21, 0x24,
    ]

    private static let keyExpansion: [UInt8] = [
        0x1F, 0x00, 0x01, 0x02, 0x03, 0x04, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x07, 0x08, 0x09, 0x0A,
        0x0B, 0x0C, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x13, 0x14,
        0x15, 0x16, 0x17, 0x18, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x00,
    ]
}
