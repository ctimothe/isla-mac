import Foundation
import XCTest
@testable import IslaKit

/// M1 and M6: what Isla shows for each (track, player variant).
///
/// For every line of `resolved/variants.jsonl` this calls the shipped
/// `OnlineLyrics.lookUp` with that identity, in sequence, through the replay
/// transport, and writes one line of `results/isla-lookups.jsonl`:
///
///     {track_id, variant, identity, outcome (found|none|failed|unreadable|uncached),
///      chosen_id, chosen_ambiguous, chosen_via (get|search), granularity,
///      chosen_granularity, lines, overrun, timed_for_longer,
///      requests:[{key, path, status, cached}], ms}
///
/// The classifier (Python) joins this with its own truth; nothing here decides
/// whether the answer was the right song.
///
/// In sequence, never concurrently: the transport keeps a per-host gap between
/// live requests, and the order Isla asks in is part of what is measured (the
/// exact query, then each search).
///
/// `chosen_id` is recovered, not reported, because `lookUp` returns lines and
/// not the id of the record they came from (see `MatchLab.recover`). `ms` is
/// wall time and the only field that differs between two runs over one cache.
final class LyricMatchLabLookupTests: XCTestCase {
    func testLookups() async throws {
        let root = try MatchLab.requireRoot()
        let variants = try MatchLab.readVariants(root)
        XCTAssertFalse(variants.isEmpty, "resolved/variants.jsonl holds no variants")

        let replay = ReplayTransport(root: root, record: MatchLab.recording, maxLive: MatchLab.maxLiveRequests)
        var rows: [[String: Any]] = []
        var counts: [String: Int] = [:]
        let clock = ContinuousClock()

        for (index, variant) in variants.enumerated() {
            let identity = variant.identity
            replay.beginLookup()
            let started = clock.now
            let outcome = await OnlineLyrics.lookUp(identity) { try await replay.fetch($0) }
            let elapsed = clock.now - started
            let exchanges = replay.takeExchanges()
            let row = Self.row(variant: variant, outcome: outcome, exchanges: exchanges, elapsed: elapsed)
            counts[(row["outcome"] as? String) ?? "?", default: 0] += 1
            rows.append(row)
            if (index + 1) % 50 == 0 {
                print("MATCH-LAB lookups \(index + 1)/\(variants.count)")
            }
        }

        try MatchLab.writeJSONL(rows, to: MatchLab.resultsURL(root, "isla-lookups.jsonl"))
        let tally = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        MatchLab.report(
            section: "lookups",
            summary: "\(rows.count) lookups (\(tally)); live requests \(replay.liveRequests)"
        )
    }

    /// One result line. `uncached` wins over whatever Isla returned when any
    /// request of the lookup missed the cache: a lookup that could not see what
    /// Isla would have seen is not a measurement of Isla.
    static func row(
        variant: MatchVariant, outcome: OnlineLyrics.Outcome, exchanges: [MatchExchange], elapsed: Duration
    ) -> [String: Any] {
        let identity = variant.identity
        var name: String
        var timeline: LyricTimeline?
        switch outcome {
        case .found(let found): name = "found"; timeline = found
        case .none: name = "none"
        case .failed: name = "failed"
        case .unreadable: name = "unreadable"
        }
        if exchanges.contains(where: { $0.kind == .miss }) {
            name = "uncached"
            timeline = nil
        }

        var chosenID: Int?
        var chosenVia: String?
        var ambiguous: [Int] = []
        if let timeline {
            let candidates = MatchLab.candidates(exchanges.map { ($0.path, $0.status, $0.body) })
            if let recovered = MatchLab.recover(target: timeline.lines, identity: identity, candidates: candidates) {
                chosenID = recovered.id
                chosenVia = recovered.via
                ambiguous = recovered.ambiguous
            }
        }

        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let granularity = timeline?.granularity.rawValue
        return [
            "track_id": variant.trackID,
            "variant": variant.variant,
            "identity": [
                "player_id": variant.playerID,
                "title": variant.title,
                "artist": variant.artist,
                "album": variant.album,
                "duration": variant.duration,
            ] as [String: Any],
            "outcome": name,
            "chosen_id": MatchLab.orNull(chosenID),
            "chosen_ambiguous": ambiguous,
            "chosen_via": MatchLab.orNull(chosenVia),
            "granularity": MatchLab.orNull(granularity),
            "chosen_granularity": MatchLab.orNull(granularity),
            "lines": MatchLab.orNull(timeline?.lines.count),
            "overrun": MatchLab.orNull(timeline?.overrun),
            "timed_for_longer": MatchLab.orNull(timeline?.timedForLongerVersion),
            "requests": exchanges.map { exchange -> [String: Any] in
                [
                    "key": exchange.key,
                    "path": exchange.path,
                    "status": MatchLab.orNull(exchange.status),
                    "cached": exchange.cached,
                ]
            },
            "ms": Int((seconds * 1000).rounded()),
        ]
    }
}
