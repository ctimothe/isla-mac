import CoreAudio
import Foundation
import Synchronization
import XCTest
@testable import IslaKit

/// L3, L4 and L7 of the Lyrics Accuracy Lab: when a line can reach the
/// screen given a frame grid, how exactly the boundary timer is armed and how
/// late the machine really runs it, and what lead all of that adds up to.
/// Skipped unless `ISLA_LYRIC_CORPUS` is set.
@MainActor
final class LyricAccuracyLabClockTests: XCTestCase {

    // MARK: - L3 frame-grid activation

    /// A display draws on a grid. For every line, the first frame on which the
    /// real `LyricSweep.position` (lead included) names it, against the moment
    /// it was due: `line.at - lead`. The clock itself is taken as perfect here,
    /// so this isolates what the frame grid alone costs.
    func testL3FrameGridActivation() throws {
        let accepted = try LyricLab.acceptedTracks()
        let lead = LyricSweep.lead(precisionSync: false, userOffset: 0)
        var section: [String: Any] = ["lead": lead, "tracks": accepted.count]
        var worstVerdict = "pass"

        for hz in [60.0, 120.0] {
            let period = 1 / hz
            var errors: [Double] = []
            var perCategory: [String: [Double]] = [:]
            var skipped = 0, skippedTracks = Set<Int>(), shadowed = 0, doubled = 0
            var preRoll = 0, preRollNeverShown = 0, unreached = 0, unreachedTracks = Set<Int>()
            var outOfBound = 0
            var minGap = Double.infinity

            for (track, lines) in accepted {
                var random = LabRandom(seed: UInt64(truncatingIfNeeded: track.id) &* 31 &+ UInt64(hz))
                let phase = random.unit() * period
                let duration = track.duration > 0 ? track.duration : lines.last!.at + 6
                var activations = [Int](repeating: 0, count: lines.count)
                var previous: Int?
                var frame = 0
                for i in lines.indices.dropFirst() { minGap = min(minGap, lines[i].at - lines[i - 1].at) }
                while true {
                    let t = phase + Double(frame) * period
                    if t > duration { break }
                    frame += 1
                    let index = LyricSweep.index(
                        in: lines, at: LyricSweep.position(t, precisionSync: false, userOffset: 0)
                    )
                    guard let j = index, j != previous else { continue }
                    let from = (previous ?? -1) + 1
                    if j < from { doubled += 1 }
                    // Lines passed over on the way to this one.
                    if j > from {
                        for m in from..<j {
                            if lines[m].at == lines[m + 1].at {
                                shadowed += 1
                            } else if previous == nil, lines[m].at - lead < phase {
                                preRollNeverShown += 1
                            } else {
                                skipped += 1
                                skippedTracks.insert(track.id)
                            }
                        }
                    }
                    activations[j] += 1
                    let due = lines[j].at - lead
                    if due < 0 {
                        // Due before the track starts: shown on the first frame
                        // of playback, which is as early as anything can be.
                        preRoll += 1
                    } else {
                        let error = t - due
                        errors.append(error)
                        perCategory[track.category, default: []].append(error)
                        if error > period + 1e-9 || error < -1e-9 { outOfBound += 1 }
                    }
                    previous = j
                }
                for (j, count) in activations.enumerated() {
                    if count > 1 { doubled += count - 1 }
                    if count == 0, lines[j].at - lead > duration {
                        unreached += 1
                        unreachedTracks.insert(track.id)
                    }
                }
            }
            if outOfBound > 0 { LyricLab.finding("L3 \(Int(hz)) Hz: \(outOfBound) activations later than a frame") }
            let verdict = outOfBound > 0 || doubled > 0 ? "fail" : (skipped + unreached > 0 ? "concern" : "pass")
            if verdict == "fail" || (verdict == "concern" && worstVerdict == "pass") { worstVerdict = verdict }
            section["\(Int(hz))Hz"] = [
                "periodMs": period * 1000,
                "activationErrorMs": LabStats.summary(errors, scale: 1000),
                "perCategoryErrorMs": perCategory.mapValues { LabStats.summary($0, scale: 1000) },
                "activationsLaterThanOneFrame": outOfBound,
                "skippedLinesTwoBoundariesInOneFrame": skipped,
                "skippedTrackIDs": skippedTracks.sorted(),
                "shadowedLinesDuplicateStamp": shadowed,
                "doubledLines": doubled,
                "preRollLinesShownAtPlaybackStart": preRoll,
                "preRollLinesNeverShown": preRollNeverShown,
                "linesUnreachedBeyondTrackEnd": unreached,
                "unreachedTrackIDs": unreachedTracks.sorted(),
                "smallestGapBetweenLinesMs": minGap.isFinite ? minGap * 1000 : Double.nan,
            ]
        }
        section["verdict"] = worstVerdict
        let sixty = (section["60Hz"] as? [String: Any])?["activationErrorMs"] as? [String: Any]
        let twenty = (section["120Hz"] as? [String: Any])?["activationErrorMs"] as? [String: Any]
        section["summary"] = "frame-grid error 60 Hz p50 \(fmt(sixty?["p50"])) max \(fmt(sixty?["max"])) ms; "
            + "120 Hz p50 \(fmt(twenty?["p50"])) max \(fmt(twenty?["max"])) ms (clock assumed perfect); "
            + "\(((section["60Hz"] as? [String: Any])?["linesUnreachedBeyondTrackEnd"] as? Int) ?? 0) lines in "
            + "\((((section["60Hz"] as? [String: Any])?["unreachedTrackIDs"] as? [Int]) ?? []).count) tracks are stamped past the track's end and never shown"
        LyricLab.write(section: "L3_frame_grid_activation", section)
    }

