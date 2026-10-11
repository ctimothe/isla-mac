import AppKit
import CoreAudio
import SwiftUI
import XCTest
@testable import IslaKit

/// V1, the island shut: the compact pill in every state it can be put in, and
/// the pill over the lock screen.
@MainActor
final class VisualLabPillTests: VisualLabCase {

    /// A shut island. The view model is built while the track plays, so a
    /// pause afterwards is a pause it saw happen — the only kind that shows
    /// the paused pill rather than folding straight into the notch.
    func pill(
        _ session: LabSession, physical: Bool = true, track: LabFixtures.Track? = nil,
        pauseAfter: Bool = false, configure: (NotchViewModel) -> Void = { _ in }
    ) async throws -> NotchViewModel {
        let stores = session.makeStores()
        if let track { await LabFixtures.play(track, on: stores.media) }
        let vm = NotchViewModel(geometry: try LabGeometry.make(physical: physical), stores: stores)
        if pauseAfter, let track { LabFixtures.pause(track, on: stores.media) }
        configure(vm)
        return vm
    }

    func testCompactPill() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "pill")
        let size = Self.pillSize
        let variants = LabVariant.pill

        try await shoot.shoot("idle-resting-in-notch", variants: variants, size: size,
                              notes: "Nothing playing on a notched Mac: the island sits one point inside the cutout and is meant to be invisible.") { variant in
            Self.scene(try await self.pill(session), variant, height: size.height)
        }
        try await shoot.shoot("idle-pointer-awake", variants: variants, size: size,
                              notes: "The pointer on a resting island: it grows out of the cutout (end state of the hover nudge).") { variant in
            Self.scene(try await self.pill(session, configure: { $0.isHovering = true }), variant, height: size.height)
        }
        try await shoot.shoot("playing-equalizer", variants: variants, size: size) { variant in
            Self.scene(try await self.pill(session, track: .init()), variant, height: size.height)
        }
        try await shoot.shoot("playing-pointer-lift", variants: [.base, .light, .contrast], size: size,
                              notes: "Hover over a playing pill: the wings lighten and the cutout does not.") { variant in
            Self.scene(try await self.pill(session, track: .init(), configure: { $0.isHovering = true }), variant, height: size.height)
        }
        try await shoot.shoot("paused-cover-play-badge", variants: variants, size: size,
                              notes: "Paused, inside the linger before the pill folds (the lab stretches the linger so it can be drawn).") { variant in
            Self.scene(try await self.pill(session, track: .init(), pauseAfter: true), variant, height: size.height)
        }
        try await shoot.shoot("new-track-peek", variants: variants, size: size) { variant in
            Self.scene(try await self.pill(session, track: .init(), configure: { $0.isPeeking = true }), variant, height: size.height)
        }
        try await shoot.shoot("new-track-peek-long-title", variants: [.base, .w480, .russian], size: size) { variant in
            Self.scene(try await self.pill(session, track: LabFixtures.longTitle, configure: { $0.isPeeking = true }),
                       variant, height: size.height)
        }
        try await shoot.shoot("new-track-peek-cjk", variants: [.base], size: size) { variant in
            Self.scene(try await self.pill(session, track: LabFixtures.cjkTitle, configure: { $0.isPeeking = true }),
                       variant, height: size.height)
        }
        try await shoot.shoot("charger-charging", variants: variants, size: size) { variant in
            Self.scene(try await self.pill(session, configure: { $0.ambient = .charging(level: 82, isCharging: true) }),
                       variant, height: size.height)
        }
        try await shoot.shoot("charger-holding", variants: [.base, .russian], size: size,
                              notes: "Plugged in but not charging: the plug, not the bolt.") { variant in
            Self.scene(try await self.pill(session, configure: { $0.ambient = .charging(level: 80, isCharging: false) }),
                       variant, height: size.height)
        }
        try await shoot.shoot("charger-no-level", variants: [.base], size: size) { variant in
            Self.scene(try await self.pill(session, configure: { $0.ambient = .charging(level: nil, isCharging: true) }),
                       variant, height: size.height)
        }
        try await shoot.shoot("headphones", variants: variants, size: size) { variant in
            Self.scene(try await self.pill(session, configure: { $0.ambient = .headphones(name: "AirPods Pro", symbol: "airpodspro") }),
                       variant, height: size.height)
        }
        try await shoot.shoot("headphones-long-name", variants: [.base, .w480], size: size) { variant in
            Self.scene(try await self.pill(session, configure: {
                $0.ambient = .headphones(name: "Beats Studio Pro Wireless Special Edition", symbol: "headphones")
            }), variant, height: size.height)
        }
        try await shoot.shoot("charger-over-music", variants: [.base], size: size,
                              notes: "A moment while a song plays: the music stays mounted, faded, under the moment.") { variant in
            Self.scene(try await self.pill(session, track: .init(), configure: { $0.ambient = .charging(level: 82, isCharging: true) }),
                       variant, height: size.height)
        }
        try await shoot.shoot("synthetic-notch-idle", variants: [.base, .light, .contrast], size: size,
                              notes: "A display with no cutout: the island draws a notch of its own.") { variant in
            Self.scene(try await self.pill(session, physical: false), variant, height: size.height)
        }
        try await shoot.shoot("synthetic-notch-playing", variants: [.base, .light, .russian], size: size) { variant in
            Self.scene(try await self.pill(session, physical: false, track: .init()), variant, height: size.height)
        }
        try await shoot.shoot("synthetic-notch-pointer-lift", variants: [.base, .light], size: size,
                              notes: "With no hole in the display the middle lifts with the wings.") { variant in
            Self.scene(try await self.pill(session, physical: false, track: .init(), configure: { $0.isHovering = true }),
                       variant, height: size.height)
        }
        try await shoot.shoot("locked-playing", variants: [.base, .light, .contrast], size: size,
                              notes: "Over the lock screen: visible, never opening.") { variant in
            Self.scene(try await self.pill(session, track: .init(), configure: { $0.isLockedPresentation = true }),
                       variant, height: size.height)
        }
        try await shoot.shoot("locked-pointer-edge", variants: [.base], size: size,
                              notes: "Locked, pointer on the pill: the edge says it is there; a click would shake it (see keyframes-refusal-shake).") { variant in
            Self.scene(try await self.pill(session, track: .init(), configure: {
                $0.isLockedPresentation = true
                $0.isHovering = true
            }), variant, height: size.height)
        }
        try await shoot.shoot("locked-nothing-playing", variants: [.base], size: size) { variant in
            Self.scene(try await self.pill(session, configure: { $0.isLockedPresentation = true }), variant, height: size.height)
        }
    }
}

