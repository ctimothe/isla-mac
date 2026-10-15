import Foundation
import XCTest
@testable import IslaKit

/// M2: Isla's client-side matcher, alone, under the ways players really differ.
///
/// For each track whose *canonical* lookup ran a search, the rows are every
/// search row that lookup received (read back from the cache by the request
/// keys in `isla-lookups.jsonl`), de-duplicated by LRCLIB id in the order
/// received. `OnlineLyrics.bestCandidate(in:for:)` is then asked once for the
/// canonical identity and once per perturbation, and the id of the row it
/// picked is recovered (`MatchLab.recover`, over the same pooled rows).
///
/// No network. The pool is fixed, so a difference between `base_id` and
/// `picked_id` is the matcher's reading of the identity and nothing else:
/// which row exists is held constant. That is the point of the section, and
/// also its limit — it cannot say a perturbation would have *found* a row the
/// canonical queries never returned. M6 (the lookups) covers that.
///
/// Each line of `results/perturbations.jsonl` is
/// `{track_id, perturbation, applicable, base_id, picked_id, rows}`.
/// `applicable` is false when the perturbation leaves the identity unchanged
/// (a "A, B" form for a track credited to exactly "A, B", an apostrophe swap
/// for a title with no apostrophe, a duration perturbation for a track whose
/// length is unknown): such a row repeats the base pick and says nothing about
/// the matcher.
final class LyricMatchLabPerturbationTests: XCTestCase {
    static let perturbations: [String] = [
        // Title suffixes.
        "t-remaster-dash", "t-remaster-paren", "t-radio-edit", "t-feat", "t-official-video",
        "t-from-soundtrack", "t-live-at",
        // Artist forms.
        "a-comma", "a-amp", "a-feat", "a-x", "a-topic", "a-the", "a-semicolon", "a-slash",
        // Characters.
        "c-apostrophe", "c-strip-diacritics", "c-upper", "c-fullwidth", "c-double-space",
        "c-amp-word", "c-yo",
        // Script.
        "s-latin",
        // Duration.
        "d-plus-2.5", "d-plus-3.5", "d-minus-3.5",
    ]

    static let guestArtist = "Guest Artist"

    struct Identity: Equatable {
        var title: String
        var artist: String
        var duration: TimeInterval
    }