    // MARK: - L4 timer scheduling

    /// The boundary timer's arithmetic through the real `MediaController`,
    /// driven by its own monotonic-clock seam: rates 0.5, 1, 1.25 and 2, a
    /// seek, a tick, a wake that lands on its boundary, and a rate change —
    /// each armed delay checked against an independent computation. Then the
    /// part no arithmetic can answer: how late this Mac actually runs the wake
    /// `armBoundaryTimer` schedules, through the same
    /// `MediaController.scheduleLyricWake`, with the Foundation timer it
    /// replaced measured beside it for comparison.
    func testL4TimerScheduling() throws {
        let accepted = try LyricLab.acceptedTracks()
        let lead: TimeInterval = 0.2
        var errorsMs: [Double] = []
        var perScenario: [String: [Double]] = [:]
        var wrongBoundary = 0, missingWake = 0, checks = 0
        var rateChangePendingWakeErrorMs: [Double] = [], rateChangePendingJumpMs: [Double] = []

        final class Clock { var now: TimeInterval = 50_000 }

        /// The next boundary strictly ahead, computed here and not by
        /// `MediaController.nextLyricWake`, so the two can disagree.
        func expected(_ boundaries: [TimeInterval], position: TimeInterval, rate: Double) -> (boundary: TimeInterval, delay: TimeInterval)? {
            for boundary in boundaries where boundary - lead > position + 0.0005 {
                return (boundary, (boundary - lead - position) / rate)
            }
            return nil
        }

        for (track, lines) in accepted.prefix(60) where lines.count >= 6 {
            let boundaries = lines.map(\.at).sorted()
            let duration = max(track.duration, boundaries.last! + 10)
            for rate in [0.5, 1.0, 1.25, 2.0] {
                let clock = Clock()
                let controller = MediaController()
                controller.lyricsShown = { false }
                controller.monotonicNow = { clock.now }
                var snapshot = NowPlayingFeed.Snapshot()
                snapshot.title = "Lab \(track.id)"
                snapshot.artist = "Lab"
                snapshot.album = "Lab"
                snapshot.duration = duration
                snapshot.elapsed = max(0, boundaries[boundaries.count / 3] - 1.3)
                snapshot.rate = rate
                snapshot.isPlaying = true
                snapshot.takenAt = Date()
                snapshot.playerPID = 7
                controller.apply(snapshot)
                controller.setActive(true)

                func check(_ scenario: String, rate checkRate: Double, arm: () -> Void) {
                    let before = Date()
                    arm()
                    let after = Date()
                    checks += 1
                    guard let want = expected(boundaries, position: controller.position, rate: checkRate) else {
                        if controller.lyricWakeDateForTests != nil { wrongBoundary += 1 }
                        return
                    }
                    guard let wake = controller.lyricWakeDateForTests else { missingWake += 1; return }
                    // The fire date is computed inside `arm`, between the two
                    // stamps; anything outside that bracket is the arithmetic.
                    let early = wake.timeIntervalSince(before) - want.delay
                    let late = wake.timeIntervalSince(after) - want.delay
                    let error = early < 0 ? early : (late > 0 ? late : 0)
                    errorsMs.append(error * 1000)
                    perScenario["\(scenario)@\(checkRate)x", default: []].append(error * 1000)
                    if abs(error) > 0.001 { wrongBoundary += 1 }
                }

                check("register", rate: rate) {
                    controller.setLyricBoundaries(boundaries, lead: { lead })
                }
                // The clock runs on, and a grid tick re-arms.
                check("tick", rate: rate) {
                    clock.now += 0.437
                    controller.tick()
                }
                // A wake that lands exactly on its boundary must arm the next.
                // Re-arming for the boundary just served would show as a 1 ms
                // delay against the next one's, and fail the check.
                if let due = expected(boundaries, position: controller.position, rate: rate) {
                    check("on-boundary", rate: rate) {
                        clock.now += due.delay
                        controller.tick()
                    }
                }
                // A rate change reported by the player, mid-line.
                let newRate = rate == 1 ? 1.25 : 1
                var change = snapshot
                change.rate = newRate
                change.elapsed = controller.position
                change.takenAt = Date()
                check("rate-change", rate: newRate) { controller.apply(change) }
                // A seek forward and one back, each re-arming from its target.
                let forward = boundaries[boundaries.count / 2] - 0.7
                check("seek-forward", rate: newRate) { controller.seek(to: forward) }
                clock.now += 0.25
                controller.tick()
                let back = boundaries[boundaries.count / 4] + 0.31
                check("seek-back", rate: newRate) { controller.seek(to: back) }

                // The same kind of rate change while the seek is still
                // unconfirmed: the snapshot's position is then not adopted,
                // nothing re-bases the anchor, and the new rate is applied
                // backwards over all the time since it was set. Measured as
                // the jump the next tick publishes, and as the wake it arms.
                clock.now += 0.8
                controller.tick()
                let standing = controller.position
                var pendingChange = snapshot
                pendingChange.rate = rate
                pendingChange.elapsed = standing
                pendingChange.takenAt = Date()
                let armedBefore = Date()
                controller.apply(pendingChange)
                if let wake = controller.lyricWakeDateForTests,
                   let want = expected(boundaries, position: standing, rate: rate) {
                    rateChangePendingWakeErrorMs.append((wake.timeIntervalSince(armedBefore) - want.delay) * 1000)
                }
                clock.now += 0.1
                controller.tick()
                rateChangePendingJumpMs.append((controller.position - (standing + 0.1 * rate)) * 1000)
                controller.setActive(false)
                controller.stop()
            }
        }

        let fidelity = Self.clockFidelity()

        // The machine's real timer slack, on the production wake.
        let foundation = LabTimers.foundationTimerSamples()
        let idle = LabTimers.samples(load: false)
        let idleNoTicker = LabTimers.samples(load: false, ticker: false)
        let loaded = LabTimers.samples(load: true)
        func describe(_ samples: [Double]) -> [String: Any] {
            let late = samples.map { $0 * 1000 }
            return [
                "timers": samples.count,
                "wakeLatenessMs": LabStats.summary(late),
                "over1ms": late.filter { $0 > 1 }.count,
                "over8_33ms": late.filter { $0 > 1000.0 / 120 }.count,
                "over16_67ms": late.filter { $0 > 1000.0 / 60 }.count,
                "early": late.filter { $0 < 0 }.count,
            ]
        }
        let arithmeticBad = wrongBoundary + missingWake
        if arithmeticBad > 0 { LyricLab.finding("L4: \(arithmeticBad) wrong or missing wakes") }
        let idleP99 = LabStats.percentile(idle.map { $0 * 1000 }, 0.99)
        let loadedP99 = LabStats.percentile(loaded.map { $0 * 1000 }, 0.99)
        let verdict: String
        if arithmeticBad > 0 || max(idleP99, loadedP99) > 1000.0 / 60 {
            verdict = "fail"
        } else if max(idleP99, loadedP99) > 1 {
            verdict = "concern"
        } else {
            verdict = "pass"
        }
        LyricLab.write(section: "L4_timer_scheduling", [
            "arithmetic": [
                "method": "real MediaController, monotonicNow seam frozen and stepped; fire date read from lyricWakeDateForTests; expected delay computed independently",
                "checks": checks,
                "armedDelayErrorMs": LabStats.summary(errorsMs),
                "perScenarioErrorMs": perScenario.mapValues { LabStats.summary($0) },
                "wrongOrRearmedBoundary": wrongBoundary,
                "missingWake": missingWake,
                "rateChangeWhileSeekPending": [
                    "note": "apply() sets playbackRate before deciding whether to adopt the snapshot's position; when it does not adopt (seek pending, precision sync steering, stale or held reading) the anchor is not re-based and the new rate rescales all the time since the anchor was set",
                    "armedWakeErrorMs": LabStats.summary(rateChangePendingWakeErrorMs),
                    "nextTickPositionJumpMs": LabStats.summary(rateChangePendingJumpMs),
                ],
            ],
            "clockFidelityUnderSnapshots": fidelity,
            "foundationTimerBeforeLY07": [
                "construction": "Timer(timeInterval: max(delay, 0.001), repeats: false) { Task { @MainActor in … } }, tolerance 0, RunLoop.main .common — what Isla used before LY-07, kept as the comparison",
                "callbackLatenessMs": LabStats.summary(foundation.map { $0.callbackLate * 1000 }),
                "mainActorHopLatenessMs": LabStats.summary(foundation.map { $0.taskLate * 1000 }),
            ],
            "timerConstruction": "MediaController.scheduleLyricWake, the function armBoundaryTimer calls: DispatchSource.makeTimerSource(flags: .strict, queue: .main), leeway 0, handler through MainActor.assumeIsolated (no Task hop), lateness measured by the scheduler against its own DispatchTime deadline; a 100 ms repeating ticker (tolerance 5 ms) runs beside it as in an open panel",
            "mainThreadQoS": Thread.current.qualityOfService.rawValue,
            "idle": describe(idle),
            "idleWithoutTicker": describe(idleNoTicker),
            "loaded": describe(loaded).merging(["burnerThreads": ProcessInfo.processInfo.activeProcessorCount, "burnerQoS": "userInitiated"]) { a, _ in a },
            "verdict": verdict,
            "summary": "arithmetic: \(checks) arms, \(arithmeticBad) wrong; rate change during a pending seek jumps the clock p50 \(fmt(LabStats.summary(rateChangePendingJumpMs)["p50"])) ms; "
                + "snapshot re-base leaves the anchor behind a perfect player \(fmt((fidelity["shareOfTimeBehindOver1ms"] as? Double).map { $0 * 100 }))% of the time, mean \(fmt((fidelity["anchorErrorMs"] as? [String: Any])?["mean"])) ms, worst \(fmt((fidelity["anchorErrorMs"] as? [String: Any])?["min"])) ms; "
                + "lyric wake late p50/p99/max idle "
                + "\(fmt(LabStats.percentile(idle.map { $0 * 1000 }, 0.5)))/\(fmt(idleP99))/\(fmt(idle.map { $0 * 1000 }.max())) ms, loaded "
                + "\(fmt(LabStats.percentile(loaded.map { $0 * 1000 }, 0.5)))/\(fmt(loadedP99))/\(fmt(loaded.map { $0 * 1000 }.max())) ms; "
                + "the Foundation Timer it replaced, idle p50/p99 \(fmt(LabStats.percentile(foundation.map { $0.taskLate * 1000 }, 0.5)))/\(fmt(LabStats.percentile(foundation.map { $0.taskLate * 1000 }, 0.99))) ms",
        ])
    }

