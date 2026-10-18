# Exhaustion round 3: the last hunt, and the completeness ruling

Produced 2026-10-11. Six Sonnet hunters attacked the last gaps the critic had named (long-run soak, Translate engines, the Spotify account, locales and right-to-left, Focus and presentation suppression, audio output hot-plug and the artwork pipeline) and produced 210 scenarios; an Opus critic deduplicated against 1 022 ledger rows and 162 findings, verified every high and medium suspect in code and, for Spotify behaviour, against Spotify's own migration guide, refuted 21 claims, and promoted 17 findings (0 P1, 3 P2, 14 P3). Discoveries per round: 40, then 27, then 17, with P1s falling 3, 1, 0. Ledger additions: 211 scenarios in `2026-10-11-scenario-ledger-round-3.json`, bringing the ledgers to about 1 230 rows.

## Verdict: complete = True

Deduped all six hunters' output, about 211 rows, against wave A, rounds 1 and 2 (1,022 ledger rows) and the 162-finding register (F, H, G, J, L). I verified every high and medium suspected defect by reading the cited code: SpotifyAccount, TokenStore usage, LockScreenCard, SystemVolume, AudioOutputs, Translator, TranslatePane, TranslationLanguage, NotchController's peek and ambient gates, RecordingPickup, NowPlayingFailurePolicy, NowPlayingPayloadDecoder, helper.m, the MediaController artwork and precision paths, test-localizations.sh and bundle.sh. Behaviour defined outside the code was checked against Spotify's own February 2026 migration guide.

Seventeen new findings survived, with no P1. Three are P2:
- K-001: the apiBlocked latch can never clear and survives a disconnect.
- K-002: Liked Songs still calls /me/tracks endpoints that Spotify retired for Development Mode apps on 2026-03-09.
- K-003: nothing suppresses peeks or charger and headphone moments over full screen, presentations, mirrored projectors or Focus.
The other fourteen are P3. About 25 hunter items were duplicates, extensions of existing fixes, or downgraded. One was rejected because it contradicts the tested contract that the island is present on every Space.

Every feature group has dozens to hundreds of scenarios. The thinnest are ambient moments (31, a two-trigger feature) and distribution (42, mostly scripted gates plus live Gatekeeper checks), and both are adequate for their size. Every dimension in the brief now has rows. Verified discoveries have fallen from 40 to 27 to 17, mostly P3, and what remains unknown needs a live Mac, a Spotify account or hardware, which belongs in the owner's live script. I sign complete.

## Coverage audit (scenarios per feature group)

| Feature group | Scenarios | Adequate | Note |
|---|---|---|---|
| music and media route | 246 | yes | Plus this round: K-013 restart policy, K-014 Apple-event churn, and soak rows for helper lifetime and descriptors. |
| lyrics clock and sources | 155 | yes | Lyrics lab (L-01..12) on 540 tracks, and the 12 h session row this round. |
| local lyric library and editor | 129 | yes | Round 2 covered the editor in depth. This round's resident-memory and O(N) lookup rows fall under F-043's fix. |
| Spotify account | 113 | yes | About 34 rows this round. K-001, K-002, K-015 and K-016 are new. Endpoint status and the keychain entitlement without a profile are live-only. |
| audio and lock card | 125 | yes | About 25 audio hot-plug rows this round (K-008, K-009, K-017). Device-specific behaviour (fixed-volume DAC, coreaudiod restart) is live-only. |
| lock screen | 111 | yes | Lock and unlock soak traced: listeners and spaces balance. Physical checks are in the owner's script. |
| Shelf | 227 | yes | Plus the Dropped/ uptime row, folded into F-019. |
| captures | 103 | yes | K-012 (the seen-name cap) is new. Vault byte growth was already a round-2 row. |
| Clipboard | 220 | yes | Pasteboard privacy, TCC and poll-rate rows complete. |
| Translate | 252 | yes | About 36 engine and routing rows this round (K-004, K-005, K-006). Model cancellation, rate limits and pack races are live-only. |
| privacy | 188 | yes | F-008 (sharingType under ScreenCaptureKit) is still live-only. Mirror and presentation exposure is now K-003. |
| ambient moments | 31 | yes | Small feature (charger, headphones). Plus about 6 rows this round on Focus, full screen and soak. K-003 covers suppression. |
| shell and interaction | 372 | yes | About 37 Focus, full-screen and menu-bar-reveal rows added this round. |
| hot keys | 153 | yes | Layout, recorder and conflict rows exist. The presentation-time hot key row was added. |
| intents | 144 | yes | Siri phrase localisation (round 1) and the intent toggle (F-024) are covered. |
| appearance and accessibility | 207 | yes | Wave B persona passes plus round-1 combinations. VoiceOver language tagging was noted this round. |
| Settings | 275 | yes | Every row and switch has scenarios. |
| updates and diagnostics | 83 | yes | G-027 and J-019. Diagnostics log flooding is now part of K-014. |
| distribution and signing | 42 | yes | Thin by count, but the area is mostly scripted gates plus live Gatekeeper checks. keychain-access-groups without a provisioning profile is live-only. |