/// V1, the lock card: every glass, both sizes, all three panes, with and
/// without words, and the heart.
@MainActor
final class VisualLabLockCardTests: VisualLabCase {

    static let outputs: [AudioOutputs.Output] = [
        .init(id: 41, name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn),
        .init(id: 42, name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth),
        .init(id: 43, name: "Studio Display Speakers", transport: kAudioDeviceTransportTypeDisplayPort),
        .init(id: 44, name: "Living Room", transport: kAudioDeviceTransportTypeAirPlay),
    ]

    /// An audio watch that reads fixtures instead of the machine's devices
    /// and never installs a Core Audio listener.
    static func audio() -> AudioWatch {
        AudioWatch(read: { (outputs, 42, 0.62) }, installListeners: {}, removeListeners: {})
    }

    func card(
        _ session: LabSession, variant: LabVariant,
        pane: LockScreenCard.Pane = .player, size: NotchViewModel.LockCardSize = .standard,
        track: LabFixtures.Track = .init(elapsed: 27), lyrics: LyricsAvailability = LabFixtures.timeline(),
        pauseAfter: Bool = false, spotifyTrack: Bool = false
    ) async -> AnyView {
        let stores = session.makeStores()
        await LabFixtures.play(track, on: stores.media)
        if pauseAfter { LabFixtures.pause(track, on: stores.media) }
        stores.lyrics.present(lyrics)
        if spotifyTrack {
            stores.media.setSpotifyTrackIDForTests("labtrack00000000000001")
            SpotifyAccount.shared.refreshSavedState(trackID: "labtrack00000000000001")
            for _ in 0..<100 where SpotifyAccount.shared.saved["labtrack00000000000001"] == nil
                && !LabNetworkGuard.slowSpotify {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let cardSize = LockScreenCard.size(for: size)
        return AnyView(
            ZStack {
                LabLockWallpaper(light: variant.lightDesktop)
                LockScreenCard(media: stores.media, lyrics: stores.lyrics, audio: Self.audio(), initialPane: pane)
                    .frame(width: cardSize.width, height: cardSize.height)
            }
        )
    }

    static func canvas(_ size: NotchViewModel.LockCardSize) -> CGSize {
        let card = LockScreenCard.size(for: size)
        return CGSize(width: card.width + 80, height: card.height + 80)
    }

    func testEveryStyleSizeAndPane() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "lock-card")
        let note = "Hosting renders draw the cover light unblurred (cacheDisplay cannot draw SwiftUI blur); the -ir renders are the faithful look, the hosting ones carry the accessibility tree."
        for style in NotchViewModel.LockCardStyle.allCases {
            for size in NotchViewModel.LockCardSize.allCases {
                for pane in LockScreenCard.Pane.allCases {
                    try await shoot.shoot(
                        "\(style.rawValue)-\(size.rawValue)-\(pane.rawValue)",
                        variants: LabVariant.card, size: Self.canvas(size), settle: 0.25,
                        defaults: [NotchViewModel.lockCardStyleKey: style.rawValue, NotchViewModel.lockCardSizeKey: size.rawValue],
                        notes: note
                    ) { variant in
                        await self.card(session, variant: variant, pane: pane, size: size)
                    }
                }
            }
        }
    }

