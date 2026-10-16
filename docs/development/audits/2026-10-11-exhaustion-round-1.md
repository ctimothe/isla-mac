# Exhaustion round 1: scenario hunt and completeness critic

Produced 2026-10-11. Six Sonnet hunters attacked Isla along six dimensions (environment and hardware, failure injection, text and input, security and privacy, concurrency, accessibility combinations) and produced 285 scenarios; an Opus critic deduplicated them against the 435-row Wave A ledger, verified every high and medium suspected defect in code, refuted 19 claims, and promoted 40 findings. **The critic ruled the exploration not yet complete** and listed what a second round must attack (end of this file). Ledger additions: 215 genuinely new scenarios, stored in `2026-10-11-scenario-ledger-round-1.json`.

## Verdict: complete = False

I read both audit files, sampled the 435 ledger rows by title and checked the code behind every high- and medium-risk claim I promoted, and about half the low ones. Two claims I verified outside the source tree: ScreenCaptureKit's Localizable.loctable on this Mac has no 'Screenshot' key (G-001), and the 'Remove Local Binding' gate depends on in-session state (G-004).

The strongest new defects are:
- **Localized screenshots never reach the Shelf** (G-001).
- **Standard LRC tags reject whole files**, and LRCLIB caches those failures as 14-day misses (G-002).
- **The fallback route loses every scriptable-player feature**, because the pid is set only by the helper path. That matters because the project memory says ad-hoc DMG users land on the fallback (G-003).
- **The Spotify Automation prompt can appear at launch**, contradicting checklist.md (G-005).

Some hunter claims fell apart under the code:
- The lyric-stage 'following' state cannot leak into the next song: MediaPane.swift:110 closes the stage on every track change.
- The Translate reveal is documented as keyed to the pane, not to the text.

The intents-while-locked claim contradicts the recorded default-on lock card, which already shows the same content. Several security items assume a same-user attacker, which crosses no boundary. A cluster of items duplicates F-043, F-022, F-012, ledger rows 7, 52, 82, 134, 191, 192, 200 and 266, or owner decisions 16 and 21.

My ledger-addition count of 215 is an estimate. I deduplicated by title and intent against the ledger and backlog, not with an exact join.

I will not sign complete. Pasteboard privacy on macOS 27 could disable a whole feature and is unchecked. The lyric editor, legacy migration, media-key fallback, intents and upgrade/compat paths each have only a handful of scenarios or none. Many accessibility and TCC behaviours can only be settled live.

## Findings (G-001 to G-040)

### G-001 Screen-capture pickup never matches still screenshots on a non-English Mac
P1 · shelf-integrity · verified by critic: yes

- Evidence: RecordingPickup.swift:95-101 accepts a still image only when its name starts with a capture prefix. RecordingPickup.swift:116-118 looks up the localized prefix with Bundle(identifier: "com.apple.ScreenCaptureKit").localizedString(forKey: "Screenshot"). I read ScreenCaptureKit's Localizable.loctable on this Mac: it has 43 languages and no key containing 'creen'. The lookup therefore returns the key 'Screenshot', which is already in the list, so no localized prefix is ever added.
- Scenario: The Mac runs in Russian, German or Ukrainian, so Screenshot.app saves 'Снимок экрана 2026-10-11 в 15.04.05.png'. The user opens the Shelf. The still never appears. Movies still arrive because they are matched by type.
- Fix direction: Read the word from screencaptureui.app's table, or test the kMDItemIsScreenCapture / com.apple.metadata:kMDItemIsScreenCapture xattr instead of a name prefix (this also settles owner decision 13).
- Verification: Inspected the system loctable directly. The owner's own locales (ru/uz) are the affected ones.

### G-002 One standard LRC tag, one section label or one angle bracket rejects a whole lyric file, and an LRCLIB answer that fails this way is cached as a 14-day miss
P1 · lyrics-clock · verified by critic: yes

