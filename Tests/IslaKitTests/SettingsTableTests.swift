import AppKit
import XCTest
@testable import IslaKit

/// Settings as a table (redesign 2026-10-15, spec §10, §14): the ten sections in
/// order, each one's rows, every default, the key each row stores under, the
/// renamed keys and the last section restored.
///
/// Pure, over private defaults suites: nothing here touches the standard domain,
/// the network, a player or the Spotify keychain.
@MainActor
final class SettingsTableTests: XCTestCase {
    private func suite() -> UserDefaults {
        let name = "com.ctimothe.isla.settingstable.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    override func tearDown() {
        LabLocalization.use("en")
        super.tearDown()
    }

    // MARK: - The ten sections

    func testTheTenSectionsAreInTheSpecsOrder() {
        XCTAssertEqual(
            SettingsSection.allCases,
            [.general, .privacy, .shortcuts, .music, .lyrics, .lockScreen, .translate, .spotify, .screenshots, .about]
        )
        XCTAssertEqual(SettingsTable.sections, SettingsSection.allCases)
        XCTAssertEqual(
            SettingsSection.allCases.map(\.title),
            ["General", "Privacy", "Shortcuts", "Music", "Lyrics", "Lock Screen", "Translate", "Spotify", "Screenshots", "About"]
        )
        XCTAssertEqual(Set(SettingsSection.allCases.map(\.rawValue)).count, 10, "ten distinct stored names")
    }