    func testWordsHeartAndEdges() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "lock-card-states")
        let variants: [LabVariant] = [.base, .russian, LabVariant(name: "dark-ir", backend: .imageRenderer)]
        let canvas = Self.canvas(.standard)

        for size in NotchViewModel.LockCardSize.allCases {
            try await shoot.shoot("no-lyrics-found-\(size.rawValue)", variants: variants, size: Self.canvas(size), settle: 0.25,
                                  defaults: [NotchViewModel.lockCardSizeKey: size.rawValue]) { variant in
                await self.card(session, variant: variant, pane: .lyrics, size: size, lyrics: .noLocalLyrics)
            }
            try await shoot.shoot("lyrics-off-\(size.rawValue)", variants: variants, size: Self.canvas(size), settle: 0.25,
                                  defaults: [NotchViewModel.lockCardSizeKey: size.rawValue, NotchViewModel.showLyricsKey: false],
                                  notes: "Lyrics switched off: the lyrics pane says so.") { variant in
                await self.card(session, variant: variant, pane: .lyrics, size: size, lyrics: .disabled)
            }
            try await shoot.shoot("lyrics-finding-\(size.rawValue)", variants: [.base], size: Self.canvas(size), settle: 0.25,
                                  defaults: [NotchViewModel.lockCardSizeKey: size.rawValue]) { variant in
                await self.card(session, variant: variant, pane: .lyrics, size: size, lyrics: .findingLocalLyrics)
            }
        }
        try await shoot.shoot("lyrics-long-lines", variants: variants, size: canvas, settle: 0.25) { variant in
            await self.card(session, variant: variant, pane: .lyrics, track: .init(elapsed: 16),
                            lyrics: LabFixtures.timeline(LabFixtures.longLines))
        }
        try await shoot.shoot("paused", variants: variants, size: canvas, settle: 0.25) { variant in
            await self.card(session, variant: variant, pauseAfter: true)
        }
        try await shoot.shoot("long-title", variants: variants, size: canvas, settle: 0.25) { variant in
            await self.card(session, variant: variant, track: LabFixtures.longTitle)
        }
        try await shoot.shoot("no-artwork", variants: [.base], size: canvas, settle: 0.25,
                              notes: "No cover: the Tinted card samples the desktop through NSVisualEffectView, which neither renderer can draw — it comes out flat. Only the hosting render is taken (ImageRenderer would draw a placeholder plate).") { variant in
            await self.card(session, variant: variant, track: .init(cover: nil))
        }

        await session.connectSpotify(liked: true)
        try await shoot.shoot("heart-liked", variants: variants, size: canvas, settle: 0.3,
                              notes: "A connected Spotify account (the lab's isolated one) and a song in Liked Songs.") { variant in
            await self.card(session, variant: variant, spotifyTrack: true)
        }
        await session.connectSpotify(liked: false)
        try await shoot.shoot("heart-not-liked", variants: variants, size: canvas, settle: 0.3) { variant in
            await self.card(session, variant: variant, spotifyTrack: true)
        }
        await session.connectSpotify(liked: false)
        LabNetworkGuard.slowSpotify = true
        try await shoot.shoot("heart-asking", variants: [.base], size: canvas, settle: 0.2,
                              notes: "Liked Songs has not answered yet: hollow and dimmed.") { variant in
            await self.card(session, variant: variant, spotifyTrack: true)
        }
        LabNetworkGuard.slowSpotify = false
        await session.disconnectSpotify()
    }
}

/// V1, confirmation and copy feedback that the panel tests do not reach.
@MainActor
final class VisualLabConfirmationTests: VisualLabCase {
    func testConfirmations() async throws {
        let session = try makeSession()
        let shoot = LabPhotographer(session: session, surface: "confirmation")
        let size = CGSize(width: 260, height: 60)
        func plate(_ content: some View) -> AnyView {
            AnyView(content.padding(12).frame(width: size.width, height: size.height).background(Color.black))
        }
        try await shoot.shoot("copy-button-idle", variants: [.base, .contrast], size: size) { _ in
            plate(CopyButton(copy: {}))
        }
        try await shoot.shoot("copy-button-copied", variants: [.base, .contrast], size: size,
                              notes: "Pressed through its accessibility action; the copy closure is a no-op.",
                              interact: { LabAccessibility.press(localized("Copy"), in: $0) }) { _ in
            plate(CopyButton(copy: {}))
        }
        try await shoot.shoot("confirm-text-idle", variants: [.base, .russian], size: size) { _ in
            plate(ConfirmTextButton(title: localized("Clear"), armedTitle: localized("Clear Everything"), action: {}))
        }
        try await shoot.shoot("confirm-text-armed", variants: [.base, .contrast, .russian], size: size,
                              interact: { LabAccessibility.press(localized("Clear"), in: $0) }) { _ in
            plate(ConfirmTextButton(title: localized("Clear"), armedTitle: localized("Clear Everything"), action: {}))
        }
        try await shoot.shoot("confirm-row-armed", variants: [.base, .contrast, .russian], size: CGSize(width: 360, height: 60),
                              notes: "The Settings row that quits, armed. The action is a no-op here.",
                              interact: { LabAccessibility.press(localized("Quit"), in: $0) }) { _ in
            AnyView(ConfirmRow(symbol: SettingsIcon.quit, title: localized("Quit"), armedTitle: localized("Quit Isla"), action: {})
                .padding(12).frame(width: 360, height: 60).background(Color.black))
        }
    }
}