    /// The anchor against a perfect player, through the real snapshot path.
    ///
    /// A player that plays at exactly 1x publishes an exact reading every two
    /// seconds (the helper's poll), at a random phase against the 0.1 s grid
    /// tick. Where the anchor stands after each event is read back from the
    /// wake the controller arms for a boundary far ahead, so the measurement
    /// reads the same number a lyric wake would act on.
    static func clockFidelity() -> [String: Any] {
        final class Clock { var now: TimeInterval = 1_000 }
        let clock = Clock()
        let controller = MediaController()
        controller.lyricsShown = { false }
        controller.monotonicNow = { clock.now }
        let start = 1_000.0, origin = 40.0, far = 90_000.0
        func truth() -> Double { origin + (clock.now - start) }
        var snapshot = NowPlayingFeed.Snapshot()
        snapshot.title = "Lab fidelity"
        snapshot.artist = "Lab"
        snapshot.album = "Lab"
        snapshot.duration = 100_000
        snapshot.rate = 1
        snapshot.isPlaying = true
        snapshot.playerPID = 7
        snapshot.elapsed = truth()
        snapshot.takenAt = Date()
        controller.apply(snapshot)
        controller.setActive(true)
        controller.setLyricBoundaries([far], lead: { 0 })

        var random = LabRandom(seed: 11)
        let tickPhase = random.unit() * 0.1
        let snapshotPhase = random.unit() * 2
        var events: [(at: Double, isSnapshot: Bool)] = []
        var t = tickPhase
        while t < 600 { events.append((t, false)); t += MediaController.positionTickInterval }
        t = snapshotPhase
        // The helper's poll runs on its own clock, so its phase against the
        // grid drifts: each snapshot lands anywhere inside a tick period.
        while t < 600 { events.append((t + random.unit() * MediaController.positionTickInterval, true)); t += 2 }
        events.sort { $0.at < $1.at }

        var errors: [Double] = [], afterSnapshot: [Double] = [], takes = 0, rebases = 0
        for event in events {
            clock.now = start + event.at
            let before = controller.position
            if event.isSnapshot {
                snapshot.elapsed = truth()
                snapshot.takenAt = Date()
                controller.apply(snapshot)
                if controller.position != before { takes += 1 } else { rebases += 1 }
            } else {
                controller.tick()
            }
            guard let wake = controller.lyricWakeDateForTests else { continue }
            let anchorNow = far - wake.timeIntervalSinceNow
            let error = (anchorNow - truth()) * 1000
            errors.append(error)
            if event.isSnapshot { afterSnapshot.append(error) }
        }
        controller.setActive(false)
        controller.stop()
        return [
            "method": "real MediaController; exact 1x player; snapshot every 2 s (helper poll) with zero age; 0.1 s grid tick; anchor read back from the armed wake",
            "simulatedSeconds": 600,
            "snapshots": takes + rebases,
            "snapshotsTaken": takes,
            "snapshotsRebasedOnStalePosition": rebases,
            "anchorErrorMs": LabStats.summary(errors),
            "anchorErrorAfterSnapshotMs": LabStats.summary(afterSnapshot),
            "shareOfTimeBehindOver1ms": Double(errors.filter { $0 < -1 }.count) / Double(max(errors.count, 1)),
            "meanLagWhileBehindMs": LabStats.summary(errors.filter { $0 < -1 })["mean"] ?? 0,
            "sign": "negative = the clock runs behind the player",
        ]
    }