## Findings (K-001 to K-017)

### K-001 After one 403, Spotify Web API calls stop for the rest of the process, and disconnecting does not clear the block
P2 · spotify-account · verified by critic: yes

- Evidence: refuse() sets apiBlocked = true (SpotifyAccount.swift:79-82). The only resets are in the success branches (:377, :418, :484). Every route to those branches is closed while the flag is set: trackMetadata returns at the guard `isConnected, !apiBlocked` (:465), the heart is drawn only when `!spotify.apiBlocked` (LockScreenCard.swift:836), and the heart's .task (:858) is the only caller of refreshSavedState. toggleSaved needs the heart. disconnect() (:290-297) resets saved, isConnected and the generation, but not apiBlocked, refusal or tokenUnavailable, and store() (:268-288) does not reset them either. SettingsPane.swift:491-492 shows the refusal whenever isConnected && apiBlocked. The doc comment at :34-36 says the flag 'clears on the next successful call', and no such call can happen. No test checks that the flag clears (SpotifyAccountTests:115 only checks that it is set).
- Scenario: The account gets one 403, for example before the owner adds it in the dashboard. The owner then adds the account, or the user buys Premium, or disconnects and connects a different account that works. The heart stays hidden, the ISRC lookup stays off, and Settings keeps showing the first account's refusal under the new account until Isla is relaunched.
- Fix direction: Reset apiBlocked, refusal and tokenUnavailable in disconnect() and store(). Allow a cheap re-probe after a cooldown (for example on the next lock, or 10 minutes after the 403) so a fixed account can recover. Add a test that a refused account recovers.
- Verification: Every reset path was traced. The latch is real, and new: the ledgers mention apiBlocked only for Settings display and token errors.

### K-002 Liked Songs calls endpoints Spotify retired for Development Mode apps (/me/tracks, /me/tracks/contains), and the refusal copy blames the listener for the owner's Premium
P2 · spotify-account · verified by critic: yes · needs live check

- Evidence: refreshSavedState calls GET /v1/me/tracks/contains (SpotifyAccount.swift:358). toggleSaved calls PUT and DELETE /v1/me/tracks (:405-410). Spotify's February 2026 migration guide (developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide, fetched 2026-10-11) lists PUT /me/tracks, DELETE /me/tracks and GET /me/tracks/contains as replaced by PUT/DELETE /me/library and GET /me/library/contains, which take Spotify URIs. Existing Development Mode apps were moved over on 2026-03-09. The same guide says 'All Development Mode apps require the app owner to have an active Spotify Premium subscription', caps new apps at 5 users, and keeps GET /tracks/{id}. The built-in client is a Development Mode app: checklist.md:654 is still open, and the .notRegistered copy assumes it. Refusal.from maps any 403 message containing 'premium' to 'Liked Songs needs Spotify Premium.' (:63, :72), which addresses the listener. The guide does not say what status the retired endpoints return. A non-403 goes to the retry path and gives up after 3 tries, leaving the heart dimmed and disabled (LockScreenCard.swift:845-855). A 403 gives the generic or the wrong refusal.
- Scenario: Any user connects Spotify with the built-in client and locks the Mac on a Spotify song. The heart either stays dimmed and disabled for the whole track, or disappears with a Settings note that names a cause the user cannot fix. Liking a song from the lock card never works.
- Fix direction: Move to GET /me/library/contains?uris=spotify:track:<id> and PUT/DELETE /me/library with URIs. Re-read the 403 copy so the owner's Premium is not presented as the listener's. Add the endpoint status check to the owner's live script.
- Verification: Endpoint replacement, migration date, owner-Premium rule and the 5-user cap were confirmed from Spotify's own guide. The retired endpoints' response status, and so which failure surface the user sees, needs a live call. No ledger row mentions the migration.