- Evidence: LocalLyricsDocument.swift:60-87 recognises only ti/ar/al/ve/length/offset. Any other bracketed line goes to parseTimedLine (:140-146), where parseTimestamp fails. Because the raw text contains ':', it throws invalidTimestamp and aborts parse(). Affected lines include [by:x], [re:x], [au:x], [#:comment], [id:x], [tool:x] and '[00:12.00][Verse 1: Drake]'. parseWords (:167-176) runs whenever the content has '<' or '>', and throws unless the content starts with '<', so a line like 'I <3 you' or 'a -> b' rejects the file. Local files then become .malformed (LocalLyricsLibrary.swift:276-277). For LRCLIB, OnlineLyrics.swift:97-100 and :227 use try? and turn the failure into .none, which OnlineLyricsCache.remember stores as searched miss for missLifetime (:343-344, 14 days).
- Scenario: The user adds a folder of LRC files from NetEase or a Russian lyrics site. Every file carrying [by:] or [re:] is listed as invalid. Or LRCLIB's synced text for a song contains '<3', and the song shows 'No lyrics found.' for two weeks.
- Fix direction: Treat any [word:value] header whose key is not numeric as metadata and skip it. Keep a non-timestamp bracket after a stamp as text. Parse word stamps only when the content starts with '<mm:ss'. Do not cache a parse failure as a miss.
- Verification: Traced each path in the parser by hand. The lab corpus (REPORT L1) contained no such lines, which is why it never surfaced. Distinct from F-009, which covers compressed stamps and their ordering.

### G-003 On the AppleScript fallback route, shuffle, repeat, precision sync, Spotify broadcasts, the heart and per-player lyric keying all switch off
P1 · media-route · verified by critic: yes

- Evidence: displayedPlayerPID is assigned only in apply() (MediaController.swift:1427) and clear() (:1726). refreshFromPlayers (:1831-1861) sets activeApp and the track but never the pid. displayedPlayerApp (:600-603) is derived only from the pid, so it is nil on this route. As a result, refreshPlaybackModes nils shuffle and repeat (:531-535), precisionPlayer is nil (:591-595), receiveSpotifyBroadcast returns early (:416), requestSpotifyTrackID never runs (:624) so there is no heart, and lyricPlayerID falls back to 'other' (:608-610). In the same code, artworkKey is set before the Spotify CDN fetch (:1853-1856), so a failed fetch is never retried for that track.
- Scenario: A DMG user's helper is refused by Gatekeeper (the known ad-hoc block in project memory), or the helper keeps stopping. Spotify plays. The panel shows no shuffle or repeat, the lock card has no heart, lyrics run on the 1 s-stale clock with no 1 Hz correction, and timing nudges are saved under 'other'.
- Fix direction: Derive the displayed scriptable app from activeApp when feedAvailable is false. Alternatively, resolve the player's pid from NSRunningApplication in refreshFromPlayers.
- Verification: checklist.md:30-36 says refusing Automation consent costs these controls. It does not say that the fallback itself loses them, and the fallback is exactly the route that has the consent.

### G-004 A binding whose LRC has gone leaves the track on 'No lyrics for this track.', never asks LRCLIB, and hides Remove Local Binding
P2 · lyrics-clock · verified by critic: yes

- Evidence: removeFolder (LocalLyricsLibrary.swift:197-206) and rescanFolders (:284-286) drop documents but never prune state.bindings. reloadImportedRecords (:489-499) does the same for missing imports. lookup() returns .invalid(.unreadable) for a binding with no record (:301-304). The online path runs only on .noMatch (LyricsCoordinator.swift:292). hasLocalOverride is set only by an import or select in the current session and is reset on every reconcile (LyricsCoordinator.swift:266). The trash button is gated on it (LyricsStage.swift:511), so after a track change or a relaunch even a healthy binding cannot be removed from the page.
- Scenario: The user binds a folder file to a song, then removes that folder in Settings or deletes the file. The song now shows 'No lyrics for this track.' forever. Retry repeats it, LRCLIB is never asked, and the only escape is importing another file or 'Clear bindings and timing corrections', which wipes every binding.
- Fix direction: Prune bindings whose id has no record, or treat a dangling binding as .noMatch. Derive hasLocalOverride from the persisted binding on every resolve.

### G-005 A Spotify listener gets the Automation prompt at launch and with the panel closed, and the script and a Web API call run for every track even with nothing consuming them
P2 · privacy-consent · verified by critic: yes · needs live check

- Evidence: apply() calls requestSpotifyTrackID on every track or player change (MediaController.swift:1430-1433). Its only guard is displayedPlayerIsSpotify (:587-589, :624), with no isActive check, no lyrics switch and no account check. It runs PlayerBridge.spotifyTrackID, an AppleScript to Spotify (PlayerBridge.swift:80-88). When connected, it then calls GET /v1/tracks/{id} (MediaController.swift:631, SpotifyAccount.swift:464-486). The resulting spotifyISRC and spotifyExactDuration have no reader outside MediaController (grep). checklist.md:32-37 records that macOS asks 'the first time the panel opens on Music or Spotify' and that 'Nothing is requested at launch'.
- Scenario: Isla launches at login while Spotify is playing. Lyrics are off and no account is connected. The TCC 'Isla wants to control Spotify' dialog appears unprompted, with no panel open to explain it.
- Fix direction: Gate the id lookup on an open panel or the lock card, and on lyrics-on or account-connected. Drop the unused catalogue lookup.
- Verification: The code path is certain. That TCC raises the prompt from a background accessory app at that moment needs a live check.

### G-006 With Caps Lock on, Command-A/X/C/V/Z do nothing in the Translate field
P2 · keyboard-shell · verified by critic: yes

- Evidence: NotchPanel.swift:103-105 masks the event flags with .deviceIndependentFlagsMask, which includes .capsLock, then requires flags.subtracting(.shift) == .command exactly. [.command, .capsLock] fails that test, the event falls to super.sendEvent, and an accessory app has no Edit menu to handle it (comment at :54-58).
- Scenario: Caps Lock is latched, and the user presses ⌘V to paste text into Translate. Nothing is pasted.
- Fix direction: Intersect with [.command, .control, .option, .shift] before comparing.
- Verification: Distinct from F-039, which is about key position.

### G-007 Lyric files in legacy encodings or common timestamp dialects are rejected, and Import / Add Folder / Rescan errors are discarded
P2 · lyrics-clock · verified by critic: yes

- Evidence: Every read is String(contentsOf:encoding: .utf8) (LocalLyricsLibrary.swift:164, 269, 409, 492). Windows-1251, UTF-16 and GBK files therefore throw, and the scan files them as .unreadable with no fallback (:278-279). parseTimestamp splits on the first ':' and needs Double(rest) (LocalLyricsDocument.swift:200-209), so [00:12,34] and [00:12:34] both throw and reject the file. NotchViewModel.swift:403, 412 and 420 call importLocalFile, addFolder and rescanFolders with try?. importLocalFile also returns silently when currentIdentity is nil (LyricsCoordinator.swift:195).
- Scenario: A Russian user imports a cp1251 .lrc. The panel closes and nothing happens, with no message.
- Fix direction: Try UTF-8 first, then detect the encoding with NSString's usedEncoding or a cp1251/UTF-16 fallback. Accept ',' and ':' as the fraction separator. Surface import errors as one section-level message.

### G-008 The media helper aborts on uncaught Objective-C exceptions where it was meant to degrade
P2 · media-route · verified by critic: yes · needs live check

- Evidence: emitPayload calls [NSJSONSerialization dataWithJSONObject:...error:NULL] and then checks `if (!json) return` (helper.m:91). Apple documents that this method raises, rather than returning nil, for invalid input such as NaN or Infinity. Duration, elapsed and rate are copied raw from MediaRemote (helper.m:260-262). activePlayerPath calls performSelector with no respondsToSelector check (helper.m:356-359). There is no @try anywhere in the file. Each abort costs one failure, and three failures move the route to fallback with the generic 'kept stopping' text.
- Scenario: A browser tab plays a live HLS stream whose Now Playing duration is +inf. The helper dies on every publish, and after three restarts browser audio vanishes from the island for the session.
- Fix direction: Replace non-finite numbers with 0 before serialising, or check isValidJSONObject first. Guard the selectors with respondsToSelector and emit the routeClosed error line instead.
- Verification: The mishandled API contract is certain from code and docs. Whether macOS delivers a non-finite value needs a live stream.

### G-009 A helper that stays alive but only reports empty or undecodable records counts as healthy, and a retry gives up the working fallback on its first empty record
P2 · media-route · verified by critic: yes · needs live check

- Evidence: helper.m:244-262 fills a record with '' or 0 when keys are missing, which is what a MediaRemote that refuses perl answers. NowPlayingFeed.consume refreshes lastLineAt on any byte (:428) and silently drops lines that do not decode (:441-462), so neither the watchdog nor the failure policy notices. feedDelivered (MediaController.swift:1819-1829) removes the fallback observers and sets feedAvailable before it looks at the snapshot. On the fallback displayedPlayerApp is nil (G-003), so admission returns .accept for an empty record (:1072-1074) and apply() clears the island (:1363).
- Scenario: A macOS update closes MediaRemote to perl again, as 15.4 did. The island says 'Nothing is playing' over a playing Spotify, and Settings shows no route problem. Or a wake retry hands over to a helper whose first record is empty while MediaRemote is still waking.
- Fix direction: Treat 'helper alive and no non-empty record for N seconds while a scriptable player reports playing' as a route failure. Hand over from the fallback only on a non-empty snapshot.

### G-010 A revoked or dead Spotify grant is never detected, and sign-in failures are silent
P2 · spotify-account · verified by critic: yes

- Evidence: tokenRequest returns nil for any status other than 200 (SpotifyAccount.swift:258-266). freshAccessToken returns nil but never clears the tokens or isConnected (:310-332). refreshSavedState has no 401 branch and retries with the same token (:368-380). toggleSaved rolls back silently (:415-417). Settings reads only isConnected and apiBlocked, never tokenUnavailable (SettingsPane.swift:470-492). The expiry is a wall-clock stamp (:270, :317-318). handleCallback returns silently without a code (error=access_denied), with no verifier after a relaunch, or when the exchange fails (:201-218, :241).
- Scenario: The user removes Isla at spotify.com/account/apps. Settings still says Connected, the heart vanishes, and every Spotify track change sends a failing refresh POST to accounts.spotify.com. Separately, pressing Cancel on Spotify's consent page leaves Isla offering Connect with no word of what happened.
- Fix direction: On invalid_grant or a 401 after a refresh, clear the tokens and show 'Reconnect Spotify' in Settings. On a 401, refresh once. Report denied and failed sign-ins in Settings.

### G-011 Copies made while the Mac is locked are recorded at unlock, against the code's stated intent
P2 · privacy-cover · verified by critic: yes

- Evidence: NotchController.swift:241-247 suspends the poll on lock because 'Universal Clipboard arrivals from a phone are not something to record behind a shield'. Unlock and wake call resumeFromIdleScreen, then refreshClipboardPolling() with settingChanged false, then clipboard.start() (NotchStores.swift:146-148, 196-198). start() deliberately keeps the old lastChangeCount (ClipboardStore.swift:113-118), so the first poll after unlock records whatever arrived during the lock. Only startFresh() re-baselines.
- Scenario: While the Mac is locked, a phone copy arrives by Universal Clipboard, or a script runs pbcopy over ssh. On unlock it appears in Clipboard history.
- Fix direction: Re-baseline (startFresh) on the unlock path while keeping start() for display wake, or record the change count at lock time.

### G-012 In the Edit Lyrics sheet, text buttons are forced into circle frames and the sheet may fold with the panel
P2 · lyrics-editor · verified by critic: yes · needs live check

- Evidence: NotchButtonStyle frames its label at width = height = size, with a Circle background and contentShape (Theme.swift:464-479). The sheet uses it for Cancel (24x24), Export LRC (76) and Save Copy (a filled 72x72 circle at title size) (LocalLyricsEditorView.swift:97-111). The sheet's minHeight is 340 pt (:116) against a 208 pt body. pointer.isDragging counts drags and menus but not sheets (NotchController.swift:948-950).
- Scenario: The user opens Edit Lyrics in English or Russian. 'Cancel' truncates inside a 24 pt circle, and 'Сохранить копию' wraps inside a large circle. When the user moves down to the lower fields, the pointer can leave the hover rect, the panel folds, and unsaved edits go with it.
- Fix direction: Use a text button style for the sheet row. Hold the panel open while a sheet is attached.
- Verification: The button layout is certain from code. The fold depends on where the sheet attaches relative to hoverRect, so it needs a live check.

### G-013 Import LRC binds the file to whatever song is playing when the open panel returns
P2 · lyrics-clock · verified by critic: yes

- Evidence: chooseLocalLyricsFile runs panel.runModal() and only then calls importLocalFile (NotchViewModel.swift:397-404). That reads currentIdentity at that moment (LyricsCoordinator.swift:194-198) and stores a persisted binding (LocalLyricsLibrary.swift:179). Nothing captures the identity when Import is pressed.
- Scenario: The user presses Import LRC for song A and browses for 20 s. Song B starts, and the user picks A's file. Song B is now permanently bound to song A's lyrics, and per G-004 the remove button is not shown after the next track change.
- Fix direction: Capture the identity when Import is pressed and pass it through.

### G-014 Translate detection is decided by a single character from another script
P2 · translate · verified by critic: yes

- Evidence: language(of:) runs byLetters, then byScript, before the recognizer (TranslationLanguage.swift:90-93). byScript returns on any kana, Hangul, Han, Arabic or Devanagari scalar in the first 400 characters (:138-156). byLetters returns Kazakh on any of 'әөүұңһ' (:124-131). The detected source then picks the engine. Kazakh and Uzbek are online-only, so with Translate Online on the text goes to MyMemory.
- Scenario: A Russian paragraph quotes one Kazakh name containing 'ү'. It is labelled 'Kazakh (Detected)' and, with Translate Online on, the whole paragraph is sent to MyMemory. Similarly, an English sentence containing one Japanese word is translated as Japanese.
- Fix direction: Weigh scripts by share of letters (for example, more than 30%) rather than by presence. Let the recognizer decide mixed text.

### G-015 A panel pinned open by an assistive-tech action has no accessible way to close
P2 · a11y-voiceover · verified by critic: yes · needs live check

- Evidence: The compact island's accessibility action opens the panel pinned (NotchContentView.swift:580, NotchViewModel pin rule). The header close strip is a bare .onTapGesture with no button trait or action (NotchContentView.swift:497-498). There is no accessibilityAction(.escape) anywhere in Sources (grep). The pin ends only on a real left or right mouse-down in another app (NotchController.swift:737-745).
- Scenario: A VoiceOver or Switch Control user opens Isla from the island. To close it they must know the global hot key, since VO-Escape and the header do nothing they can discover.
- Fix direction: Add .accessibilityAction(.escape) on the panel root and give the header strip a 'Close' button trait and label.
- Verification: Related to F-004, which covers the keyboard Escape path. This finding is the assistive-tech path.

### G-016 Online requests use URLSession.shared's disk cache and cookie store, so translated text and listening queries may persist on disk
P2 · privacy-network · verified by critic: yes · needs live check

- Evidence: OnlineTranslation.swift:46-66 sends the user's text as the q query item of a GET over URLSession.shared. LRCLIB (OnlineLyrics.swift:119-130), Spotify and the update check use the same shared session. There is no .ephemeral configuration, urlCache = nil or httpShouldHandleCookies anywhere in Sources (grep). The shared session's default URLCache stores cacheable GET responses, keyed by full URL, in ~/Library/Caches/com.ctimothe.isla.
- Scenario: With Translate Online on, the user translates a private message to Uzbek. The source text, in the URL, and the translation may sit in Cache.db indefinitely. The Translate cover implies the user treats this text as sensitive.
- Fix direction: Use one ephemeral URLSession with no cache and no cookies for every third-party request.
- Verification: The code is certain. Whether these services' response headers allow caching needs a live look at Cache.db.

### G-017 Now Playing titles lose ZWJ, ZWNJ, soft hyphens and tag characters
P3 · text-input · verified by critic: yes

- Evidence: NowPlayingPayloadDecoder.swift:59-64 strips CharacterSet.controlCharacters, which Apple defines as Cc plus Cf. That removes U+200D, U+200C, U+00AD and U+E0000-E007F, in addition to the intended bidi controls.
- Scenario: A title '❤️‍🔥' shows as a heart beside a fire, a family emoji splits into four people, and a Persian title loses its half-space. The same altered text goes to LRCLIB.
- Fix direction: Strip Cc and the bidi list only, and keep the joiners.

### G-018 Word-timed LRC rebuilds each line with a space between timed words
P3 · lyrics-clock · verified by critic: yes

- Evidence: Words are trimmed (LocalLyricsDocument.swift:184), and the line text is words.joined(separator: " ") (:162). serialize writes the same way (:121-123).
- Scenario: Per-character Chinese or Japanese karaoke displays and copies as '我 爱 你'. A syllable-split 'Hel<..>lo' shows as 'Hel lo'.
- Fix direction: Keep the text between markers verbatim, including whitespace, and join with no separator.

### G-019 An LRC with [offset:nan], [offset:inf] or a minutes field of 'inf' or 1e300 parses, then Save Copy or Export traps
P3 · lyrics-editor · verified by critic: yes

- Evidence: TimeInterval(String) accepts 'nan', 'inf' and huge values. The offset is not range-checked (LocalLyricsDocument.swift:81-86), and minutes have only a >= 0 check (:200-209). serialize then calls Int((offset * 1_000).rounded()) (:114) and Int((max(0, time) * 100).rounded()) (:217), which trap. The editor's save and export both serialize (LocalLyricsEditor.swift).
- Scenario: A downloaded or community LRC carries [offset:nan]. The user opens Edit Lyrics, presses Save Copy, and Isla crashes.
- Fix direction: Reject non-finite values and bound minutes in the parser.

### G-020 The lyrics folder watcher misses subfolders and in-place edits, and is never reinstalled after the folder goes away and comes back
P3 · lyrics-clock · verified by critic: yes

- Evidence: installFolderWatchers opens one O_EVTONLY descriptor per top-level folder with [.write, .rename, .delete] (LocalLyricsLibrary.swift:572-587), so it fires only for entries changed directly in that directory, as the comment at :289 itself says. It is reinstalled only by start, addFolder or removeFolder (:194, 205, 378-382). A folder absent at launch is skipped (:577-578), and a delete or rename only schedules a rescan (:589-596).
- Scenario: The library is laid out as Artist/Album/x.lrc, a sync client rewrites a file in place, or a USB drive is remounted. The new or changed lyrics are not seen until a relaunch or a manual Rescan, despite the '150 ms' promise in the inventory and Settings.
- Fix direction: Use FSEvents on the folder tree, and reinstall after .delete/.rename and on NSWorkspace didMount.

### G-021 An undecodable local-lyrics index is replaced with an empty one and overwritten with no backup
P3 · data-durability · verified by critic: yes

- Evidence: loadState returns State() on any decode error (LocalLyricsLibrary.swift:624-630). init then rescans and persist() rewrites index.json (:153-160, 614-618). An unknown enum raw value, for example from a newer worktree build sharing Application Support, is enough to trigger it.
- Scenario: An older build reads an index written by a newer one. Every folder, binding and import record is lost, and imports/*.lrc are left orphaned.
- Fix direction: Move the unreadable file aside before writing, and decode enums leniently.

### G-022 The screenshot vault never recreates its folder, and two saves in one second can share a name
P3 · shelf-integrity · verified by critic: yes

- Evidence: The folder is created only once, in init (ScreenshotVault.swift:18-44). write() never calls createDirectory and runs on the concurrent global queue with an unlocked fileExists loop (:115-136). A nil completion is ignored (NotchStores.swift:94-98), and the change count is already consumed.
- Scenario: The user deletes ~/Pictures/Isla in Finder. Every clipboard screenshot afterwards is silently dropped until relaunch.
- Fix direction: Run createDirectory before each write on a serial queue, and fall back to recording the text when the save fails.

### G-023 Lock-card volume sets an absolute level on mouse-down, flattens channel balance and ignores mute
P3 · lock-card · verified by critic: yes · needs live check

- Evidence: DragGesture(minimumDistance: 0).onChanged calls SystemVolume.set(x/width) on the first event (LockScreenCard.swift:713-720). For devices without a main element, set() writes the same scalar to channels 1 and 2 (SystemVolume.swift:36-45). There is no kAudioDevicePropertyMute read or write.
- Scenario: A user with one-sided hearing has set Balance on a USB DAC. One touch of the bar resets the balance to centre. A press near the right end on headphones jumps straight to near full volume.
- Fix direction: Use the AudioHardwareService virtual main volume, which preserves balance, reflect mute, and consider committing on drag rather than on press.

### G-024 Get Current Lyric returns a stale line while the panel is closed
P3 · intents · verified by critic: yes

- Evidence: CurrentLyricIntent reads model.media.position (IslaIntents.swift:108-113). The ticker runs only while the panel is open or the lock card is up (MediaController.swift:2057-2070), and the helper dedupes unchanged payloads for 5 s (helper.m:105-112).
- Scenario: A Stream Deck or Shortcut asks for the current lyric. The answer can be the line from several seconds earlier.
- Fix direction: Extrapolate from the anchor (the same formula as tick()) inside the intent.

### G-025 A late file promise reopens the panel regardless of lock or sleep, and is lost if the panel is rebuilt
P3 · shelf-integrity · verified by critic: yes · needs live check

- Evidence: deliverPromised leads to onDrop, then vm.accept, setOpen(true) and the Shelf tab (NotchRootView.swift:327-335, NotchController.swift:865-873), with no verdictForDeliberateOpen or screensAreAsleep check. The comment at NotchRootView.swift:255-262 expects late stragglers. The receivers and the batch hold the root view weakly, and rebuild() drops it (NotchController.swift:763-795).
- Scenario: A large iCloud Photos original finishes after the Mac locks, and the open body's active rect is applied over the shield. Or a display change mid-transfer leaves the file in Dropped/ with no card, and it is trashed after 7 days (F-019).
- Fix direction: Route promise arrivals through the stores, not the view. Add quietly without opening while locked or asleep.

### G-026 Unchanged Translate text is re-translated, and re-sent online, every time the tab reappears
P3 · translate · verified by critic: yes

- Evidence: .task(id: translator.request) runs schedule() on each appearance (TranslatePane.swift:61, 379-391). translate() never compares the input with outputSource (Translator.swift:407-459). OnlineTranslation re-sends every chunk (OnlineTranslation.swift:65-89).
- Scenario: The user switches between Music and Translate. Each return sends the same Uzbek text to MyMemory again and spends quota.
- Fix direction: Skip the run when outputSource == trimmed and the route is unchanged.

### G-027 The update check opens any html_url it is given
P3 · security · verified by critic: yes

- Evidence: Release.html_url is decoded as any URL (UpdateCheck.swift:83-96) and opened by 'Download Isla x' with NSWorkspace.shared.open (SettingsPane.swift:578-580). Only tag_name is validated.
- Scenario: A TLS-intercepting proxy, or a tampered response, supplies file:///… or an off-domain page behind an Isla-branded button.
- Fix direction: Accept only https://github.com/ctimothe/isla-mac/… and otherwise return .failed.

### G-028 The helper dylib is handed to perl with no identity check, inheriting Isla's environment
P3 · security · verified by critic: yes · needs live check

- Evidence: launch() passes the path from Bundle.main.path to /usr/bin/perl -e DynaLoader (NowPlayingFeed.swift:261-276). There is no code-signature or team check, task.environment is never set, and stderr goes to /dev/null. perl does no library validation.
- Scenario: A local process swaps libislamedia.dylib in a user-writable ad-hoc /Applications/Isla.app. Its code runs as Isla's child, under Isla's TCC responsibility (Automation, Desktop).
- Fix direction: Before launch, check the dylib with SecStaticCodeCheckValidity against the app's own designated requirement, and pass a minimal environment.

### G-029 The clipboard opt-out honours only the three org.nspasteboard markers
P3 · privacy-cover · verified by critic: yes

- Evidence: optOut lists ConcealedType, TransientType and AutoGeneratedType only (ClipboardStore.swift:98-102). There is no legacy marker and no source-app exclusion.
- Scenario: A manager or tool that still sets de.petermaurer.TransientPasteboardType, com.agilebits.onepassword or 'Pasteboard generator type' gets its password recorded in history.
- Fix direction: Add the legacy marker list that nspasteboard.org documents.

### G-030 The README privacy claim and a code comment are both false about Spotify cover fetches
P3 · privacy-network · verified by critic: yes

- Evidence: PlayerBridge.artwork fetches Spotify's https artwork URL with URLSession.shared, with no setting, on the fallback and held routes (PlayerBridge.swift:230-244; callers at MediaController.swift:1266, 1856). Its comment says 'The one thing the app ever fetches'. README.md:57-66 says nothing leaves the Mac unless it is turned on.
- Scenario: An owner audit or a user reading the README believes no request leaves without a switch.
- Fix direction: List the cover fetch, which goes to Spotify's CDN with no user data beyond the IP, in the README table, and correct the comment.

### G-031 The Services menu item 'Translate in Isla' is English-only
P3 · localization · verified by critic: yes

- Evidence: NSServices NSMenuItem default is the literal 'Translate in Isla' (Scripts/bundle.sh:69-76). There is no ServicesMenu.strings in Resources/en.lproj or Resources/ru.lproj, and InfoPlist.strings carries only usage descriptions.
- Scenario: On a Russian Mac, the Services menu shows the item in English.
- Fix direction: Add ServicesMenu.strings for en and ru, and extend test-localizations.sh to cover it.

### G-032 Liked Songs writes race, and a disconnect does not stop an in-flight lookup
P3 · spotify-account · verified by critic: yes

- Evidence: Each heart tap spawns an unserialised Task with an optimistic write and a PUT or DELETE (SpotifyAccount.swift:392-421). refreshSavedState writes saved[trackID] after its await with no generation check (:347-379), even though disconnect() clears saved and bumps credentialGeneration (:290-297).
- Scenario: A quick double tap can leave Spotify liked while the heart shows hollow. A disconnect during a lookup writes the old account's answer back.
- Fix direction: Serialise writes per track (last tap wins), and check credentialGeneration after each await.

### G-033 A flapping charger re-fires the charging moment on every reconnect
P3 · system-lifecycle · verified by critic: yes

- Evidence: powerChanged emits an event on every false-to-true external-power edge (AmbientWatch.swift:94-110) with no quiet window. Headphones have repeatQuiet of 30 s (:156-169).
- Scenario: A loose USB-C dock drops and restores power every few seconds, and the pill re-grows each time.
- Fix direction: Apply the same quiet window to power.

### G-034 A VoiceOver scrubber step is 5% of the track's length
P3 · a11y-voiceover · verified by critic: yes

- Evidence: Both adjustable actions use step = media.duration * 0.05 (MediaPane.swift:379-386, LockScreenCard.swift:671-678).
- Scenario: On a 3-hour audiobook or podcast, each increment jumps 9 minutes.
- Fix direction: Use a fixed step of 10-15 s, or clamp the percentage step.

### G-035 LRCLIB edition stripping mishandles full-width brackets and titles made entirely of brackets
P3 · lyrics-clock · verified by critic: yes

- Evidence: baseTitle's regex strips only ASCII ( ) [ ] (OnlineLyrics.swift:238-240). Every bracket group is removed, so '(Nice Dream)' becomes '' and bestMatch then returns nil (:209-212).
- Scenario: 'Title（Remastered）' never matches its LRCLIB row, and a title that is itself in brackets never matches.
- Fix direction: Add the full-width and CJK bracket pairs, and keep the bracket text when stripping would leave nothing.

### G-036 Switching between the fallback and the helper route re-announces an unchanged song
P3 · media-route · verified by critic: yes

- Evidence: The fallback key is 'app|title|artist|album' (PlayerBridge.swift:46), while the helper key is 'pid|title|artist|album' (MediaController.swift:1397). The peek sink fires on any key change (NotchController.swift:1064-1072). LyricsCoordinator re-resolves on a new logicalTrackKey (LyricsCoordinator.swift:243-269). Late fallback replies have no feedAvailable guard (MediaController.swift:1832-1860).
- Scenario: A wake retry hands the route back to the helper while the same song plays. The pill peeks, the lyrics re-resolve and the cover blinks, possibly twice.
- Fix direction: Key logical identity on app plus metadata on both routes, and drop scripted replies once the feed is available.

### G-037 Persisted wall-clock stamps are trusted even when the clock was wrong
P3 · system-lifecycle · verified by critic: yes

- Evidence: recordings.since is stamped once with Date() (NotchStores.swift:71-74). collect() inserts a name into seen before testing date > since (RecordingPickup.swift:76-83), so captures taken under a future 'since' are rejected permanently. Miss-cache age is Date().timeIntervalSince(checkedAt) with no check for negative values (OnlineLyrics.swift:335). The drop-inbox prune uses a wall-clock cutoff (AppPaths.swift:67).
- Scenario: A first launch with the clock ahead (a new VM, or before NTP) means every screenshot taken until real time catches up never reaches the Shelf, even after the clock is fixed.
- Fix direction: Clamp future stamps to now when read, and insert into seen only what was actually judged.

### G-038 The karaoke edge runs ahead on truncated lines
P3 · lyrics-clock · verified by critic: yes

- Evidence: wordFraction is computed over every word in the line (LyricSweep.swift:128-152). KaraokeRenderer maps it onto the width of the runs actually laid out (KaraokeText.swift:28-37). With lineLimit 1 on the lock card or 2 on the stage, the ellipsized runs cover only part of the line.
- Scenario: A long Russian line on the lock card is fully lit while the singer is mid-line.
- Fix direction: Base the fraction on the visible characters, or drop the line limit while sweeping.

### G-039 Hot key labels use US key names on Dvorak, AZERTY and QWERTZ layouts
P3 · keyboard-shell · verified by critic: yes

- Evidence: keyName uses a fixed US table, and any other key shows as '#<code>' (HotKeys.swift:92-98). The comment's premise, that menus show the Latin letter, holds only for non-Latin layouts.
- Scenario: On Dvorak, Settings and the welcome say ⌃⌥⌘I, but the shortcut fires on the key printed 'C'.
- Fix direction: Name keys through UCKeyTranslate with the current ASCII-capable layout. Keep the US names only for non-Latin layouts.

### G-040 A transport tap held during a helper restart is very likely dropped by the new helper
P3 · media-route · verified by critic: yes · needs live check

- Evidence: launch() writes pendingCommand right after task.run() (NowPlayingFeed.swift:316-319). In the helper's constructor, startFeed (which dlopens MediaRemote) and the command reader start together (helper.m:516-524). fgets returns at once with the buffered line, and handleCommand returns silently while sFeedReady is false (helper.m:370-373), which is set only after the dlopen and dlsym calls (:443).
- Scenario: The user taps Pause during the 2 s restart window. The icon flips, then reverts 1.5 s later, and the player never pauses, despite the promise in the comment at NowPlayingFeed.swift:312-315.
- Fix direction: Queue commands in the helper until the feed is ready, or replay from the app on the first snapshot.

## Refuted

- Lyric stage keeps reading mode into the next song (concurrency): refuted. MediaPane.swift:110 sets showingLyrics false on every track.key change, which tears down LyricsStage and its @State 'following'.
- Translate reveal carries over to text pasted by the hot key (concurrency/security): a documented design choice. TranslatePane.swift:24-26 says the reveal is 'per-session and keyed to the pane, not to any particular text'. The output-visibility part is F-002 and F-021.
- Translate hot key ignores ConcealedType (security): the hot key is an explicit user request to read the clipboard. The off-Mac half is owner decision 21, so merged there.
- Intents read the track and lyric and drive transport while locked (security): contradicts a recorded decision. The lock card is default-on (checklist.md:99-108) and already shows the same track, lyric and transport over the shield.
- Forged com.apple.screenIsLocked or Spotify broadcasts, PERL5OPT/defaults tampering, and the '..' path in index.json enabling Clear Imported Lyrics deletion (security): no privilege boundary is crossed. Each needs a same-user process that can already do everything these achieve.
- HotKeys UInt32 overflow trap (failure): HotKeys.swift:146-152 can trap, but only on a hand-edited defaults value. No UI path stores more than 32 bits.
- lyrics.userOffset NaN via Set Lyric Delay (failure/security): the intent's parameter declares inclusiveRange (-3, 3) (IslaIntents.swift:159), which the system validates. NaN otherwise needs defaults tampering.
- Int(duration) trap in the OnlineLyrics request/cache key on Infinity (security): unreachable. A non-finite number cannot cross the helper's JSON (the helper throws first, see G-008), and fallback durations come from integer milliseconds.
- Peek survives sleep or lock: duplicate of ledger row 52 ('Display sleep during a peek or ambient moment').
- LRCLIB outage reads as 'No lyrics found.': duplicate of ledger row 200. Auto-retry at 5/30/120 s instead of a Retry button is recorded at checklist.md:70-71.
- Mixed-direction and RTL karaoke sweep: duplicate of ledger rows 134, 191 and 192 and the backlog's 'RTL karaoke sweep'.
- Huge or home-folder lyrics root, iCloud dataless files and stalled SMB during the scan: merged into F-043 (same root cause, the synchronous main-thread rescanFolders in init at LocalLyricsLibrary.swift:159). F-043 should add a file-count/depth cap, because picking ~ hangs every launch.
- Shelf scan and TCC prompt on drag-enter: merged into F-022 (importNewRecordings on the main thread when the Shelf tab is shown).
- On-screen keyboard or head-pointer user loses the panel while typing: owner decision 16 (the pointer decides by design).
- Increase Contrast rim missing on the system-glass lock card: merged into F-012.
- Press drift cancels the island open, the 3 pt Shelf drag threshold and the fixed 0.32 s close delay: duplicates of ledger rows 7, 82 and 60 plus the close-rect owner items.
- Clipboard 256 KiB cap leaves a trailing U+FFFD: duplicate of ledger row 266.
- SkyLight ABI change on macOS 27: no defect shown. The hunter verified the symbols are present, and ledger row 353 covers the version matrix.
- Volume jumps on a click (rated high by the a11y hunter): demoted to P3 inside G-023. macOS's own NSSlider and Control Center sliders also jump to the clicked point, so this is not a platform deviation.

## Remaining gaps (what round 2 must attack)

- Pasteboard privacy on macOS 26/27 (NSPasteboard accessBehavior / 'Paste from other apps') is the largest unknown. This Mac runs 27.0.1. If programmatic reads prompt or return nil, Clipboard history and clipboard-screenshot pickup silently stop working. This needs one live check before anything else in the clipboard cluster.
- Local lyric editor (Edit Lyrics sheet): only layout and text scenarios exist. Uncovered: Save Copy versus Export semantics, what Save does to a folder-owned file and its binding, validation of out-of-order timestamps, the sheet while the panel folds or the track changes, keyboard and Escape inside the sheet, and the regional decimal format of the timestamp field.
- Legacy migration (v4/v5 overrides and offsets into lyrics-local) has zero scenarios. Uncovered: a partial or failed migration, a rerun after downgrade, and unassigned imports and offsets as presented in Settings.
- Settings > Music library management (Clear Imported Lyrics, Clear bindings and timing corrections, the unassigned imports list, Reveal folder, Remove folder) and the per-track timing nudge persistence (keyed by player and identity) are thin: about 2 rows each.
- System media-key fallback (posts play/next keys, needs Accessibility, fails silently) has no scenario in either the ledger or the hunters.
- Intents: 8 intents but about 8 scenarios total. Uncovered: intents while the helper is down or on the fallback, Next/Previous coalescing, Set Lyric Delay persistence against the slider, the Siri spoken result (no ProvidesDialog), and intents during app launch on a cold start.
- Music Only allowlist and media-type heuristics (Yandex Music, Telegram songs versus videos, podcasts as lyric targets) have about 2 rows. Podcasts reaching LRCLIB with episode titles was noted by a hunter but not verified here.
- There is no hunter dimension for upgrade and data compatibility: defaults key changes, index and cache schema drift across worktree builds sharing Application Support, downgrade, and the legacy keychain import. G-021 is the only probe.
- Live-only accessibility behaviour is largely unproven: whether SwiftUI Slider onEditingChanged fires for VoiceOver increments (Panel Width and Hover Delay may never commit), tooltips on a never-key panel, AX window identity across the orderOut/orderFront keyboard handback, and VoiceOver reachability of the lock card at SkyLight level 400.
- TCC timing: the Desktop/Documents prompt raised inside a drag callback (F-022 path), at launch for a watched lyrics folder under ~/Documents, and the Spotify Automation prompt at launch (G-005). All need one controlled live session.
- Network etiquette is not covered: Retry-After handling for LRCLIB and Spotify 429, behaviour after the three lyric retries are spent with no reachability hook, and MyMemory per-pause prefixes (fold into F-042).
- Unverified claims left unpromoted: bookmark resolution for a folder deleted and recreated at the same path; a Universal Clipboard or lazy-provider pasteboard read blocking the main thread; ShelfSharing returnTo lost when Quick Look and AirDrop interleave; the NFC/NFD and case-variant duplicate Shelf cards and duplicate lyrics folders via a symlink.
