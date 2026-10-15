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
            .general: [.launchAtLogin, .openOnHover, .panelWidth, .charging, .headphones, .newTracks],
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

    // MARK: - Volume and Brightness (R5): a row of the table, hidden behind one flag

    func testVolumeAndBrightnessIsHiddenBehindOneFlag() {
        XCTAssertFalse(SettingsTable.shipsVolumeAndBrightness, "R5 flips it")
        XCTAssertFalse(SettingsContext().offersVolumeAndBrightness)
        for section in SettingsSection.allCases {
            XCTAssertFalse(SettingsTable.rows(for: section, context: Self.everything).contains(.volumeAndBrightness),
                           "the HUD row is not shown in \(section)")
        }
        // The row exists, with its key and default, so R5 only wires behaviour.
        XCTAssertEqual(SettingsRowID.volumeAndBrightness.key, "island.showHUD")
        XCTAssertEqual(SettingsRowID.volumeAndBrightness.defaultValue, .off)

        // Flipping the one field is all it takes to show it, in General, last in
        // "The island shows".
        var shipped = SettingsContext()
        shipped.offersVolumeAndBrightness = true
        XCTAssertEqual(
            SettingsTable.rows(for: .general, context: shipped),
            [.launchAtLogin, .openOnHover, .panelWidth, .charging, .headphones, .newTracks, .volumeAndBrightness]
        )
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
        XCTAssertTrue(blocks.contains(.group([.charging, .headphones, .newTracks])))
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
            ("Volume and Output", .volumeAndOutput, .music),
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
        // Every row the enum has is placed somewhere, but the HUD's, which waits.
        let unplaced = Set(SettingsRowID.allCases).subtracting(homes.keys)
        XCTAssertEqual(unplaced, [.volumeAndBrightness], "only the row R5 turns on is unplaced")
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
        context.delayIsSet = true
        context.libraryHasFolders = true
        context.hasUnassignedCorrections = true
        context.lyricsNotice = "Couldn't read: a.lrc"
        context.showOnLockScreen = true
        context.spotify = SettingsPane.spotifyRows(
            connected: true, needsReconnect: false, signIn: nil, apiBlocked: false, canImport: true
        )
        context.offersDownload = true
        context.diagnosticsCopied = true
        return context
    }
}