    // MARK: - L7 lead calibration

    /// The owner's "Lyric Delay", set for AirPods (checklist.md 2026-09-21).
    /// Stored as −0.247 s while the lead added the correction; the sign
    /// migration of 2026-10-11 rewrote it as the +0.247 s of delay it always
    /// meant, at the same effective lead.
    static let ownerDelay: TimeInterval = 0.247

    /// Every term between a timestamp and the eye, summed as a distribution,
    /// and the lead that keeps the result inside what people cannot detect.
    ///
    /// Measured here: the frame grid (L3, analytic), the timer wake (L4,
    /// sampled live), the crossfade's rise (computed from `Theme`'s own spring
    /// constants). Measured elsewhere: the clock's lag behind the player
    /// (`Scripts/measure-sync.sh`, 2026-09-21). Assumed: the output device's
    /// latency, how far the catalogue's stamps sit from the voice, and one
    /// frame of compositor latency. The report says which is which.
    func testL7LeadCalibration() throws {
        _ = try LyricLab.requireCorpus()
        let wake = LabTimers.samples(load: false)
        let loadedWake = LabTimers.samples(load: true)

        // The crossfade a line lights with: `LyricRow` animates `isCurrent` on
        // `Theme.lyricScroll`, a spring. Its rise times, from its constants.
        let response = Theme.lyricScrollResponse, damping = Theme.lyricScrollDamping
        func rise(_ level: Double) -> Double {
            Theme.springRiseTime(response: response, damping: damping, level: level)
        }
        let rise10 = rise(0.1), rise50 = rise(0.5), rise90 = rise(0.9)

        // ITU-R BT.1359-1 (1998), detectability: sound before picture by more
        // than 45 ms, or after it by more than 125 ms. Here the picture is the
        // line lighting, so "display late" is sound-first (+45 ms limit) and
        // "display early" is sound-after (−125 ms limit).
        let detectLate = 0.045, detectEarly = -0.125
        let acceptLate = 0.090, acceptEarly = -0.185
        let target = (detectLate + detectEarly) / 2

        struct Scenario { let name: String; let hz: Double; let outputLatency: Double; let wake: [Double] }
        let device = LabAudio.defaultOutputLatency()
        var scenarios = [
            Scenario(name: "60Hz, output 0 (player position already compensated)", hz: 60, outputLatency: 0, wake: wake),
            Scenario(name: "120Hz, output 0", hz: 120, outputLatency: 0, wake: wake),
            Scenario(name: "120Hz, output 0, CPU loaded", hz: 120, outputLatency: 0, wake: loadedWake),
            Scenario(name: "120Hz, wired/built-in output 0.020 s (assumed)", hz: 120, outputLatency: 0.020, wake: wake),
            Scenario(name: "120Hz, Bluetooth output 0.200 s (assumed)", hz: 120, outputLatency: 0.200, wake: wake),
        ]
        if let seconds = device["totalSeconds"] as? Double {
            scenarios.append(Scenario(name: "120Hz, this Mac's default output as CoreAudio reports it", hz: 120, outputLatency: seconds, wake: wake))
        }

        // The newest probe run with today's 0.1 s grid (2026-09-21, commit
        // 03a3059, checklist.md): published position a median 0.188 s behind
        // Spotify's. The probe reads `controller.position`, which between grid
        // ticks is stale by U(0, 0.1) s — a mean of 0.05 s a boundary wake does
        // not suffer, because the wake publishes a fresh extrapolation. The
        // ±0.04 s spread covers the AppleScript read's own age (truth is
        // sampled mid-call, 40–80 ms) and is an assumption.
        let publishedLag = 0.188
        let anchorLag = publishedLag - MediaController.positionTickInterval / 2
        let anchorLagSpread = 0.04

        var random = LabRandom(seed: 7)
        let draws = 20_000
        var results: [[String: Any]] = []
        var defaultInWindow: [Double] = []
        var optimalLeads: [Double] = []
        for scenario in scenarios {
            let period = 1 / scenario.hz
            // d = display - heard, before the lead: positive is late.
            var base: [Double] = []
            base.reserveCapacity(draws)
            for _ in 0..<draws {
                // The anchor's lag behind the player, which is what a boundary
                // wake reads: the probe's published-position median less the
                // grid's mean staleness, with the probe's own uncertainty.
                let lag = anchorLag - anchorLagSpread + random.unit() * 2 * anchorLagSpread
                let timer = scenario.wake.isEmpty ? 0 : scenario.wake[Int(random.unit() * Double(scenario.wake.count)) % scenario.wake.count]
                let vsync = random.unit() * period
                let compositor = period
                base.append(lag + max(0, timer) + vsync + compositor + rise50 - scenario.outputLatency)
            }
            func inWindow(lead: Double, low: Double, high: Double) -> Double {
                Double(base.filter { $0 - lead >= low && $0 - lead <= high }.count) / Double(base.count)
            }
            var best = (lead: 0.0, share: -1.0, centre: Double.infinity)
            var lead = -0.5
            while lead <= 0.6 + 1e-9 {
                let share = inWindow(lead: lead, low: detectEarly, high: detectLate)
                let median = LabStats.percentile(base, 0.5) - lead
                if share > best.share + 1e-9 || (abs(share - best.share) <= 1e-9 && abs(median - target) < best.centre) {
                    best = (lead, share, abs(median - target))
                }
                lead += 0.005
            }
            // The production lead with this scenario's route reported to the
            // model, exactly as `LyricsCoordinator` reports a live one — so
            // the lab measures the lead the app would use on that route, not
            // a restated constant. While the term is not applied the lead is
            // the same on every route, which this asserts.
            let savedModel = LyricSweep.model
            LyricSweep.model.outputLatency = scenario.outputLatency
            let shipped = LyricSweep.lead(precisionSync: false, userOffset: 0)
            let owner = LyricSweep.lead(precisionSync: false, userOffset: Self.ownerDelay)
            let modelTerms = LyricSweep.model.trail
            // What the follow-up that applies the term would ship, for its
            // reviewer: the same sum with this route's latency in place of
            // the reference one.
            let leadIfApplied = LyricSweep.model.lead + LyricSweep.model.appliedOutputLatency
                - scenario.outputLatency
            LyricSweep.model = savedModel
            if !LyricLeadModel.appliesOutputLatency {
                XCTAssertEqual(
                    shipped, savedModel.lead, accuracy: 1e-12,
                    "\(scenario.name): an unapplied output latency must not move the lead"
                )
            }
            defaultInWindow.append(inWindow(lead: shipped, low: detectEarly, high: detectLate))
            optimalLeads.append(best.lead)
            results.append([
                "scenario": scenario.name,
                "outputLatencyS": scenario.outputLatency,
                "productionLeadTerms": modelTerms,
                "leadIfOutputLatencyApplied": leadIfApplied,
                "medianOffsetMsIfOutputLatencyApplied": (LabStats.percentile(base, 0.5) - leadIfApplied) * 1000,
                "undetectableShareIfOutputLatencyApplied": inWindow(lead: leadIfApplied, low: detectEarly, high: detectLate),
                "offsetBeforeLeadMs": LabStats.summary(base, scale: 1000),
                "shippedLead": shipped,
                "shippedMedianOffsetMs": (LabStats.percentile(base, 0.5) - shipped) * 1000,
                "shippedUndetectableShare": inWindow(lead: shipped, low: detectEarly, high: detectLate),
                "shippedAcceptableShare": inWindow(lead: shipped, low: acceptEarly, high: acceptLate),
                "ownerEffectiveLead": owner,
                "ownerMedianOffsetMs": (LabStats.percentile(base, 0.5) - owner) * 1000,
                "ownerUndetectableShare": inWindow(lead: owner, low: detectEarly, high: detectLate),
                "optimalLead": best.lead,
                "optimalUndetectableShare": best.share,
                "optimalMedianOffsetMs": (LabStats.percentile(base, 0.5) - best.lead) * 1000,
            ])
        }

        // What the owner's correction says. Tuned as −0.247 s when the lead
        // added it, it reads +0.247 s since the 2026-10-11 sign migration,
        // and either way the effective lead is −0.047 s; if that is where the
        // owner hears the line on the voice
        // (median offset at the window's centre), the unmodelled delay between
        // the player's position and the voice reaching the ear is:
        let modelled = results.first { ($0["scenario"] as? String)?.hasPrefix("120Hz, output 0") == true }
        let baseMedianMs = (modelled?["offsetBeforeLeadMs"] as? [String: Any])?["p50"] as? Double ?? .nan
        let ownerLead = LyricSweep.lead(precisionSync: false, userOffset: Self.ownerDelay)
        XCTAssertEqual(
            ownerLead, -0.047, accuracy: 1e-9,
            "the sign migration must leave the owner's calibration at the lead it was tuned to"
        )
        let impliedHidden = baseMedianMs / 1000 - ownerLead - target
        let impliedHiddenAtZero = baseMedianMs / 1000 - ownerLead

        LyricLab.write(section: "L7_lead_calibration", [
            "measured": [
                "frameGrid": "uniform over one period (L3), plus one period of compositor latency (assumed)",
                "timerWakeMs_idle": LabStats.summary(wake, scale: 1000),
                "timerWakeMs_loaded": LabStats.summary(loadedWake, scale: 1000),
                "crossfadeSpring": ["response": response, "damping": damping,
                                    "rise10Ms": rise10 * 1000, "rise50Ms": rise50 * 1000, "rise90Ms": rise90 * 1000],
                "defaultOutputDevice": device,
            ],
            "measuredElsewhere": [
                "publishedPositionLagBehindPlayerS": publishedLag,
                "publishedLagSource": "Scripts/measure-sync.sh, live Spotify, 2026-09-21 (commit 03a3059, checklist.md); 0.1 s grid",
                "anchorLagUsedS": anchorLag,
                "anchorLagModel": "uniform ±\(anchorLagSpread) s around published lag − grid/2; the spread is assumed",
                "olderRun": "2026-09-13 measured −0.103 s with the 0.25 s grid, i.e. an anchor lag near −0.02 s; the two runs disagree by ~0.16 s and the lab cannot say which holds today",
            ],
            "assumed": [
                "catalogueStampBias": "0 s — LRCLIB stamps are taken as the vocal onset; not measurable without audio",
                "outputLatency": "scenarios; whether Spotify's player position already compensates for it is unknown",
                "perceivedOnset": "the crossfade's 50% point",
            ],
            "criterion": [
                "standard": "ITU-R BT.1359-1 (1998)",
                "detectabilityMs": [detectEarly * 1000, detectLate * 1000],
                "acceptabilityMs": [acceptEarly * 1000, acceptLate * 1000],
                "sign": "offset = display − voice heard; positive = line lights after the voice (sound leads picture)",
                "targetMs": target * 1000,
            ],
            "scenarios": results,
            "ownerCorrection": [
                "userOffset": Self.ownerDelay,
                "userOffsetBeforeSignMigration": -Self.ownerDelay,
                "effectiveLead": ownerLead,
                "impliedHiddenDelaySIfOwnerAimsAtWindowCentre": impliedHidden,
                "impliedHiddenDelaySIfOwnerAimsAtZero": impliedHiddenAtZero,
            ],
            "perceivedOnsetSensitivity": [
                "note": "if the eye takes the line as lit at the crossfade's 10% point instead of its 50% point, every optimum lead and every implied hidden delay moves by this much",
                "shiftS": -(rise50 - rise10),
            ],
            "verdict": "concern",
            "summary": "shipped lead 0.20 s keeps \(fmt(defaultInWindow.first.map { $0 * 100 }))% of line onsets undetectable at 60 Hz with zero output latency; "
                + "optimal lead per scenario \(optimalLeads.map { String(format: "%.3f", $0) }.joined(separator: "/")) s; "
                + "owner's +0.247 s delay implies ≈\(String(format: "%.0f", impliedHidden * 1000)) ms of delay the model does not contain",
        ])
    }

}