    /// The credited artists, split on the ", " the resolver joined them with.
    /// A single artist whose own name contains ", " ("Tyler, The Creator")
    /// splits wrongly, and the joiner perturbations then start from "Tyler";
    /// the matcher cuts at the first comma too, so for this section that is
    /// the same reading Isla takes.
    static func credited(_ artist: String) -> [String] {
        artist.components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The perturbed identity. `A` is the track's first credited artist and
    /// `B` its second if it has one — from the canonical credits, then from
    /// the spotify-style variant, which carries the featured artists too —
    /// else "Guest Artist".
    static func perturbed(
        _ id: String, canonical: MatchVariant, spotify: MatchVariant?, latin: MatchVariant?
    ) -> Identity {
        let base = Identity(title: canonical.title, artist: canonical.artist, duration: canonical.duration)
        let main = credited(canonical.artist)
        let a = main.first ?? canonical.artist
        let b = main.count > 1 ? main[1]
            : (spotify.map { credited($0.artist) }.flatMap { $0.count > 1 ? $0[1] : nil } ?? guestArtist)

        func titled(_ suffix: String) -> Identity {
            var identity = base
            identity.title += suffix
            return identity
        }
        func artisted(_ artist: String) -> Identity {
            var identity = base
            identity.artist = artist
            return identity
        }
        func mapped(_ transform: (String) -> String) -> Identity {
            Identity(title: transform(base.title), artist: transform(base.artist), duration: base.duration)
        }
        func lengthened(_ delta: TimeInterval) -> Identity {
            // An unknown length (zero) stays unknown: +2.5 s would turn "no
            // length" into "a 2.5 s track", which no player reports.
            var identity = base
            if identity.duration > 0 { identity.duration += delta }
            return identity
        }

        switch id {
        case "t-remaster-dash": return titled(" - Remastered 2011")
        case "t-remaster-paren": return titled(" (Remastered 2009)")
        case "t-radio-edit": return titled(" - Radio Edit")
        case "t-feat": return titled(" (feat. \(b))")
        case "t-official-video": return titled(" (Official Video)")
        // How Spotify names a song taken from a film, and how a concert
        // recording arrives: suffixes outside brackets, after " - ".
        case "t-from-soundtrack": return titled(" - From \"A Film\"")
        case "t-live-at": return titled(" - Live at Wembley Stadium")
        case "a-comma": return artisted("\(a), \(b)")
        case "a-amp": return artisted("\(a) & \(b)")
        case "a-feat": return artisted("\(a) feat. \(b)")
        case "a-x": return artisted("\(a) x \(b)")
        case "a-topic": return artisted("\(a) - Topic")
        // Multi-artist tags as ID3v2.4 taggers and some players join them.
        case "a-semicolon": return artisted("\(a); \(b)")
        case "a-slash": return artisted("\(a)/\(b)")
        case "a-the":
            // Added, or removed where the name already opens with it.
            let artist = canonical.artist
            if artist.lowercased().hasPrefix("the ") { return artisted(String(artist.dropFirst(4))) }
            return artisted("The \(artist)")
        case "c-apostrophe":
            return mapped { text in
                // Straight to curly, or curly to straight: a service that
                // writes one against a catalogue that wrote the other.
                if text.contains("'") { return text.replacingOccurrences(of: "'", with: "\u{2019}") }
                return text.replacingOccurrences(of: "\u{2019}", with: "'")
            }
        case "c-strip-diacritics":
            return mapped { text in
                // Decompose and drop the combining marks, which is how a
                // service that stores ASCII-only metadata arrives at "Beyonce".
                var scalars = String.UnicodeScalarView()
                scalars.append(contentsOf: text.decomposedStringWithCanonicalMapping.unicodeScalars
                    .filter { $0.properties.generalCategory != .nonspacingMark })
                return String(scalars)
            }
        case "c-upper": return mapped { $0.uppercased() }
        case "c-fullwidth":
            // Full-width forms inside each name, as a Japanese or Chinese
            // catalogue writes them, but never in the ", " a player joins the
            // names with: no player sends a full-width comma there, and
            // widening it made `primaryArtist` keep every name (adversarial
            // review, 2026-10-15).
            func widened(_ text: String) -> String {
                var scalars = String.UnicodeScalarView()
                for scalar in text.unicodeScalars {
                    if scalar == " " {
                        scalars.append("\u{3000}")
                    } else if (0x21...0x7E).contains(scalar.value), let wide = Unicode.Scalar(scalar.value + 0xFEE0) {
                        scalars.append(wide)
                    } else {
                        scalars.append(scalar)
                    }
                }
                return String(scalars)
            }
            return Identity(
                title: widened(base.title),
                artist: credited(base.artist).map(widened).joined(separator: ", "),
                duration: base.duration
            )
        case "c-double-space": return mapped { $0.replacingOccurrences(of: " ", with: "  ") }
        case "c-amp-word":
            // "Me & You" against "Me and You": catalogues disagree on which.
            var identity = base
            if base.title.contains(" & ") {
                identity.title = base.title.replacingOccurrences(of: " & ", with: " and ")
            } else {
                identity.title = base.title.replacingOccurrences(of: " and ", with: " & ")
            }
            return identity
        case "c-yo":
            // Russian catalogues write "ё" or plain "е" for the same word.
            return mapped { $0.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е") }
        case "s-latin":
            // The Latin form, where the resolver found one that differs; the
            // length stays the canonical one, since this perturbation is
            // about the script and nothing else.
            guard let latin else { return base }
            return Identity(title: latin.title, artist: latin.artist, duration: base.duration)
        case "d-plus-2.5": return lengthened(2.5)
        case "d-plus-3.5": return lengthened(3.5)
        case "d-minus-3.5": return lengthened(-3.5)
        default: return base
        }
    }

    /// The search rows a lookup received, de-duplicated by id in the order
    /// received. Nil when a response it logged is no longer in the cache.
    static func pool(of lookup: MatchLookup, root: URL) -> [MatchRecord]? {
        var seen = Set<Int>()
        var pool: [MatchRecord] = []
        for request in lookup.requests where MatchLab.isSearch(request.path) {
            guard let status = request.status, (200..<300).contains(status) else { continue }
            guard let entry = MatchLab.cacheEntry(root, key: request.key) else { return nil }
            for record in MatchLab.records(path: request.path, status: entry.status, body: entry.body) {
                guard let id = record.id, seen.insert(id).inserted else { continue }
                pool.append(record)
            }
        }
        return pool
    }

    /// The id `bestCandidate` picks from the pool, or nil when it picks nothing.
    static func pick(pool: [MatchRecord], identity: LocalTrackIdentity) -> Int? {
        guard let match = OnlineLyrics.bestCandidate(in: pool.map(MatchLab.searchRow), for: identity).match else {
            return nil
        }
        let candidates = pool.enumerated().map {
            MatchLab.Candidate(exchange: 0, row: $0.offset, via: "search", record: $0.element)
        }
        return MatchLab.recover(target: match.timeline.lines, identity: identity, candidates: candidates)?.id
    }

    func testPerturbations() throws {
        let root = try MatchLab.requireRoot()
        let variants = try MatchLab.readVariants(root)
        let lookups = try MatchLab.readLookups(root)

        var byTrack: [String: [String: MatchVariant]] = [:]
        for variant in variants { byTrack[variant.trackID, default: [:]][variant.variant] = variant }

        var rows: [[String: Any]] = []
        var tracks = 0
        var skippedNoSearch = 0
        var skippedUncached = 0
        var skippedNoVariant = 0
        var skippedEmptyPool = 0
        var applicable: [String: Int] = [:]
        var moved: [String: Int] = [:]
        var lost: [String: Int] = [:]

        for lookup in lookups where lookup.variant == "canonical" {
            guard lookup.requests.contains(where: { MatchLab.isSearch($0.path) }) else { skippedNoSearch += 1; continue }
            guard lookup.outcome != "uncached", let pool = Self.pool(of: lookup, root: root) else {
                skippedUncached += 1
                continue
            }
            // A search that returned no rows at all (LRCLIB has nothing for the
            // song) holds no pick to perturb: every row would be null on both
            // sides and say nothing about the matcher.
            guard !pool.isEmpty else { skippedEmptyPool += 1; continue }
            guard let canonical = byTrack[lookup.trackID]?["canonical"] else { skippedNoVariant += 1; continue }
            let spotify = byTrack[lookup.trackID]?["spotify-style"]
            let latin = byTrack[lookup.trackID]?["latin-alt"]
            tracks += 1

            let baseIdentity = canonical.identity
            let baseID = Self.pick(pool: pool, identity: baseIdentity)
            let base = Identity(title: canonical.title, artist: canonical.artist, duration: canonical.duration)

            for id in Self.perturbations {
                let identity = Self.perturbed(id, canonical: canonical, spotify: spotify, latin: latin)
                let changes = identity != base
                var pickedID = baseID
                if changes {
                    pickedID = Self.pick(
                        pool: pool,
                        identity: LocalTrackIdentity(
                            playerID: canonical.playerID, title: identity.title, artist: identity.artist,
                            album: canonical.album, duration: identity.duration, recordingID: nil
                        )
                    )
                    applicable[id, default: 0] += 1
                    if pickedID != baseID { moved[id, default: 0] += 1 }
                    if pickedID == nil, baseID != nil { lost[id, default: 0] += 1 }
                }
                rows.append([
                    "track_id": lookup.trackID,
                    "perturbation": id,
                    "applicable": changes,
                    "base_id": MatchLab.orNull(baseID),
                    "picked_id": MatchLab.orNull(pickedID),
                    "rows": pool.count,
                ])
            }
        }

        try MatchLab.writeJSONL(rows, to: MatchLab.resultsURL(root, "perturbations.jsonl"))
        let detail = Self.perturbations.map { id in
            "\(id) \(moved[id] ?? 0)/\(applicable[id] ?? 0)"
        }.joined(separator: ", ")
        MatchLab.report(
            section: "perturbations",
            summary: "\(tracks) tracks, \(rows.count) rows (skipped: no search \(skippedNoSearch), uncached \(skippedUncached), "
                + "empty pool \(skippedEmptyPool), no canonical variant \(skippedNoVariant)); pick changed/applicable: \(detail); "
                + "pick lost: \(lost.values.reduce(0, +))"
        )
    }
}
