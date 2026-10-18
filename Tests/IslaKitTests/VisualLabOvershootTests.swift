import AppKit
import SwiftUI
import XCTest
@testable import IslaKit

/// Lab only (ISLA_VISUAL_OUT): the panel drawn while fingers hold the pages
/// past the last one, and between two pages, so a frame of the swipe can be
/// looked at without the live app (owner's recording, 2026-10-18).
@MainActor
final class VisualLabOvershootTests: XCTestCase {
    func testPagesHeldPastTheEnd() async throws {
        guard let out = ProcessInfo.processInfo.environment["ISLA_VISUAL_OUT"], !out.isEmpty else {
            throw XCTSkip("lab only")
        }
        let folder = URL(fileURLWithPath: out).appendingPathComponent("overshoot", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let clock = ManualPageClock()
        vm.pageTravel.clock = clock
        vm.isOpen = true
        vm.open(.translate)
        let size = vm.geometry.windowSize
        func shoot(_ name: String) async throws {
            let view = NotchContentView(vm: vm).frame(width: size.width, height: size.height, alignment: .top)
            guard let shot = await LabRenderer.host(view, size: size, variant: .base, settle: 0.3) else {
                throw NSError(domain: "VisualLab", code: 4)
            }
            try shot.rep.representation(using: .png, properties: [:])!
                .write(to: folder.appendingPathComponent("\(name).png"))
        }
        try await shoot("0-rest")
        var time: TimeInterval = 0
        func scroll(_ dx: CGFloat, _ phase: ScrollSample.Phase) {
            time += 0.016
            _ = vm.pageScroll(PageScroll(deltaX: dx, deltaY: 0, phase: phase, time: time), over: true)
        }
        scroll(-6, .began)
        for step in 1...12 {
            scroll(-12, .changed)
            if step % 4 == 0 { try await shoot("1-past-end-\(step)") }
        }
        scroll(0, .ended)
        vm.open(.clipboard)
        try await shoot("2-clipboard")
        scroll(-6, .began)
        for step in 1...20 {
            scroll(-14, .changed)
            if step % 5 == 0 { try await shoot("3-toward-translate-\(step)") }
        }
    }

    /// The volume and brightness pop-up as the island draws it, at three
    /// levels and muted, so its fill can be looked at beside the system's.
    func testThePopUp() async throws {
        guard let out = ProcessInfo.processInfo.environment["ISLA_VISUAL_OUT"], !out.isEmpty else {
            throw XCTSkip("lab only")
        }
        let folder = URL(fileURLWithPath: out).appendingPathComponent("hud", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let isolated = ProbeFixtures.isolatedStores()
        defer { isolated.release() }
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: isolated.stores)
        let size = vm.geometry.windowSize
        for (name, reading) in [
            ("volume-68", HUDReading(kind: .volume, level: 0.68, muted: false, deviceSymbol: nil)),
            ("volume-muted", HUDReading(kind: .volume, level: 0.4, muted: true, deviceSymbol: nil)),
            ("display-30", HUDReading(kind: .display, level: 0.3, muted: false, deviceSymbol: nil)),
        ] {
            vm.hud = HUDMoment(reading)
            let view = NotchContentView(vm: vm).frame(width: size.width, height: size.height, alignment: .top)
            guard let shot = await LabRenderer.host(view, size: size, variant: .base, settle: 0.6) else {
                throw NSError(domain: "VisualLab", code: 4)
            }
            try shot.rep.representation(using: .png, properties: [:])!
                .write(to: folder.appendingPathComponent("\(name).png"))
        }
    }
}