func fmt(_ value: Any?) -> String {
    guard let double = value as? Double, double.isFinite else { return "-" }
    return String(format: "%.3f", double)
}

// The spring a line lights with used to be modelled here as `SpringRise`; it
// is `Theme.springRiseTime` now, so the lab and the lead model compute one
// number from one place.

// MARK: - Real timers

/// Real lyric wakes, scheduled through `MediaController.scheduleLyricWake` —
/// the very function `armBoundaryTimer` calls, not a restatement of it —
/// run on the main queue, measured once per process and shared by L4 and L7.
/// Until LY-07 this restated the Foundation `Timer` the controller then used;
/// that construction survives below only as the comparison.
@MainActor
enum LabTimers {
    /// The rejected construction's two moments.
    struct FoundationSample {
        /// Seconds past the fire date when the timer's block ran.
        let callbackLate: Double
        /// Seconds past the fire date when the `Task { @MainActor }` the
        /// block starts — the hop to `tick()` — ran.
        let taskLate: Double
    }

    /// Seconds past the deadline when each wake's handler ran — the moment
    /// production calls `tick()`, as the scheduler itself measures it.
    private static var cache: [String: [Double]] = [:]
    static var count: Int {
        Int(ProcessInfo.processInfo.environment["ISLA_LYRIC_TIMERS"] ?? "") ?? 300
    }

