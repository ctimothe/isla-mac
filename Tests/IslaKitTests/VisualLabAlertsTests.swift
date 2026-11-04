import SwiftUI
import XCTest
@testable import IslaKit

/// Every alert under the open panel (spec §19.5 d, amended 2026-10-26) and
/// the two that show over the lock screen (spec §3.7, amended 2026-10-26).
extension VisualLabPillTests {
    func testAlertCapsuleVariants() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "capsule")
        let size = Self.panelSize
        let cases: [(String, (NotchViewModel) -> Void, [LabVariant], String?)] = [
            ("charger-usbc-held", {
                $0.stripNotice = .ambient(.charging(level: 80, isCharging: false, port: .usbC, watts: 61, hold: .onHold))
            }, [.base, .light, .russian], "Plugged in with the panel open: the charger in the level's capsule."),
            ("charger-magsafe-charging", {
                $0.stripNotice = .ambient(.charging(level: 64, isCharging: true, port: .magSafe, watts: 140))
            }, [.base, .contrast], "MagSafe's ring and the island's green line."),
            ("charger-low", {
                $0.stripNotice = .ambient(.charging(level: 12, isCharging: true, port: .usbC, watts: 61))
            }, [.base], nil),
            ("headphones", {
                $0.stripNotice = .ambient(.headphones(name: "AirPods Max", symbol: "airpodsmax"))
            }, [.base, .russian], nil),
            ("confirmation-copied", { $0.stripNotice = .confirmation(IslandConfirmation(.copied)) },
             [.base, .russian], nil),
            ("confirmation-added-to-shelf", { $0.stripNotice = .confirmation(IslandConfirmation(.addedToShelf)) },
             [.base], nil),
            ("confirmation-lyrics-imported", { $0.stripNotice = .confirmation(IslandConfirmation(.lyricsImported)) },
             [.base], nil),
            ("level-for-comparison", {
                $0.hudStrip = HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: false, deviceSymbol: nil))
            }, [.base], "The level's own capsule, which the others match."),
        ]
        for (name, configure, variants, notes) in cases {
            try await shoot.shoot(name, variants: variants, size: size, notes: notes) { variant in
                Self.scene(
                    try await self.openPanel(session, surface: .player, track: .init(), configure: configure),
                    variant, height: size.height
                )
            }
        }
    }

    func testLockedAlertVariants() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "pill")
        let size = Self.pillSize
        let volume = HUDMoment(HUDReading(kind: .volume, level: 0.62, muted: false, deviceSymbol: nil))
        let display = HUDMoment(HUDReading(kind: .display, level: 0.4, muted: false, deviceSymbol: nil))
        let muted = HUDMoment(HUDReading(kind: .volume, level: 0.5, muted: true, deviceSymbol: nil))
        let cases: [(String, (NotchViewModel) -> Void, [LabVariant], String?)] = [
            ("locked-volume", { $0.hud = volume }, [.base, .light],
             "A volume key over the lock screen: the pill's height, never the 103 pt alert over the clock."),
            ("locked-brightness", { $0.hud = display }, [.base], nil),
            ("locked-muted", { $0.hud = muted }, [.base], nil),
            ("locked-charger-held", {
                $0.ambient = .charging(level: 80, isCharging: false, port: .usbC, watts: 61, hold: .onHold)
            }, [.base, .russian], "Plugged in while locked."),
            ("locked-charger-magsafe", {
                $0.ambient = .charging(level: 64, isCharging: true, port: .magSafe, watts: 140)
            }, [.base], nil),
        ]
        for (name, configure, variants, notes) in cases {
            try await shoot.shoot(name, variants: variants, size: size, notes: notes) { variant in
                Self.scene(try await self.pill(session, track: .init(), configure: {
                    $0.isLockedPresentation = true
                    configure($0)
                }), variant, height: size.height)
            }
        }
    }
}
