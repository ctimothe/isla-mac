import SwiftUI
import XCTest
@testable import IslaKit

/// The two Charging activities (spec §19.4, amended 2026-10-26) in the lab:
/// MagSafe's ring and USB-C's battery, and the states both share.
extension VisualLabPillTests {
    func testChargingVariants() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "pill")
        let size = Self.pillSize
        let cases: [(String, AmbientActivity, [LabVariant], String?)] = [
            ("charger-magsafe", .charging(level: 64, isCharging: true, port: .magSafe, watts: 140),
             [.base, .light, .contrast, .russian], "MagSafe: the ring drawn to the level, the bolt inside it."),
            ("charger-usbc-watts", .charging(level: 64, isCharging: true, port: .usbC, watts: 61),
             [.base, .light, .contrast, .russian], "USB-C: the adapter's watts, the battery with the bolt."),
            ("charger-usbc-no-watts", .charging(level: 64, isCharging: true, port: .usbC), [.base], nil),
            ("charger-magsafe-low", .charging(level: 12, isCharging: true, port: .magSafe), [.base, .contrast],
             "20 percent or less is red, stroke and all."),
            ("charger-usbc-low", .charging(level: 12, isCharging: true, port: .usbC, watts: 61), [.base], nil),
            ("charger-magsafe-held", .charging(level: 80, isCharging: false, port: .magSafe), [.base, .russian],
             "Held at the Optimized Charging limit: Not Charging, in white."),
            ("charger-usbc-held", .charging(level: 80, isCharging: false, port: .usbC, watts: 61), [.base, .russian], nil),
            ("charger-usbc-charged", .charging(level: 100, isCharging: false, port: .usbC, watts: 61), [.base], nil),
        ]
        for (name, activity, variants, notes) in cases {
            try await shoot.shoot(name, variants: variants, size: size, notes: notes) { variant in
                Self.scene(try await self.pill(session, configure: { $0.ambient = activity }), variant, height: size.height)
            }
        }
    }
}
