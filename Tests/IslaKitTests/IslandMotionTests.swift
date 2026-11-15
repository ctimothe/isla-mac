import SwiftUI
import XCTest
@testable import IslaKit

/// The island's per-change springs, carried over from islandcn's
/// measurements of the iPhone (spec §19.3, amended 2026-11-14).
final class IslandMotionTests: XCTestCase {
    /// The table as islandcn fitted it (`islandMotion.shape`, commit 0011a41).
    /// A changed number here is a different island, not a refactor.
    func testTheSpringsAreIslandcnsFittedValues() {
        let expected: [IslandMotion.Transition: (Double, Double)] = [
            .appear: (0.483, 0.62), .expand: (0.517, 0.824), .appearExpand: (0.54, 0.811),
            .swap: (0.498, 0.829), .collapse: (0.479, 0.894), .alertCollapse: (0.535, 0.84),
            .split: (0.505, 0.815), .unsplit: (0.487, 0.794), .dismiss: (0.432, 1.019),
            .resize: (0.5, 0.82),
        ]
        XCTAssertEqual(Set(expected.keys), Set(IslandMotion.Transition.allCases))
        for (transition, (response, damping)) in expected {
            XCTAssertEqual(IslandMotion.spring(for: transition), .init(response: response, damping: damping), "\(transition)")
        }
    }

    /// Only the arrival of a compact activity overshoots visibly, and going
    /// home never does: that is the difference the owner chose (2026-11-14).
    func testOnlyArrivalsBounceAndGoingHomeDoesNot() {
        XCTAssertLessThan(IslandMotion.spring(for: .appear).damping, 0.7)
        XCTAssertGreaterThanOrEqual(IslandMotion.spring(for: .dismiss).damping, 1)
        XCTAssertGreaterThan(IslandMotion.spring(for: .alertCollapse).damping, IslandMotion.spring(for: .appearExpand).damping)
    }

    func testPresentationsFollowTheSpec() {
        XCTAssertEqual(IslandMotion.presentation(of: .none), .idle)
        XCTAssertEqual(IslandMotion.presentation(of: .music), .compact("music"))
        XCTAssertEqual(IslandMotion.presentation(of: .peek), .expanded("peek"), "a new track is shown as the pop-up is")
        XCTAssertEqual(IslandMotion.presentation(of: .shelf(count: 3)), .compact("shelf"))
        XCTAssertEqual(IslandMotion.presentation(of: .music, hasBubble: true), .split("music"))
        XCTAssertEqual(
            IslandMotion.presentation(of: .ambient(.charging(level: 50, isCharging: true))), .compact("charging")
        )
        XCTAssertEqual(
            IslandMotion.presentation(of: .ambient(.headphones(name: "AirPods", symbol: "airpods"))),
            .expanded("headphones")
        )
    }

    /// islandcn's `shapeTransition`, case by case.
    func testTheTransitionIsPickedFromBothEnds() {
        typealias P = IslandMotion.Presentation
        let cases: [(P, P, IslandMotion.Transition)] = [
            (.idle, .compact("music"), .appear),
            (.idle, .expanded("hud"), .appearExpand),
            (.compact("music"), .expanded("music"), .expand),
            (.compact("music"), .expanded("headphones"), .swap),
            (.split("music"), .expanded("music"), .swap),
            (.expanded("headphones"), .expanded("update"), .swap),
            (.expanded("headphones"), .compact("music"), .alertCollapse),
            (.expanded("headphones"), .split("music"), .split),
            (.expanded("headphones"), .idle, .dismiss),
            (.compact("music"), .idle, .dismiss),
            (.compact("music"), .split("music"), .split),
            (.split("music"), .compact("music"), .unsplit),
            (.compact("music"), .compact("shelf"), .resize),
            (.compact("music"), .compact("music"), .resize),
        ]
        for (from, to, expected) in cases {
            XCTAssertEqual(IslandMotion.transition(from: from, to: to), expected, "\(from) → \(to)")
        }
        XCTAssertEqual(
            IslandMotion.transition(from: .expanded("hud"), to: .compact("music"), wasAlert: false), .collapse
        )
    }

    /// The outline is drawn by Core Animation from the curve read out of the
    /// transaction (`OutlineCurve`). Each spring must read back as itself, or
    /// the outline and the content would ride different curves.
    func testTheOutlineReadsEverySpringBack() {
        for transition in IslandMotion.Transition.allCases {
            let spring = IslandMotion.spring(for: transition)
            let curve = OutlineCurve.of(IslandMotion.animation(for: transition, reduceMotion: false))
            guard case .spring(let response, let damping, let delay) = curve else {
                return XCTFail("\(transition) read as \(curve)")
            }
            XCTAssertEqual(response, spring.response, accuracy: 1e-9, "\(transition)")
            XCTAssertEqual(damping, spring.damping, accuracy: 1e-9, "\(transition)")
            XCTAssertEqual(delay, 0)
        }
    }

    func testReduceMotionKeepsItsEaseForEveryChange() {
        for transition in IslandMotion.Transition.allCases {
            XCTAssertEqual(
                String(describing: IslandMotion.animation(for: transition, reduceMotion: true)),
                String(describing: Theme.reducedMotion)
            )
        }
    }

    /// The shut island's changes ride the morph, not the one outline spring:
    /// the keyed `.animation`s that used to name `Theme.pill` for the song,
    /// the peek, the charger, the confirmation and the update now go through
    /// `IslandMorph`.
    func testTheShellAnimatesActivityChangesThroughTheMorph() throws {
        let shell = try SourceText.of("Sources/IslaKit/UI/NotchContentView.swift")
        XCTAssertTrue(shell.contains(".modifier(IslandMorph("), "the shell has no morph")
        // The locked pill keeps its own keyed charger curve beneath the
        // lock's refusal, so `vm.ambient` is not in this list.
        for key in ["value: vm.isPeeking)", "value: vm.confirmation)", "value: vm.updateOffer?.version)"] {
            XCTAssertFalse(shell.contains(".animation(Theme.pill(reduceMotion: reduceMotion), \(key)"), key)
        }
    }
}