    @MainActor final class Box {
        var callback: Date?
        var task: Date?
        var late: Double?
    }

    /// The open panel's grid tick, beside the wake, as in production.
    private static func gridTicker() -> Timer {
        let ticker = Timer(timeInterval: 0.1, repeats: true) { _ in Task { @MainActor in _ = 0 } }
        ticker.tolerance = 0.005
        return ticker
    }

    /// The same delays on the production wake.
    static func samples(load: Bool, ticker withTicker: Bool = true) -> [Double] {
        let key = "\(load)-\(withTicker)"
        if let cached = cache[key] { return cached }
        var random = LabRandom(seed: load ? 2 : 1)
        let ticker = gridTicker()
        if withTicker { RunLoop.main.add(ticker, forMode: .common) }
        let burner = load ? CPUBurner(threads: ProcessInfo.processInfo.activeProcessorCount) : nil
        if burner != nil { Thread.sleep(forTimeInterval: 0.3) }
        var samples: [Double] = []
        for _ in 0..<count {
            let delay = 0.005 + random.unit() * 0.245
            let box = Box()
            let source = MediaController.scheduleLyricWake(after: delay) { late in box.late = late }
            let giveUp = Date().addingTimeInterval(delay + 2)
            while box.late == nil, Date() < giveUp {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.25))
            }
            source.cancel()
            if let late = box.late { samples.append(late) }
        }
        burner?.stop()
        ticker.invalidate()
        cache[key] = samples
        return samples
    }

    /// The same delays on the construction Isla used before LY-07: a
    /// Foundation `Timer`, tolerance 0, on the main run loop in `.common`,
    /// whose block hops to the main actor through a `Task`. Idle only — it is
    /// the comparison, not the product.
    static func foundationTimerSamples() -> [FoundationSample] {
        var random = LabRandom(seed: 1)
        let ticker = gridTicker()
        RunLoop.main.add(ticker, forMode: .common)
        defer { ticker.invalidate() }
        var samples: [FoundationSample] = []
        for _ in 0..<count {
            let delay = 0.005 + random.unit() * 0.245
            let box = Box()
            let timer = Timer(timeInterval: max(delay, 0.001), repeats: false) { _ in
                let fired = Date()
                Task { @MainActor in
                    box.callback = fired
                    box.task = Date()
                }
            }
            timer.tolerance = 0
            let deadline = timer.fireDate
            RunLoop.main.add(timer, forMode: .common)
            let giveUp = Date().addingTimeInterval(delay + 2)
            while box.task == nil, Date() < giveUp {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.25))
            }
            guard let callback = box.callback, let task = box.task else { continue }
            samples.append(FoundationSample(
                callbackLate: callback.timeIntervalSince(deadline),
                taskLate: task.timeIntervalSince(deadline)
            ))
        }
        return samples
    }
}