### K-003 Track peeks and charger and headphone moments appear over full-screen apps, presentations, games and mirrored or sole projectors, and there is no Focus integration
P2 · shell-interaction · verified by critic: yes

- Evidence: sneakPeek checks only sneakPeekEnabled, isOpen, isDropTargeted, ambient, isLockedPresentation, pointer and pill visibility (NotchController.swift:1281-1300). ambientAllowed takes switchOn, isOpen, isDropTargeted, isLocked, pointerInside, pointerUnderGrownPill and screensAsleep (:1377-1383). A grep of Sources for presentationOptions, CGDisplayIsCaptured, CGDisplayIsInMirrorSet, SetFocusFilterIntent and FocusFilter finds nothing, and frontmostApplication appears only in ShelfSharing. The panel is .canJoinAllSpaces + .fullScreenAuxiliary at statusWindow+1 (NotchPanel.swift:146), so it draws over full-screen Spaces. sharingType = .none hides it from capture, not from a hardware mirror. activeSpaceChanged (NotchController.swift:149-170) folds an open panel but does not cancel peekWork or ambientWork. No recorded project decision covers suppressing transient moments. The island's own visibility in full screen (wave-a, S9-b) is a separate question and is left alone.
- Scenario: A Keynote talk mirrored to a projector, or a laptop in clamshell mode presenting through HDMI, with Spotify playing in the background. The track changes, or the presenter plugs in the charger. A 2.2 s pill with the song title or battery percentage appears on the audience's screen. The same happens over a full-screen film or game. A user in a Sleep or Work Focus still gets every moment.
- Fix direction: Add one pure 'quiet' input to sneakPeek and ambientAllowed (ambientAllowed is already pure and unit-tested): a full-screen app frontmost (NSApp.currentSystemPresentationOptions or the Space type), CGDisplayIsInMirrorSet or a sole external display while presenting, and a SetFocusFilterIntent parameter beside the existing App Intents. Add one Settings row, default on, with en and ru strings and a checklist.md entry. Cancel peekWork and ambientWork in activeSpaceChanged.
- Verification: Both gate functions were read in full, and a grep of Sources confirmed no presentation, mirror, capture or Focus read exists. Whether the panel sits above Keynote's play window is still live-only. That does not change the finding for a mirrored display or a full-screen Space.

### K-004 Translate keeps the old answer or old failure on screen while a new request runs, so Retry looks dead and Copy can copy a translation of different text
P3 · translate · verified by critic: yes

- Evidence: translate() never clears output or failure when it starts (Translator.swift:414-466). They change only in received() (:471-477), clear() (:400-407) and the engine-loop end. TranslatePane.outcome checks failure first, then output, and shows the 'Translating…' spinner only when both are empty (TranslatePane.swift:159-200). Retry bumps attempt (:390). The pane waits 320 ms and re-runs, and through that wait plus the engine time the same failure text stays up. An identical failure never visibly changes. copyOutput (:566-571) copies output even when outputSource no longer matches the input. Obstacles .appleIntelligenceOff, .modelNotReady and .needsDownload offer no Retry (:299-305), so after the user fixes the cause the message stays until they edit the text or reopen the panel.
- Scenario: The user presses Retry after 'The translation could not be completed.' and nothing on screen changes for one to several seconds, then nothing changes again. Or the user edits a sentence after its translation appeared, presses Copy before the model finishes, and pastes a translation of the old sentence.
- Fix direction: While a run for different text is pending, dim or mark the output, compare outputSource with trimmed before enabling Copy, show the spinner over a failure while isTranslating, and add Retry to the obstacles the user can resolve outside Isla.
- Verification: Pane ordering and the translate() body were read. Retry offered for failures that cannot succeed (F-042) and re-translation of unchanged text (G-026, which also covers trailing-whitespace edits) are existing findings, not this one.