    /// Spec §10's icon column: the symbols and the five colours, and Spotify and
    /// About wearing an app's own mark.
    func testEachSectionsIconAndColourAreTheSpecs() {
        let expected: [SettingsSection: SettingsSection.Glyph] = [
            .general: .symbol("gearshape", .grey),
            .privacy: .symbol("hand.raised", .blue),
            .shortcuts: .symbol("keyboard", .grey),
            .music: .symbol("music.note", .rose),
            .lyrics: .symbol("quote.bubble.fill", .orange),
            .lockScreen: .symbol("lock.display", .indigo),
            .translate: .symbol("translate", .blue),
            .spotify: .spotify,
            .screenshots: .symbol("photo.on.rectangle", .grey),
            .about: .isla,
        ]
        for section in SettingsSection.allCases {
            XCTAssertEqual(section.glyph, expected[section], "\(section)")
            if case .symbol(let name, _) = section.glyph {
                XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil),
                                "\(name) does not resolve — the tile would draw no glyph")
            }
        }
        XCTAssertEqual(Theme.SettingsTint.grey.hex, 0x8E8E93)
        XCTAssertEqual(Theme.SettingsTint.blue.hex, 0x0A84FF)
        XCTAssertEqual(Theme.SettingsTint.rose.hex, 0xFF375F)
        XCTAssertEqual(Theme.SettingsTint.orange.hex, 0xFF9F0A)
        XCTAssertEqual(Theme.SettingsTint.indigo.hex, 0x5E5CE6)
    }

    /// Long names are the sidebar's problem, not the table's: Russian's Privacy
    /// is the longest and the one the board truncates at 480.
    func testTheRussianTitlesAreTheTablesTranslations() {
        LabLocalization.use("ru")
        XCTAssertEqual(SettingsSection.privacy.title, "Конфиденциальность")
        XCTAssertEqual(SettingsSection.shortcuts.title, "Сочетания клавиш")
        XCTAssertEqual(SettingsSection.about.title, "О программе")
        for section in SettingsSection.allCases where section != .spotify {
            XCTAssertNotEqual(section.title, section.rawValue, "\(section) is translated, not an identifier")
        }
    }

    // MARK: - Each section's rows, in order

    func testEachSectionsRowsAreSpecsRowsInOrder() {
        // The default context: a Mac with a battery, nothing failing, every
        // switch at its default. Conditional rows are tested below.
        let expected: [SettingsSection: [SettingsRowID]] = [
            // R5 (spec §12) turns Volume and Brightness on: last in "The island shows", off by default.
            .general: [.launchAtLogin, .openOnHover, .panelWidth, .charging, .headphones, .newTracks, .volumeAndBrightness],
            .privacy: [.clipboardHistory, .includeImages, .keepPinned, .coverClipboard, .coverTranslate, .hideFromRecording],
            .shortcuts: [.shortcutOpenPanel, .shortcutLyrics, .shortcutTranslate],
            .music: [.musicOnly, .volumeAndOutput, .lyricBand],
            .lyrics: [
                .showLyrics, .wordKaraoke, .showNextLineEarly, .lyricDelay, .translateLyrics, .translateTo,
                .lookUpLyricsOnline, .openLyricsFolder, .addLyricsFolder, .importLRC, .rescanLocalLyrics,
                .clearImportedLyrics, .clearBindings,
            ],
            .lockScreen: [.showOnLockScreen, .cardStyle, .restAsBanner, .cardSize],
            .translate: [.translateOnline, .keepHistory, .speakButton, .translationLanguages],
            .spotify: [.spotifyHead, .spotifyAccount],
            .screenshots: [.saveClipboardScreenshots, .showScreenCaptures, .showScreenshotsFolder, .clearScreenshotsFolder],
            .about: [
                .aboutHead, .updateStatus, .checkForUpdatesAutomatically, .copyDiagnostics, .reportProblem,
                .acknowledgements, .quit,
            ],
        ]
        for section in SettingsSection.allCases {
            var context = SettingsContext()
            context.hasBattery = true
            XCTAssertEqual(SettingsTable.rows(for: section, context: context), expected[section], "\(section)")
        }
    }

    /// The groups and what heads them, as the boards print them.
    func testTheGroupHeadersAreTheSpecsTitleCaseHeaders() {
        func headers(_ section: SettingsSection, _ context: SettingsContext = SettingsContext()) -> [String] {
            SettingsTable.blocks(for: section, context: context).compactMap {
                if case .header(let title) = $0 { return title } else { return nil }
            }
        }
        XCTAssertEqual(headers(.general), ["General", "The island shows"])
        XCTAssertEqual(headers(.privacy), ["Clipboard", "Cover"])
        XCTAssertEqual(headers(.shortcuts), ["Keyboard Shortcuts"])
        XCTAssertEqual(headers(.music), ["Music", "In the player"])
        XCTAssertEqual(headers(.lyrics), ["Lyrics", "Translation", "Online", "Local Lyrics Library"])
        XCTAssertEqual(headers(.lockScreen), ["Lock Screen", "Card Style"])
        XCTAssertEqual(headers(.translate), ["Translate"])
        XCTAssertEqual(headers(.spotify), ["Spotify"])
        XCTAssertEqual(headers(.screenshots), ["Screenshots"])
        XCTAssertEqual(headers(.about), [], "About opens on its head, not a header")
    }

    /// Conditional rows: each appears only while its condition holds.
    func testConditionalRowsAppearOnlyWhileTheirConditionHolds() {
        var noBattery = SettingsContext()
        noBattery.hasBattery = false
        XCTAssertFalse(SettingsTable.rows(for: .general, context: noBattery).contains(.charging),
                       "no battery, no Charging switch that could never do anything")
        XCTAssertTrue(SettingsTable.rows(for: .general, context: noBattery).contains(.headphones))

        var hover = SettingsContext()
        hover.opensOnHover = true
        XCTAssertEqual(
            SettingsTable.rows(for: .general, context: hover).prefix(4),
            [.launchAtLogin, .openOnHover, .hoverDelay, .panelWidth],
            "the delay is only a row while a hover is what opens the panel"
        )
        XCTAssertFalse(SettingsTable.rows(for: .general).contains(.hoverDelay))

        var login = SettingsContext()
        login.offersLoginItems = true
        XCTAssertTrue(SettingsTable.rows(for: .general, context: login).contains(.openLoginItems))
        XCTAssertFalse(SettingsTable.rows(for: .general).contains(.openLoginItems))

        var shortcuts = SettingsContext()
        shortcuts.canRestoreShortcuts = true
        XCTAssertEqual(SettingsTable.rows(for: .shortcuts, context: shortcuts).last, .restoreShortcuts)
        XCTAssertFalse(SettingsTable.rows(for: .shortcuts).contains(.restoreShortcuts))

        var delay = SettingsContext()
        delay.delayIsSet = true
        delay.libraryHasFolders = true
        delay.hasUnassignedCorrections = true
        let lyrics = SettingsTable.rows(for: .lyrics, context: delay)
        XCTAssertTrue(lyrics.contains(.resetLyricDelay))
        XCTAssertTrue(lyrics.contains(.libraryFolders))
        XCTAssertTrue(lyrics.contains(.unassignedCorrections))
        let plain = SettingsTable.rows(for: .lyrics)
        XCTAssertFalse(plain.contains(.resetLyricDelay) || plain.contains(.libraryFolders) || plain.contains(.unassignedCorrections))

        // Lock Screen: nothing to finish while there is no card.
        var off = SettingsContext()
        off.showOnLockScreen = false
        XCTAssertEqual(SettingsTable.rows(for: .lockScreen, context: off), [.showOnLockScreen])

        var update = SettingsContext()
        update.offersDownload = true
        XCTAssertTrue(SettingsTable.rows(for: .about, context: update).contains(.downloadUpdate))
        XCTAssertFalse(SettingsTable.rows(for: .about).contains(.downloadUpdate))
    }

    /// Spotify: not connected, Connect (and Import where there is something to
    /// bring across); connected, the one Disconnect — each a row of the group, the notes its
    /// footnotes. (There is no Liked Songs row: it could only show a guess, see
    /// `SettingsReviewFixTests`.)
    func testSpotifyShowsConnectOrDisconnect() {
        var context = SettingsContext()
        context.spotify = SettingsPane.spotifyRows(connected: false, needsReconnect: false, signIn: nil, apiBlocked: false)
        XCTAssertEqual(SettingsTable.rows(for: .spotify, context: context), [.spotifyHead, .spotifyAccount])

        context.spotify = SettingsPane.spotifyRows(
            connected: false, needsReconnect: false, signIn: nil, apiBlocked: false, canImport: true
        )
        XCTAssertEqual(SettingsTable.rows(for: .spotify, context: context), [.spotifyHead, .spotifyAccount, .spotifyImport])

        context.spotify = SettingsPane.spotifyRows(connected: true, needsReconnect: false, signIn: nil, apiBlocked: false)
        XCTAssertEqual(SettingsTable.rows(for: .spotify, context: context), [.spotifyHead, .spotifyAccount])
        let notes = SettingsTable.blocks(for: .spotify, context: context).compactMap { block -> String? in
            if case .footnote(let text) = block { return text } else { return nil }
        }
        XCTAssertTrue(notes.contains(localized("Isla forgets the account on this Mac. Your Spotify library stays as it is.")), "\(notes)")
        XCTAssertTrue(notes.contains(localized("The heart on the lock screen adds the song to your Liked Songs.")), "\(notes)")
    }

    // MARK: - The two failure groups: Music, and only while they hold

    func testTheFailureGroupsAreInMusicAndOnlyWhileTheirConditionHolds() {
        let failing = SettingsContext(
            nowPlayingFailure: NowPlayingRouteFailure.keptStopping.explanation,
            automation: SettingsPane.automationRows([.spotify: .denied, .music: .allowed])
        )

        let music = SettingsTable.blocks(for: .music, context: failing)
        XCTAssertEqual(music.prefix(3), [
            .header("Now Playing"),
            .group([.nowPlayingReader]),
            .footnote(NowPlayingRouteFailure.keptStopping.explanation),
        ], "the reader down comes first, with the reason under it")
        XCTAssertTrue(music.contains(.header("Automation")))
        XCTAssertTrue(music.contains(.group([.automationStatus, .automationPermission])))
        XCTAssertTrue(
            music.contains(.footnote(localized("Isla cannot read a player it is not allowed to control. Allow Isla under Privacy & Security › Automation."))),
            "the refusal's one sentence is the group's footnote"
        )

        // Neither condition: neither group, and nothing of them.
        let calm = SettingsTable.rows(for: .music)
        XCTAssertEqual(calm, [.musicOnly, .volumeAndOutput, .lyricBand])

        // Reader only, and automation only: each group stands alone.
        let readerOnly = SettingsTable.rows(for: .music, context: SettingsContext(nowPlayingFailure: "down"))
        XCTAssertTrue(readerOnly.contains(.nowPlayingReader))
        XCTAssertFalse(readerOnly.contains(.automationPermission))
        let automationOnly = SettingsTable.rows(
            for: .music, context: SettingsContext(automation: SettingsPane.automationRows([.spotify: .denied]))
        )
        XCTAssertTrue(automationOnly.contains(.automationPermission))
        XCTAssertFalse(automationOnly.contains(.nowPlayingReader))

        // A player that is allowed, not asked yet or not running is not a failure.
        for consent: AutomationConsent in [.allowed, .notAsked, .unknown] {
            let rows = SettingsTable.rows(
                for: .music, context: SettingsContext(automation: SettingsPane.automationRows([.spotify: consent, .music: consent]))
            )
            XCTAssertFalse(rows.contains(.automationStatus) || rows.contains(.automationPermission), "\(consent)")
        }

        // The one failure surface: in every other section, with every condition
        // true at once, Try Again and Open Automation Settings… are not drawn.
        for section in SettingsSection.allCases where section != .music {
            let rows = SettingsTable.rows(for: section, context: Self.everything)
            for failureRow: SettingsRowID in [.nowPlayingReader, .automationStatus, .automationPermission] {
                XCTAssertFalse(rows.contains(failureRow), "\(failureRow) in \(section): one failure surface")
            }
        }
    }

    // MARK: - Players on This Mac

    private func player(_ id: String, _ name: String) -> AppIcons.Installed {
        AppIcons.Installed(
            bundleID: id, url: URL(fileURLWithPath: "/Applications/\(id).app"), name: name,
            icon: NSImage(size: NSSize(width: 4, height: 4))
        )
    }

    /// The group sits right after Music Only and its footnote, before the
    /// player's own switches, and exists only while there is a player to list.
    func testPlayersOnThisMacFollowMusicOnlyAndNeedAPlayer() {
        XCTAssertFalse(
            SettingsTable.blocks(for: .music).contains(.header("Players on This Mac")),
            "no player installed: no header over an empty card"
        )
        var context = SettingsContext()
        context.installedPlayers = [player("com.apple.Music", "Apple Music"), player("com.spotify.client", "Spotify")]
        let blocks = SettingsTable.blocks(for: .music, context: context)
        let start = blocks.firstIndex(of: .header("Music"))!
        XCTAssertEqual(Array(blocks[start...].prefix(6)), [
            .header("Music"),
            .group([.musicOnly]),
            .footnote(localized("Videos and films stay off the island.")),
            .header("Players on This Mac"),
            .group([.installedPlayers]),
            .footnote(localized("These players always show. Any other app shows when it says it is playing audio.")),
        ])
        XCTAssertEqual(blocks[(start + 6)...].first, .header("In the player"))
        XCTAssertEqual(SettingsRowID.installedPlayers.kind, .custom, "drawn by a view of its own")
        XCTAssertEqual(SettingsRowID.installedPlayers.title, "Players on This Mac")
        XCTAssertNil(SettingsRowID.installedPlayers.key, "a statement about the Mac, not a setting")
        XCTAssertNil(SettingsRowID.installedPlayers.defaultValue)
    }

    /// Worded from `MediaSourcePolicy.allows`: music apps always; Telegram for a
    /// song and not for a video; any other app when it labels audio; and with
    /// Music Only off, everything.
    func testThePlayersFootnoteSaysWhatMusicOnlyDoesWithThem() {
        let plain = [player("com.spotify.client", "Spotify")]
        let withTelegram = plain + [player("ru.keepcoder.Telegram", "Telegram")]
        XCTAssertEqual(
            SettingsTable.playersNote(musicOnly: true, players: plain),
            "These players always show. Any other app shows when it says it is playing audio."
        )
        XCTAssertEqual(
            SettingsTable.playersNote(musicOnly: true, players: withTelegram),
            "These players always show, except Telegram, which shows songs but not videos. Any other app shows when it says it is playing audio."
        )
        XCTAssertNil(
            SettingsTable.playersNote(musicOnly: false, players: withTelegram),
            "Music Only off: its own footnote already says anything shows; the rule is stated once"
        )
        // And the policy agrees with every claim: a listed player passes with no
        // label, Telegram passes only for a song, an unknown app only if labelled.
        XCTAssertTrue(MediaSourcePolicy.allows(bundleIdentifier: "com.spotify.client", mediaType: nil, artist: ""))
        XCTAssertFalse(MediaSourcePolicy.allows(bundleIdentifier: "ru.keepcoder.Telegram", mediaType: nil, artist: ""))
        XCTAssertTrue(MediaSourcePolicy.allows(bundleIdentifier: "com.example.other", mediaType: MediaSourcePolicy.audioType, artist: ""))
        // Music Only off reads the switch from the context: the group has no
        // footnote and Music Only's says everything shows.
        var off = SettingsContext()
        off.musicOnly = false
        off.installedPlayers = plain
        let offBlocks = SettingsTable.blocks(for: .music, context: off)
        XCTAssertTrue(offBlocks.contains(.footnote(localized("Anything playing shows on the island, videos included."))))
        let group = offBlocks.firstIndex(of: .group([.installedPlayers]))!
        if case .footnote = offBlocks[group + 1] { XCTFail("a second footnote under the players with Music Only off") }
    }

    /// One statement of the rule (review 2026-10-15): with Music Only on, its
    /// footnote says only what it hides and the players' footnote says what
    /// always shows; neither repeats the other.
    func testTheRuleIsStatedOnceWithMusicOnlyOn() {
        var context = SettingsContext()
        context.installedPlayers = [player("ru.keepcoder.Telegram", "Telegram")]
        let footnotes: [String] = SettingsTable.blocks(for: .music, context: context).compactMap {
            if case let .footnote(text) = $0 { return text } else { return nil }
        }
        XCTAssertEqual(footnotes.filter { $0.contains("Music apps") || $0.contains("always show") }.count, 1, "\(footnotes)")
        XCTAssertFalse(footnotes.contains { $0.contains("podcasts") })
    }

    func testThePlayersGroupIsRussianToo() {
        LabLocalization.use("ru")
        XCTAssertEqual(SettingsRowID.installedPlayers.title, "Плееры на этом Mac")
        let note = try! XCTUnwrap(SettingsTable.playersNote(musicOnly: true, players: [player("ru.keepcoder.Telegram", "Telegram")]))
        XCTAssertTrue(note.contains("Telegram"), note)
        XCTAssertNotEqual(note, "These players always show, except Telegram, which shows songs but not videos. Any other app shows when it says it is playing audio.")
    }

    /// Spotify and About still wear an app's own icon; whether it is the real
    /// one is `AppIcons`' to say at draw time.
    func testSpotifyAndAboutKeepTheirAppIconGlyphs() {
        XCTAssertEqual(SettingsSection.spotify.glyph, .spotify)
        XCTAssertEqual(SettingsSection.about.glyph, .isla)
    }

    // MARK: - Volume and Brightness (R5): the row is shown, off, with its Accessibility group

    func testVolumeAndBrightnessIsShownOffByDefaultAndKeyedAsSpecified() {
        // R4 held the row behind one flag; R5 flips it (spec §12).
        XCTAssertTrue(SettingsTable.shipsVolumeAndBrightness, "R5 flipped it")
        XCTAssertTrue(SettingsContext().offersVolumeAndBrightness)
        XCTAssertEqual(SettingsRowID.volumeAndBrightness.key, "island.showHUD")
        XCTAssertEqual(SettingsRowID.volumeAndBrightness.defaultValue, .off, "off until chosen")
        XCTAssertEqual(NotchViewModel.showHUDKey, "island.showHUD")
        XCTAssertEqual(SettingsRowID.volumeAndBrightness.kind, .toggle)

        // Visible in General, last in "The island shows", and nowhere else.
        XCTAssertEqual(
            SettingsTable.rows(for: .general, context: SettingsContext()),
            [.launchAtLogin, .openOnHover, .panelWidth, .charging, .headphones, .newTracks, .volumeAndBrightness]
        )
        for section in SettingsSection.allCases where section != .general {
            XCTAssertFalse(SettingsTable.rows(for: section, context: Self.everything).contains(.volumeAndBrightness),
                           "the HUD row is not in \(section)")
        }
    }

    /// An absent key reads off, a stored one is obeyed, and the accessor the
    /// controller reads is the table's.
    func testTheAccessorReadsTheTableAndNotTheOwnersDefaults() {
        let defaults = suite()
        XCTAssertFalse(NotchViewModel.volumeAndBrightnessEnabled(in: defaults), "absent means the spec's default: off")
        SettingsRowID.volumeAndBrightness.write(true, in: defaults)
        XCTAssertTrue(NotchViewModel.volumeAndBrightnessEnabled(in: defaults))
        XCTAssertEqual(defaults.object(forKey: "island.showHUD") as? Bool, true)
        SettingsRowID.volumeAndBrightness.write(false, in: defaults)
        XCTAssertFalse(NotchViewModel.volumeAndBrightnessEnabled(in: defaults))
    }

    /// The "Accessibility" group, like the Music section's failure groups, exists
    /// only while its condition holds: the setting on and Isla not yet trusted.
    func testTheAccessibilityGroupExistsOnlyWhileOnAndUntrusted() {
        XCTAssertFalse(SettingsContext().needsAccessibility, "off, or trusted: no group")
        XCTAssertFalse(SettingsTable.rows(for: .general, context: SettingsContext()).contains(.accessibilityPermission))

        var missing = SettingsContext()
        missing.needsAccessibility = true
        let blocks = SettingsTable.blocks(for: .general, context: missing)
        XCTAssertTrue(blocks.contains(.group([.accessibilityPermission])))
        XCTAssertTrue(blocks.contains(.footnote(
            "Isla can’t see the volume keys yet. Until it can, the Mac shows its own pop-up."
        )))
        XCTAssertEqual(SettingsRowID.accessibilityPermission.title, "Accessibility")
        XCTAssertEqual(SettingsRowID.accessibilityPermission.kind, .push, "Open Privacy & Security… is a push button")
        XCTAssertNil(SettingsRowID.accessibilityPermission.key, "it stores nothing")

        // It follows the island's group and its footnote, as the board draws it.
        let rows = blocks.flatMap(\.rows)
        XCTAssertEqual(rows.last, .accessibilityPermission)

        // And it is hidden with the row while R5 is not offered.
        var notOffered = missing
        notOffered.offersVolumeAndBrightness = false
        XCTAssertFalse(SettingsTable.rows(for: .general, context: notOffered).contains(.accessibilityPermission))
        XCTAssertFalse(SettingsTable.rows(for: .general, context: notOffered).contains(.volumeAndBrightness))
    }

    func testTheAccessibilityStringsAreInBothTables() {
        for locale in ["en", "ru"] {
            LabLocalization.use(locale)
            for key in ["Accessibility", "Open Privacy & Security…", "Volume %@", "Brightness %@", "Keyboard Brightness %@",
                        "Isla can’t see the volume keys yet. Until it can, the Mac shows its own pop-up."] {
                XCTAssertFalse(localized(key).isEmpty, "\(locale): \(key)")
            }
        }
        LabLocalization.use("ru")
        XCTAssertEqual(localized("Accessibility"), "Универсальный доступ")
        XCTAssertEqual(localized("Open Privacy & Security…"), "Открыть «Конфиденциальность и безопасность»…")
        XCTAssertEqual(
            localized("Isla can’t see the volume keys yet. Until it can, the Mac shows its own pop-up."),
            "Isla пока не видит клавиши громкости. До тех пор Mac показывает своё окно."
        )
        LabLocalization.use("en")
    }

    // MARK: - Defaults and keys (spec §10 brackets, §14)

    func testEveryDefaultIsTheSpecs() {
        let expected: [SettingsRowID: SettingsDefault] = [
            .openOnHover: .off,
            .charging: .on, .headphones: .on, .newTracks: .on,
            .volumeAndBrightness: .off,
            .clipboardHistory: .on, .includeImages: .on, .keepPinned: .off,
            .coverClipboard: .off, .coverTranslate: .off,
            .hideFromRecording: .on,
            .musicOnly: .on, .volumeAndOutput: .on, .lyricBand: .on,
            .translateLyrics: .off,
            .lookUpLyricsOnline: .off,
            .showOnLockScreen: .on, .restAsBanner: .on,
            .translateOnline: .off, .keepHistory: .off, .speakButton: .on,
            .saveClipboardScreenshots: .off, .showScreenCaptures: .on,
            .checkForUpdatesAutomatically: .off,
            .panelWidth: .number(560),
            .lyricDelay: .number(0),
            .showNextLineEarly: .text("auto"),
            .translateTo: .text("automatic"),
            .cardStyle: .text("automatic"),
            .cardSize: .text("standard"),
        ]
        for (row, value) in expected {
            XCTAssertEqual(row.defaultValue, value, "\(row)")
        }
        // And an absent key reads as that default, from a suite nothing wrote to.
        let defaults = suite()
        for row in SettingsRowID.allCases where row.kind == .toggle {
            guard let isOn = row.defaultValue?.isOn else { XCTFail("\(row) is a switch with no default"); continue }
            if row.key != nil, row != .coverClipboard, row != .coverTranslate {
                XCTAssertEqual(row.isOn(in: defaults), isOn, "\(row) reads \(isOn) when nothing is stored")
            }
        }
    }

    /// §14's keys, written once and in the spec's spelling.
    func testTheKeysAreSpecs() {
        XCTAssertEqual(NotchViewModel.volumeAndOutputKey, "player.volumeAndOutput")
        XCTAssertEqual(NotchViewModel.lyricBandKey, "player.lyricBand")
        XCTAssertEqual(NotchViewModel.translateLyricsKey, "lyrics.translate")
        XCTAssertEqual(NotchViewModel.translateTargetKey, "lyrics.translateTarget")
        XCTAssertEqual(NotchViewModel.lockCardStyleKey, "lockCardStyle")
        XCTAssertEqual(NotchViewModel.restAsBannerKey, "lock.restAsBanner")
        XCTAssertEqual(NotchViewModel.clipboardIncludeImagesKey, "clipboard.includeImages")
        XCTAssertEqual(NotchViewModel.clipboardKeepPinnedKey, "clipboard.keepPinned")
        XCTAssertEqual(NotchViewModel.translateKeepHistoryKey, "translate.keepHistory")
        XCTAssertEqual(NotchViewModel.translateSpeakButtonKey, "translate.speakButton")
        XCTAssertEqual(SettingsSection.storageKey, "settings.lastSection")
        XCTAssertEqual(SettingsTable.volumeAndBrightnessKey, "island.showHUD")
        // The row table points at the same constants.
        XCTAssertEqual(SettingsRowID.volumeAndOutput.key, NotchViewModel.volumeAndOutputKey)
        XCTAssertEqual(SettingsRowID.keepHistory.key, "translate.keepHistory")
        XCTAssertEqual(SettingsRowID.speakButton.key, "translate.speakButton")
        XCTAssertEqual(SettingsRowID.restAsBanner.key, "lock.restAsBanner")
        XCTAssertEqual(SettingsRowID.cardStyle.key, "lockCardStyle")
    }

    /// The accessors the app obeys read their defaults from the table, so a
    /// default cannot be one thing in the form and another in the code: each is
    /// read from an empty suite, and from a suite holding the opposite.
    func testTheAccessorsReadTheTablesDefaults() {
        let empty = suite()
        XCTAssertEqual(NotchViewModel.volumeAndOutputEnabled(in: empty), true)
        XCTAssertEqual(NotchViewModel.lyricBandEnabled(in: empty), true)
        XCTAssertEqual(NotchViewModel.translateLyricsEnabled(in: empty), false)
        XCTAssertEqual(NotchViewModel.restAsBannerEnabled(in: empty), true)
        XCTAssertEqual(NotchViewModel.chargingEnabled(in: empty), true)
        XCTAssertEqual(NotchViewModel.headphonesEnabled(in: empty), true)
        XCTAssertEqual(NotchViewModel.newTracksEnabled(in: empty), true)
        XCTAssertEqual(NotchViewModel.translateKeepHistoryEnabled(in: empty), false)
        XCTAssertEqual(NotchViewModel.translateSpeakButtonEnabled(in: empty), true)
        XCTAssertEqual(NotchViewModel.lockCardStyle(in: empty), .automatic)

        let flipped = suite()
        flipped.set(false, forKey: NotchViewModel.chargingKey)
        flipped.set(true, forKey: NotchViewModel.translateKeepHistoryKey)
        flipped.set(false, forKey: NotchViewModel.translateSpeakButtonKey)
        XCTAssertFalse(NotchViewModel.chargingEnabled(in: flipped))
        XCTAssertTrue(NotchViewModel.headphonesEnabled(in: flipped), "one switch does not move another")
        XCTAssertTrue(NotchViewModel.translateKeepHistoryEnabled(in: flipped))
        XCTAssertFalse(NotchViewModel.translateSpeakButtonEnabled(in: flipped))
    }

    // MARK: - The last section, restored

    func testTheLastSectionDefaultsToGeneralAndIsRestored() {
        let defaults = suite()
        XCTAssertEqual(SettingsSection.stored(in: defaults), .general, "General when nothing is stored")
        SettingsSection.lyrics.store(in: defaults)
        XCTAssertEqual(SettingsSection.stored(in: defaults), .lyrics)
        XCTAssertEqual(defaults.string(forKey: "settings.lastSection"), "lyrics")
        defaults.set("a-section-this-build-does-not-have", forKey: "settings.lastSection")
        XCTAssertEqual(SettingsSection.stored(in: defaults), .general, "an unknown name is General, not a crash")
    }

    func testTheModelRemembersAndRestoresTheSectionShown() throws {
        let defaults = suite()
        let geometry = try LabGeometry.make()
        let first = NotchViewModel(geometry: geometry, stores: NotchStores(), defaults: defaults)
        XCTAssertEqual(first.settingsSection, .general)
        XCTAssertNil(defaults.object(forKey: SettingsSection.storageKey), "opening writes nothing")
        first.settingsSection = .screenshots
        XCTAssertEqual(defaults.string(forKey: SettingsSection.storageKey), "screenshots")

        // The next launch — a new model over the same defaults — opens there.
        let second = NotchViewModel(geometry: geometry, stores: NotchStores(), defaults: defaults)
        XCTAssertEqual(second.settingsSection, .screenshots)
    }

    /// Every way in that names a section selects it, opens the tab, and is
    /// remembered like any other visit.
    func testDeepLinksSelectTheirSection() throws {
        let defaults = suite()
        let vm = NotchViewModel(geometry: try LabGeometry.make(), stores: NotchStores(), defaults: defaults)
        vm.select(.media)

        vm.openLyricsSettings()
        XCTAssertEqual(vm.tab, .settings)
        XCTAssertEqual(vm.settingsSection, .lyrics, "Lyrics Settings… opens Lyrics")
        XCTAssertEqual(SettingsSection.stored(in: defaults), .lyrics)

        vm.select(.shelf)
        vm.openMusicOnlySetting()
        XCTAssertEqual(vm.tab, .settings)
        XCTAssertEqual(vm.settingsSection, .music, "the Music tab's remedy opens Music")

        vm.select(.clipboard)
        vm.openSettings(at: .privacy)
        XCTAssertEqual(vm.tab, .settings)
        XCTAssertEqual(vm.settingsSection, .privacy)

        // Leaving and coming back by the rail shows where it was, as a person
        // coming back to a settings window expects.
        vm.select(.media)
        vm.select(.settings)
        XCTAssertEqual(vm.settingsSection, .privacy)
    }

    // MARK: - The renamed keys (spec §10, last paragraph)

    func testTheRenamedKeysAreNewAndTheOldOnesAreKept() {
        XCTAssertEqual(NotchViewModel.chargingKey, "island.charging")
        XCTAssertEqual(NotchViewModel.headphonesKey, "island.headphones")
        XCTAssertEqual(NotchViewModel.newTracksKey, "island.newTracks")
        XCTAssertEqual(NotchViewModel.legacyShowChargingKey, "island.showCharging")
        XCTAssertEqual(NotchViewModel.legacyShowHeadphonesKey, "island.showHeadphones")
        XCTAssertEqual(NotchViewModel.legacySneakPeekKey, "sneakPeek")
        XCTAssertEqual(SettingsTable.renamedKeys.count, 3)
        XCTAssertEqual(SettingsRowID.charging.key, NotchViewModel.chargingKey, "the row reads the new key")
        XCTAssertEqual(SettingsRowID.headphones.key, NotchViewModel.headphonesKey)
        XCTAssertEqual(SettingsRowID.newTracks.key, NotchViewModel.newTracksKey)
    }

    func testAnOldValueIsCopiedOnceWhenTheNewKeyIsUnset() {
        let defaults = suite()
        defaults.set(false, forKey: NotchViewModel.legacyShowChargingKey)
        defaults.set(false, forKey: NotchViewModel.legacySneakPeekKey)
        // Headphones was never touched: it has no old value to carry.

        NotchViewModel.migrateRenamedKeys(in: defaults)
        XCTAssertEqual(defaults.object(forKey: NotchViewModel.chargingKey) as? Bool, false, "copied")
        XCTAssertEqual(defaults.object(forKey: NotchViewModel.newTracksKey) as? Bool, false, "copied")
        XCTAssertNil(defaults.object(forKey: NotchViewModel.headphonesKey), "nothing to carry, nothing written")
        XCTAssertFalse(NotchViewModel.chargingEnabled(in: defaults), "a switch turned off stays off after the update")
        XCTAssertFalse(NotchViewModel.newTracksEnabled(in: defaults))
        XCTAssertTrue(NotchViewModel.headphonesEnabled(in: defaults), "the default stands")
        XCTAssertEqual(defaults.object(forKey: NotchViewModel.legacyShowChargingKey) as? Bool, false, "the old key is left where it is")

        // Once: a choice made after the update is not overwritten by the old value.
        defaults.set(true, forKey: NotchViewModel.chargingKey)
        NotchViewModel.migrateRenamedKeys(in: defaults)
        XCTAssertEqual(defaults.object(forKey: NotchViewModel.chargingKey) as? Bool, true)
    }

    func testANewValueIsNeverTouched() {
        let defaults = suite()
        defaults.set(true, forKey: NotchViewModel.legacyShowHeadphonesKey)
        defaults.set(false, forKey: NotchViewModel.headphonesKey)
        NotchViewModel.migrateRenamedKeys(in: defaults)
        XCTAssertEqual(defaults.object(forKey: NotchViewModel.headphonesKey) as? Bool, false, "the new key was set: left alone")
        NotchViewModel.migrateRenamedKeys(in: defaults)
        XCTAssertEqual(defaults.object(forKey: NotchViewModel.headphonesKey) as? Bool, false, "and again")

        let empty = suite()
        NotchViewModel.migrateRenamedKeys(in: empty)
        for key in [NotchViewModel.chargingKey, NotchViewModel.headphonesKey, NotchViewModel.newTracksKey] {
            XCTAssertNil(empty.object(forKey: key), "nothing stored, nothing invented: \(key)")
        }
    }

    // MARK: - Labels: the renamed rows, and the old strings gone

    func testTheRenamedRowsReadTheirNewLabelsUnderTheirHeader() {
        XCTAssertEqual(SettingsRowID.charging.title, "Charging")
        XCTAssertEqual(SettingsRowID.headphones.title, "Headphones Connecting")
        XCTAssertEqual(SettingsRowID.newTracks.title, "New Tracks")
        let blocks = SettingsTable.blocks(for: .general)
        XCTAssertTrue(blocks.contains(.header("The island shows")))
        // R5 added Volume and Brightness to the group (spec §12).
        XCTAssertTrue(blocks.contains(.group([.charging, .headphones, .newTracks, .volumeAndBrightness])))
        LabLocalization.use("ru")
        XCTAssertEqual(SettingsRowID.charging.title, "Зарядку")
        XCTAssertEqual(SettingsRowID.headphones.title, "Подключение наушников")
        XCTAssertEqual(SettingsRowID.newTracks.title, "Новые треки")
    }

    /// The old labels went from both tables once nothing used them (spec §10):
    /// the pane no longer draws them, so the keys do not stay.
    func testTheOldStringsAreGoneFromBothTables() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for language in ["en", "ru"] {
            let text = try String(
                contentsOf: root.appendingPathComponent("Resources/\(language).lproj/Localizable.strings"), encoding: .utf8
            )
            for old in ["Show Charging", "Show Headphones Connecting", "Peek at New Tracks", "Application", "Quit"] {
                XCTAssertFalse(text.contains("\n\"\(old)\" ="), "\(old) is still in \(language).lproj")
            }
        }
    }

    // MARK: - Nothing was lost

    /// Every control the single list had, by what it was called, and the row of
    /// the new table it lives in — checked against the form with every condition
    /// true at once, so a conditional row is found where it appears. A control
    /// that could not be placed would have no row here.
    func testEveryControlOfTheOldPaneHasARow() {
        let old: [(String, SettingsRowID, SettingsSection)] = [
            ("Launch at Login", .launchAtLogin, .general),
            ("Open Login Items…", .openLoginItems, .general),
            ("Open on Hover", .openOnHover, .general),
            ("Hover Delay", .hoverDelay, .general),
            ("Panel Width", .panelWidth, .general),
            ("Show Charging", .charging, .general),
            ("Show Headphones Connecting", .headphones, .general),
            ("Peek at New Tracks", .newTracks, .general),
            ("Clipboard History", .clipboardHistory, .privacy),
            ("Include Images", .includeImages, .privacy),
            ("Keep Pinned Items", .keepPinned, .privacy),
            ("Cover Clipboard Rows", .coverClipboard, .privacy),
            ("Cover Translate Text", .coverTranslate, .privacy),
            ("Hide from Screen Recording", .hideFromRecording, .privacy),
            ("Open the panel (recorder)", .shortcutOpenPanel, .shortcuts),
            ("Show the lyrics (recorder)", .shortcutLyrics, .shortcuts),
            ("Translate the clipboard (recorder)", .shortcutTranslate, .shortcuts),
            ("Restore Default Shortcuts", .restoreShortcuts, .shortcuts),
            ("Try Again", .nowPlayingReader, .music),
            ("Automation status rows", .automationStatus, .music),
            ("Open Automation Settings…", .automationPermission, .music),
            ("Music Only", .musicOnly, .music),
            ("Players on This Mac", .installedPlayers, .music),
            ("Output Button", .volumeAndOutput, .music),
            ("Lyric Band", .lyricBand, .music),
            ("Show Lyrics", .showLyrics, .lyrics),
            ("Word Karaoke", .wordKaraoke, .lyrics),
            ("Show next line early", .showNextLineEarly, .lyrics),
            ("Lyric Delay (slider, Earlier, Later, preview)", .lyricDelay, .lyrics),
            ("Reset Lyric Delay", .resetLyricDelay, .lyrics),
            ("Look Up Lyrics Online", .lookUpLyricsOnline, .lyrics),
            ("Translate Lyrics", .translateLyrics, .lyrics),
            ("Translate To", .translateTo, .lyrics),
            ("Import LRC…", .importLRC, .lyrics),
            ("Add Lyrics Folder…", .addLyricsFolder, .lyrics),
            ("Remove <folder>", .libraryFolders, .lyrics),
            ("Rescan Local Lyrics", .rescanLocalLyrics, .lyrics),
            ("Open Lyrics Folder", .openLyricsFolder, .lyrics),
            ("Clear Imported Lyrics", .clearImportedLyrics, .lyrics),
            ("Clear Bindings and Timing Corrections", .clearBindings, .lyrics),
            ("Dismiss <correction>", .unassignedCorrections, .lyrics),
            ("Show on Lock Screen", .showOnLockScreen, .lockScreen),
            ("Rest as Banner", .restAsBanner, .lockScreen),
            ("Card Style", .cardStyle, .lockScreen),
            ("Card Size", .cardSize, .lockScreen),
            ("Translate Online", .translateOnline, .translate),
            ("Connect Spotify Account…", .spotifyAccount, .spotify),
            ("Disconnect Spotify Account", .spotifyAccount, .spotify),
            ("Import Account from Keychain…", .spotifyImport, .spotify),
            ("Save Clipboard Screenshots", .saveClipboardScreenshots, .screenshots),
            ("Show Screen Captures", .showScreenCaptures, .screenshots),
            ("Show Screenshots Folder", .showScreenshotsFolder, .screenshots),
            ("Clear Screenshots Folder", .clearScreenshotsFolder, .screenshots),
            ("Copy Diagnostics", .copyDiagnostics, .about),
            ("Report a Problem…", .reportProblem, .about),
            ("Check for Updates", .updateStatus, .about),
            ("Download Isla %@", .downloadUpdate, .about),
            ("Check for Updates Automatically", .checkForUpdatesAutomatically, .about),
            ("footer: About Isla", .aboutHead, .about),
            ("footer: Quit", .quit, .about),
        ]
        for (control, row, section) in old {
            XCTAssertTrue(
                SettingsTable.rows(for: section, context: Self.everything).contains(row),
                "\(control): no \(row) row in \(section)"
            )
        }
        // And no row is in two sections: a control has one home.
        var homes: [SettingsRowID: SettingsSection] = [:]
        for section in SettingsSection.allCases {
            for row in Set(SettingsTable.rows(for: section, context: Self.everything)) {
                XCTAssertNil(homes[row], "\(row) is in \(homes[row].map(String.init(describing:)) ?? "") and \(section)")
                homes[row] = section
            }
        }
        // Every row the enum has is placed somewhere — R5's Volume and Brightness
        // included — and `everything` makes the Accessibility group appear.
        let unplaced = Set(SettingsRowID.allCases).subtracting(homes.keys)
        XCTAssertEqual(unplaced, [], "every row has a home")
    }

    /// The glyphs the few rows that carry one wear all resolve.
    func testRowIconsResolve() {
        for row in SettingsRowID.allCases {
            guard let icon = row.icon else { continue }
            XCTAssertNotNil(NSImage(systemSymbolName: icon, accessibilityDescription: nil), "\(row): \(icon)")
        }
        XCTAssertEqual(SettingsRowID.allCases.filter { $0.icon != nil }.count, 7)
    }

    /// A row's kind decides what it draws; a switch has a default, a slider a
    /// number, and every row has a title.
    func testEveryRowHasATitleAndTheDefaultItsKindNeeds() {
        for row in SettingsRowID.allCases {
            XCTAssertFalse(row.title.isEmpty, "\(row)")
            switch row.kind {
            case .toggle: XCTAssertNotNil(row.defaultValue?.isOn, "\(row)")
            case .slider:
                if case .number = row.defaultValue {} else { XCTFail("\(row) is a slider with no number") }
            default: break
            }
        }
    }

    // MARK: - Support

    /// Every condition that adds a row true at once, for the checks that look for
    /// where a row is, not whether it shows today.
    static var everything: SettingsContext {
        var context = SettingsContext()
        context.hasBattery = true
        context.opensOnHover = true
        context.offersLoginItems = true
        context.canRestoreShortcuts = true
        context.nowPlayingFailure = NowPlayingRouteFailure.keptStopping.explanation
        context.automation = SettingsPane.automationRows([.spotify: .denied, .music: .allowed])
        context.installedPlayers = [
            AppIcons.Installed(
                bundleID: "com.spotify.client", url: URL(fileURLWithPath: "/Applications/Spotify.app"),
                name: "Spotify", icon: NSImage(size: NSSize(width: 4, height: 4))
            ),
        ]
        context.delayIsSet = true
        context.libraryHasFolders = true
        context.hasUnassignedCorrections = true
        context.lyricsNotice = "Couldn't read: a.lrc"
        context.showOnLockScreen = true
        context.needsAccessibility = true
        context.spotify = SettingsPane.spotifyRows(
            connected: true, needsReconnect: false, signIn: nil, apiBlocked: false, canImport: true
        )
        context.offersDownload = true
        context.diagnosticsCopied = true
        return context
    }
}