/// Busy threads on every core, for the loaded run.
final class CPUBurner: Sendable {
    private let stopped = Atomic<Bool>(false)
    private let sink = Atomic<UInt64>(0)

    init(threads: Int) {
        for _ in 0..<threads {
            Thread.detachNewThread { [self] in
                Thread.current.qualityOfService = .userInitiated
                var x: UInt64 = 1
                while !self.stopped.load(ordering: .relaxed) {
                    for _ in 0..<10_000 { x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407 }
                }
                self.sink.store(x, ordering: .relaxed)
            }
        }
    }

    func stop() { stopped.store(true, ordering: .relaxed) }
}

// MARK: - The output device

/// What CoreAudio reports for the default output device's latency: device
/// latency, safety offset, IO buffer and stream latency, in frames, over the
/// nominal sample rate. Read-only, and reported — not measured acoustically.
/// The device's name is deliberately not recorded.
///
/// The reading is the app's own (`AudioOutputs.outputLatency(of:)`), the one
/// `OutputLatencyMonitor` feeds the lead model, so the lab reports the number
/// the app sees rather than a second implementation of it.
enum LabAudio {
    static func defaultOutputLatency() -> [String: Any] {
        guard let device = AudioOutputs.current(),
              let reading = AudioOutputs.outputLatency(of: device) else { return ["available": false] }
        let transport = AudioOutputs.transport(of: device)
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((transport >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
        return [
            "available": true,
            "transport": fourCC,
            "sampleRate": reading.sampleRate,
            "deviceLatencyFrames": Int(reading.deviceFrames),
            "safetyOffsetFrames": Int(reading.safetyOffsetFrames),
            "bufferFrames": Int(reading.bufferFrames),
            "streamLatencyFrames": Int(reading.streamFrames),
            "totalSeconds": reading.seconds ?? Double.nan,
        ]
    }
}