### K-005 On macOS 15, Translate Online sends every language pair to MyMemory while the Settings note says only languages 'such as Uzbek' go online
P3 · translate · verified by critic: yes

- Evidence: Below macOS 26, capabilities() returns belowMinimumSystem with systemSupported and modelSupportsPair both false (Translator.swift:341-346). offeredOnDevice is therefore false, and engines() lists .online for every pair (:269-275). The Settings note reads 'Languages this Mac cannot translate itself, such as Uzbek, are sent to MyMemory over the internet.' (SettingsPane.swift:462-463). The menus do mark every language (Online) once onDeviceLanguages is [] (:366-386), but they show no marker until that set loads.
- Scenario: A macOS 15 user turns on Translate Online expecting English to Russian to stay local, as the note implies. Every sentence they type goes to a third-party service.
- Fix direction: On macOS 15, word the note as 'This Mac translates nothing itself; everything is sent to MyMemory', or show it on the Translate Online row itself.
- Verification: Routing is deliberate and the menus disclose it, so the hunter's 'high' was lowered to a P3 copy defect: the Settings note misleads about what leaves the Mac.

### K-006 Short Ukrainian text is called Russian even when it contains ї, є or ґ
P3 · translate · verified by critic: yes

- Evidence: byLetters settles only on әөүұңһ, ўҳ and қғ (TranslationLanguage.swift:125-133), and its comment says і alone decides nothing. Fewer than 3 words need recognizer confidence ≥ 0.95, otherwise the fallback is containsCyrillic ? .russian (:110-114). Ukrainian is an offered language (:44, :61). With the default Russian target, route(detected:target:) then flips Russian to English (Translator.swift:224-231). ї, є and ґ appear in no other offered Cyrillic language.
- Scenario: A user types 'Дякую' or 'Їжак' with Detect on. The header reads Russian (Detected), and the engines are told the source is Russian.
- Fix direction: Add a byLetters rule: ї, є or ґ with no ы, ё, ъ or э means Ukrainian.
- Verification: Fallback order confirmed in code. The exact recognizer confidence for one Ukrainian word is unmeasured, but the letter rule removes the dependence. The kanji-only, Persian and out-of-list language cases are round-1 rows and were excluded.

### K-007 The localisation gate cannot catch an untranslated SwiftUI literal, a Russian value copied from English, or a third .lproj
P3 · localization · verified by critic: yes

- Evidence: test-localizations.sh collects only localized("…") calls, Button("…") literals, the welcome Copy block and intent titles. A literal in Text, Label, Toggle, Picker, .help or .accessibilityLabel is invisible to it. Today no such literal exists (grep of Sources), so this is a latent hole. Equal en and ru values are rejected only for InfoPlist.strings, not for Localizable. Both loops hard-code en and ru, and bundle.sh:57-59 writes CFBundleLocalizations [en, ru] while copying every Resources/*.lproj, so a new uz.lproj would ship untested and undeclared. CLAUDE.md calls this gate the guarantee that every user-facing string is localized.
- Scenario: A developer adds Text("Lyrics folder missing") or .help("Remove") and every gate passes. Russian users see English.
- Fix direction: Scrape the SwiftUI literal initialisers too, or fail on any bare literal outside an allowlist. Flag ru values equal to en except an allowlist (Spotify, AirDrop). Derive the locale list from Resources/*.lproj and check it against CFBundleLocalizations.
- Verification: Script read in full and Sources grepped. The English-only Siri phrases and the decimal-separator mismatch are round-1 rows and were excluded.

### K-008 The lock-card volume bar appears for devices whose volume cannot be set, and a drag that spans a default-output change sets the new device to the finger's level
P3 · lock-card · verified by critic: yes

- Evidence: SystemVolume.current() decides the bar exists from AudioObjectHasProperty plus a successful read (SystemVolume.swift:17-31, 50-63) and never checks AudioObjectIsPropertySettable. set() does check it and returns false (:73-76), but both callers ignore the result (LockScreenCard.swift:719, :743). The bar follows the finger, then snaps back on release (:722), which is the 'slider that moves and changes nothing' the file comment rules out (:10-14). set() also re-reads AudioOutputs.current() on every call (:38) with no device latched at drag start, so after AirPods take over mid-drag the next onChanged writes the absolute finger fraction to the AirPods. The audio.$volume mirror is ignored while dragging (:187-189).
- Scenario: (a) A fixed-volume USB DAC or HDMI output is the default. The bar drags and then jumps back, and nothing explains why. (b) A user drags the bar to 80% for the speakers just as AirPods connect. The AirPods, previously at 20%, jump to 80%.
- Fix direction: Hide the bar unless the property is settable. Latch the device id at drag start, and stop the drag if the default changes.
- Verification: Code paths confirmed. G-023 (absolute level on press, balance, mute) and F-045 (enumeration cost) are separate.

### K-009 The lock-card output picker never hears about devices plugged in or removed unless the default output changes, lists devices that cannot be default, and a failed pick does nothing
P3 · lock-card · verified by critic: yes · needs live check

- Evidence: AudioWatch registers only kAudioHardwarePropertyDefaultOutputDevice on the system object and VolumeScalar on the default device (AudioOutputs.swift:382-441). It has no kAudioHardwarePropertyDevices listener. Only AmbientWatch has one (AmbientWatch.swift:40), and its result is not shared. The feature inventory claims listeners re-read 'the device list'. available() filters on output channels and name only (:29-50, 168-181), never on kAudioDevicePropertyDeviceCanBeDefaultDevice or IsHidden. outputRow does `guard AudioOutputs.select(device.id) else { return }` (LockScreenCard.swift:561) with no feedback, no refresh and no haptic.
- Scenario: With the picker open on the lock card, the user plugs in a USB DAC that macOS does not auto-select. It never appears. They unplug a listed device, tap its stale row, and nothing happens. A Teams or Loopback sub-device in the list cannot be selected at all.
- Fix direction: Listen for kAudioHardwarePropertyDevices while the card is up, debounced, and filter on CanBeDefaultDevice and IsHidden. When select fails, re-read the list and drop the row.
- Verification: Listener set confirmed by grep. Whether select on a dead id returns an error is standard CoreAudio behaviour. Which real virtual devices report CanBeDefault false needs hardware.

### K-010 A cover over 4 MB never appears for that track: the app drops it, asks once, and the helper resends the same bytes
P3 · artwork · verified by critic: yes

- Evidence: The decoder keeps artwork only if the base64 and decoded data are ≤ 4 MB (NowPlayingPayloadDecoder.swift:34-38, 54), and drops it silently otherwise. The helper sends the full ArtworkData with no downscale (helper.m:293-298). With no cover showing, shouldAskForArtwork asks once (MediaController.swift:1588-1595, 1647-1656). The helper answers with the same oversized payload, it is dropped again, and alreadyAsked blocks a third try. The note placeholder follows after 2.5 s. No decoder test covers the cap.
- Scenario: A local FLAC or ALAC library with 5-10 MB embedded PNG covers played in Swinsian, Doppler or VOX. The island, panel and lock card show the grey note for every track.
- Fix direction: Downscale in the helper (CGImageSource thumbnail to about 600 px) before base64, which also fixes the decode-size half of F-044 for this route.
- Verification: Traced the decoder, the helper send, and the ask-once state. The decompression-bomb row (round 1) is about pixel size under the cap. This finding is about the byte cap itself.

### K-011 On the scripting fallback every skip blanks the cover at once, with none of the helper route's 180 ms grace or same-album reuse
P3 · artwork · verified by critic: yes

- Evidence: refreshFromPlayers sets artwork = nil whenever state.key changes, then fetches (MediaController.swift:1852-1858). The helper route waits 180 ms before blanking (:1617-1627) and keeps the cover for an album-mate (:1596-1607), a fix that was filmed on 2026-09-21. The fallback is the route DMG users with a Gatekeeper-blocked helper land on (see memory isla-gatekeeper-dylib-block). On macOS 26 the lock card's samplesBackdrop also depends on artwork == nil (LockScreenCard.swift:155), so the card switches between real and drawn glass at each skip.
- Scenario: A fallback-route user skips through an album in Music or Spotify. Each skip goes cover, skeleton, same cover, and the lock card's glass flickers type.
- Fix direction: Apply the same grace and album-mate rule in refreshFromPlayers, ideally by sending both routes through one artwork-transition function.
- Verification: Both branches read. The round-1 row covers fallback fetch failures with no retry, not skip polish.

### K-012 Screen-capture pickup fills its 1,000-name memory with files from before the install, then forgets an arbitrary third, so removed cards can come back
P3 · shelf-integrity · verified by critic: yes

- Evidence: collect() inserts every capture-shaped name into `seen` before the date test (RecordingPickup.swift:76-83), so files from before the install count toward seenLimit = 1000 (:40). Above the cap, trimSeen keeps names whose file exists and then `Set(kept.prefix(seenLimit))` (:133-140). That choice is arbitrary, and Set order changes with each launch's hash seed. Evicted names that postdate `since` are offered again (:82). ShelfStore persists the set on every open (ShelfStore.swift:226). Once over the cap, every Shelf open also pays one fileExists per name per folder.
- Scenario: A Desktop with about 1,500 old Screenshot*.png files and screen recordings. The user removes a recent recording card. On a later Shelf open it returns, with probability about 1 in 3 per open.
- Fix direction: Do not record names older than `since`, and evict by date rather than by Set order.
- Verification: Code read. Existing tests stay far below 1,000 names. J-021 covers the folder list, not the name set.

### K-013 The helper restart budget forgives by time since the first failure, so a helper that dies every 10-120 s is relaunched indefinitely
P3 · media-route · verified by critic: yes

- Evidence: recordFailure resets the window when more than 300 s have passed since windowStart (NowPlayingFailurePolicy.swift:36-38). recordSuccess() zeroes consecutiveFailures on any snapshot (:54-56). Delays are 2, 4, 8, 16, 32, 60, 60, 60 s (:50), 242 s in total, so a 9th failure inside 300 s needs lives averaging under about 7 s. Longer-lived crash loops reset to a 2 s delay each window: about 2,000 perl launches a day at a 10 s life. A plausible trigger is G-008, an uncaught exception on one player's metadata.
- Scenario: One player's metadata kills the helper about 10 s after each start. Isla relaunches perl for days, the island goes stale for 2-60 s each time, and it never falls back to scripting or says anything.
- Fix direction: Forgive by how long the helper survived (for example, reset only after 5 minutes alive), or count failures in a sliding window rather than one anchored at the first failure.
- Verification: The policy arithmetic was checked against the delays. It works as designed for sub-second flaps (tests) and fails for medium-life loops.

### K-014 With Spotify Automation denied, the 1 Hz precise-position poll keeps sending Apple events and logs an error every second, and episodes and ads are looked up five times each
P3 · media-route · verified by critic: yes

- Evidence: updatePrecisionSync gates on isActive, isPlaying, precisionPlayer and lyricsShown (MediaController.swift:714), and never on a refusal. Each failing run logs at error level (PlayerBridge.swift:494-498): about 3,600 persisted records an hour, which crowd Diagnostics' last half hour. spotifyTrackID returns nil for anything but spotify:track: (PlayerBridge.swift:80-88). requestSpotifyTrackID reads nil as 'no answer' and retries at 1, 2, 4 and 8 s (MediaController.swift:623-643), so every podcast episode, ad or local file costs 5 Apple events.
- Scenario: A user who denied Isla's Automation access to Spotify opens the lyrics page for an hour. Diagnostics then shows only AppleScript -1743 lines.
- Fix direction: Treat -1743 as sticky for the session and stop the precision loop and the id lookup. Have the id script distinguish 'not a track' from 'no answer'.
- Verification: Gate and log line confirmed. J-027 and the round-2 rows cover the denial's display effects and the track-id retry, not the 1 Hz loop or the log volume.

### K-015 Spotify sign-in edge cases: a second Connect breaks the first browser tab, a reconnect cannot pick a different account, and several failures are silent
P3 · spotify-account · verified by critic: yes

- Evidence: beginAuthorization overwrites verifier and authorizationState on every press (SpotifyAccount.swift:182, 185), so completing an earlier tab fails the constant-time state check and returns silently (:208-210). The authorize URL has no show_dialog=true (:188-196), so after Disconnect, Spotify reconnects the browser's signed-in account without a choice. NSWorkspace.open's result is ignored (:197). importLegacy reports success if any one of the three items copied (:529-537), and importLegacyAccount then hides the Import row unconditionally (:164-165). storeTokens discards TokenStore.write failures (:561-566), and store() still sets isConnected (:286).
- Scenario: A user presses Connect, gets distracted, presses again, and approves the first tab: nothing happens. A user who wants to switch accounts disconnects and reconnects, and gets the same account back.
- Fix direction: Keep the pending flow until it completes or times out. Pass show_dialog=true after a disconnect. Surface an open, import or write failure on the Spotify row.
- Verification: Code confirmed. The access_denied callback, a relaunch losing the verifier, and missing Settings text for tokenUnavailable are G-010. The refused-flag latch and Retry-After are round-1 rows.

### K-016 The Spotify track id can attach to the previous song for about a second after a skip, so the lock-card heart can show or like the wrong track
P3 · spotify-account · verified by critic: yes · needs live check

- Evidence: requestSpotifyTrackID checks only `track?.key == key` and the pid after the script returns (MediaController.swift:626-628). The script asks Spotify for its current track at execution time (PlayerBridge.swift:80-88), and MediaRemote trails Spotify by about a second. The metadata guard (:672) checks the id against itself, so it cannot catch this. The mistake corrects itself when the next snapshot clears the id (:1403-1410).
- Scenario: The user skips from the lock card and taps the heart in the first second. Spotify likes the new song while the card still shows the old title.
- Fix direction: Have the script return the name and artist with the id, and accept the id only when they match the snapshot.
- Verification: The race window follows from the guard and the documented MediaRemote lag. How often it happens needs a live skip.

### K-017 On macOS 26 the lock card's whole content subtree is rebuilt when the cover appears or disappears, which can cut off a scrub or volume drag in progress
P3 · lock-card · verified by critic: yes · needs live check

- Evidence: samplesBackdrop = style != .solid && media.artwork == nil (LockScreenCard.swift:155) feeds usesSystemGlass (GlassSurface.swift:242). body branches between content.glassEffect and drawn(content) (:253-259), which changes the identity of everything inside the card. An in-flight DragGesture is torn down without onEnded. scrubbing and draggingVolume are @State on the card (LockScreenCard.swift:60, 67) and survive, so the seek bar stays pinned to the old finger fraction and the volume mirror stays muted until the next drag. Triggered by K-011 on the fallback route, by the 180 ms blank on a coverless track, or by a decode failure.
- Scenario: A song with no cover follows one with a cover while the user is dragging the lock-card scrubber. The bar freezes at the finger position, and the seek may never land.
- Fix direction: Keep one view identity, for example by always applying both modifiers and toggling opacity or material, and reset scrubbing and draggingVolume when the track changes.
- Verification: The branch and identity change are confirmed in code. Whether SwiftUI cancels the gesture without onEnded in this setup needs a live drag.

## Refuted

- DUPE F-042: Retry offered after on-device guardrail or context-window failure (F-042's title and fix already cover failures that cannot succeed; the wave-a row expects 'no Retry').
- DUPE G-026: trailing space or Return re-translates the same trimmed text (same root cause: no outputSource comparison; G-026's fix covers it).
- DUPE J-017: hot key with a huge clipboard string goes uncapped to the engines.
- REFUTED as a defect: no on-device chunking for long text. The wave-a row records the intended local behaviour as 'context-window message'. Only the Retry part is real, and that is F-042.
- DOWNGRADED: macOS 15 routes every pair online. Routing is deliberate and the menus mark every language (Online). Kept only as the Settings-copy defect K-005.
- DUPE round-1: Spotify saved-state cache never invalidated after liking elsewhere (round-2 row with the same lines).
- DUPE round-1: CredentialStore refused latch after a transient empty read.
- DUPE round-1 / G-010: refresh 429 with no Retry-After; contains retries give up and leave the heart dimmed; tokenUnavailable after wake hides the heart; heart tap 401 rolls back silently; access_denied callback; quit or relaunch during browser sign-in.
- DUPE round-1: decompression-bomb cover under the byte cap.
- DUPE round-1: fallback or held route cover fetch failure never retried.
- DUPE G-008: helper calls base64EncodedStringWithOptions: on a non-NSData artwork value (another uncaught-exception path; G-008's fix of type checks and @try covers it).
- DUPE round-2: Screenshot vault bounded by count, not bytes; movie read whole on main.
- DUPE round-1: Persian and Urdu labelled Arabic; kanji-only Japanese called Chinese; Belarusian, Kyrgyz and other unsupported languages mislabelled; Hebrew falls to English (out-of-list language row).
- DUPE round-1: decimal point vs comma mismatch in Russian Settings; editor Timestamp field locale parsing; English-only Siri AppShortcut phrases.
- DUPE F-039 / G-039 / H-005: key-code editing shortcuts, hot-key labels on other layouts, Russian default target.
- DUPE F-008: ScreenCaptureKit may ignore sharingType; screen recording of clipboard rows.
- MERGED into F-019: Dropped/ promise files are reclaimed only at launch (runtime growth); fix by pruning on Remove and Clear as well as at launch, honouring live cards.
- COVERED by F-043 fix direction (index by mtime, parse lazily): 10,000-file library fully resident with 2x peak during rescan; O(N) lookup per track change; whole-index JSON rewrite per change.
- COVERED by F-044 fix (thumbnail decode at about 512 px): uncancelled concurrent artwork decodes during a skip storm; the per-decode size is what makes the burst expensive.
- REJECTED as contradicting the recorded behaviour: hide the resting pill in full screen. The island's presence on every Space is the tested contract (S9-b). K-003 targets only transient moments.
- NOT PROMOTED, rare or cosmetic: volume listener not re-attached when the same AudioObjectID returns; alpha covers blur to black with opaque: true; wired-jack data-source glyph stale; DebugTrail unbounded (verification-only flag); zero-offset nudge entries never pruned; Connect with a custom client id lacking the redirect URI.

## What remains (live-only, in the owner script; does not block completeness)

- Live-only, add to the owner's script, does not block: status and body Spotify returns for /v1/me/tracks/contains and PUT/DELETE /v1/me/tracks with the built-in client (confirms K-002's failure surface).
- Live-only: whether a Developer ID build with keychain-access-groups and no embedded provisioning profile launches and can write to the data-protection keychain, including while the screen is locked.
- Live-only: whether the panel, peeks and the hot-key-opened panel sit above Keynote and PowerPoint play windows and display-captured games (decides part of K-003's reach).
- Live-only: FoundationModels cancellation and rate limiting for a never-frontmost accessory app, and single-word detection confidence.
- Live-only, soak: footprint and vmmap over 12 h, leaks after 20 dock and 100 lock cycles, lsof on Isla and the perl helper on day 1 and day 7, ScrollWheelWatch monitor lifetime across a rebuild with the stage open.
- No code-readable gap remains that this critic can name. Universal Control and Sidecar have zero ledger rows but are display and pointer variants of existing multi-display rows and are live-only.
