# Exhaustion round 2: gap hunt and completeness critic

Produced 2026-10-11. Six Sonnet hunters attacked the gaps round 1 left (pasteboard privacy and permission timing on macOS 26 and 27, the lyric editor and library, intents and media keys, upgrade compatibility and network etiquette, thinly covered features, and a live-validation script for the owner) and produced 302 scenarios; an Opus critic deduplicated against the 720 ledger rows, verified every high and medium suspected defect in code, refuted 16 claims, and promoted 27 findings (1 P1, 12 P2, 14 P3). New-finding rate fell from 40 to 27, and P1s from 3 to 1, but **the critic still does not sign complete**. Ledger additions: 205 scenarios, in `2026-10-11-scenario-ledger-round-2.json`.

## Verdict: complete = False

I deduplicated the six hunters' roughly 280 scenarios against the 720 ledger rows and F-, G- and H-findings. I read the code behind every high- and medium-risk suspected defect and about half the low ones, and checked the release tags in git.

**Verified and promoted:** 27 findings: one P1 that a live check could downgrade (J-001, pasteboard privacy), 12 P2 and 14 P3.

**Biggest refutation:** the whole legacy-migration cluster. `git tag --contains` shows no shipped build ever wrote lyrics-v5 overrides or lrc4 caches, so those scenarios touch only the owner's dev data. The one real 0.1.0 leftover is the lrc3 cache (J-016).

**Other rejections:**
- The hunter's nondeterministic-fallback claim fails because the scripts run on one serial queue.
- Several claims contradict recorded decisions: Music Only filtering, the foreign-session hold, and the opt-in LRCLIB contract.
- Several merge into existing findings: G-004, G-007, G-010, G-016, G-019 and F-023.

**Why I will not sign complete:**
- The new-finding rate has fallen from round 1 (40 findings, several P1) but has not dried up. Twelve new P2s came this round, mostly on the fallback route, in intents and in the lyric library.
- Several areas still have no scenarios: long-run soak, Translate engines 1 and 2, the Spotify account edges, non-en/ru locales and RTL, Focus and presentation suppression, output hot-plug, and the artwork pipeline.
- About forty unknowns can only be settled by the owner's live sessions.

## Findings (J-001 to J-027)

### J-001 Clipboard reads have no answer to macOS pasteboard privacy: the change is consumed before any read, a refused or prompted read loses the copy for good, and nothing tells the user
P1 · clipboard · verified by critic: yes · needs live check

- Evidence: ClipboardStore.swift:174-176 advances lastChangeCount before reading anything. :181 (data .islaInternal) and :185 (readObjects NSURL) run for every changed pasteboard, before wantsImages (:198) or recordsHistory (:214) are consulted. A nil string returns silently at :215-216. encodeImage treats nil bytes as 'not arrived yet' and retries 12 times at 0.5 s (:262-321). AppDelegate.swift:49-51 hot key reads .string with no cap and no feedback. No accessBehavior, detect* or denial handling exists anywhere in Sources, Scripts or checklist.md (grep). The only record is docs/research/technical-feasibility.md:69 ('not active by default as of macOS 26.4'), and this Mac runs 27.0.1. The Settings note 'Copies are not read or kept' (SettingsPane.swift:508-510) is false whenever Save Clipboard Screenshots keeps the poll alive.
- Scenario: macOS enforces Paste from Other Apps (Ask or Don't Allow) for Isla. With Clipboard History on (the default), the 0.5 s poll reads every copy in the background. Under Ask, an unexplained alert appears with the panel closed. The copy that raised it is never recorded, even after Allow, because its change count was already spent. Under Don't Allow, history and clipboard screenshots go silently empty, the timer keeps polling forever, and Settings and Copy Diagnostics show nothing.
- Fix direction: Gate every content read behind types/availableType (not gated). Spend the change count only after a successful read, or retry once after an access decision. On macOS 15.4+ read NSPasteboard.accessBehavior: when it is alwaysDeny, stop polling and show a Clipboard row with a link to Privacy & Security > Paste from Other Apps. Add the state to Diagnostics. Correct the 'not read' note.
- Verification: I verified the code facts line by line. The impact depends on whether 27.0.1 enforces the policy. It is P1 if live session S1 shows any alert or nil read; otherwise it is a latent P2 that a 27.x point update can turn on.

### J-002 Every ad-hoc-signed update forfeits Isla's TCC grants (Desktop, Documents, Downloads, Automation), contradicting 'the grant sticks'
P2 · privacy-consent · verified by critic: yes · needs live check

- Evidence: Scripts/bundle.sh:207 SIGN_IDENTITY defaults to '-'. checklist.md:614-616 records 0.2.0 as released ad-hoc. TCC keys an ad-hoc binary's grant to its designated requirement, which for ad-hoc code is its cdhash. That changes with every build. RecordingPickup.swift:21-24 and checklist.md:129-131 promise 'one prompt, once ... the grant sticks'.
- Scenario: A DMG user updates from one release to the next, or the owner reinstalls after every change (CLAUDE.md step 2-3). Desktop, Automation for Music and Spotify, and any Paste-from-Other-Apps Allow are asked again. The Automation prompt then arrives at launch on the routes in G-005 and J-003.
- Fix direction: Ship with Developer ID, which is already the release owner's input and also fixes the Gatekeeper helper block. Until then, state the re-prompt in the release notes and the checklist rather than 'the grant sticks'.
- Verification: Signing default and release record are verified in the repo. The TCC behaviour is standard macOS, but confirm it on 27.0.1 with `codesign -d -r-` and a reinstall (session S2).

### J-003 On the fallback route Isla sends Apple Events at launch with the panel closed, so the Automation prompt appears unprompted
P2 · privacy-consent · verified by critic: yes · needs live check

- Evidence: switchToScriptingFallback ends with refreshFromPlayers() (MediaController.swift:1790). refreshFromPlayers calls PlayerBridge.currentState (MediaController.swift:1831-1832), which runs an AppleScript against every running player (PlayerBridge.swift:104-121, 66-70). checklist.md:32-37 says macOS asks the first time the panel opens on Music, and that 'Nothing is requested at launch.' This is a different trigger from G-005, which is the Spotify track-id lookup on the helper route, so G-005's fix does not cover it.
- Scenario: A DMG user's helper is refused (the Gatekeeper case in project memory) and Music or Spotify is open at login. Isla falls back during launch and one or two Automation prompts appear over whatever the user is doing, with no panel to explain them.
- Fix direction: On the fallback, read state from the distributed notifications until the panel first opens: Music's playerInfo userInfo carries name, artist, album, total time and state, and Spotify's PlaybackStateChanged carries the same. Send the first Apple Event only after the panel opens on Music.
- Verification: The code path is certain. Whether TCC shows the prompt to a background accessory process is confirmed in session S3.

### J-004 On the fallback route a skip keeps the old song's clock under the new title, and with no 1 Hz correction the lyrics follow the wrong time
P2 · media-route · verified by critic: yes · needs live check

- Evidence: refreshFromPlayers rebuilds the track and calls adopt(state.position) with the default mayRewindAtOnce=false (MediaController.swift:1839-1849). It has no trackChanged branch like apply(). adopt() holds a playing rewind larger than seekThreshold until a second reading corroborates it (REWIND-HELD, :2025-2037). On this route refreshFromPlayers runs only on a player notification or on setActive (:521, :1786). Precision sync is off on the fallback (G-003), so nothing supplies the second reading.
- Scenario: Fallback route, panel open on Apple Music 2:00 into a song, lyrics on. The user presses Next. The new title shows with the clock still near 2:00, and the stage highlights lines two minutes ahead, until Music sends another notification (pause or the next track) or the panel is reopened. Spotify is rescued by its broadcast; Apple Music is not.
- Fix direction: In refreshFromPlayers, treat a changed state.key as a track change: adopt with mayRewindAtOnce: true and clear the rewind candidate, mirroring apply().
- Verification: Traced in code. The live step is in session S3.

### J-005 Play or Pause, Next and Previous act on the session Music Only hides when Isla shows nothing
P2 · intents · verified by critic: yes

- Evidence: PlayPauseIntent is described as 'Toggles playback of whatever Isla is showing' (IslaIntents.swift:179-186). It, NextTrackIntent and PreviousTrackIntent call the controller unconditionally (:188-206). With no track and the feed alive, dispatch sends feed.send(cmd, playerPID: displayedPlayerPID) with a nil pid (MediaController.swift:1004-1012). The helper then falls back to activePlayerPath(), which is whatever owns Now Playing: the film or browser that was filtered (helper.m:361-367). CurrentTrackIntent, by contrast, throws nothingPlaying (IslaIntents.swift:131).
- Scenario: Music Only is on and a paused YouTube tab owns Now Playing. The island says nothing is playing. A Stream Deck key or Shortcut runs Play or Pause, and the hidden video starts, while the intent reports success. Next skips a browser queue the user never saw. Pausing a playing filtered film is impossible, because clear() resets the intent to 'paused' on every empty snapshot (:1727), so each press sends play.
- Fix direction: When track is nil, throw IslaIntentError.nothingPlaying from all three transport intents. In dispatch, refuse the feed branch when displayedPlayerPID is nil instead of letting the helper pick the active player.
- Verification: I traced the intent, dispatch and helper paths.

### J-006 The system media-key fallback is effectively dead: Isla never asks for Accessibility, and every press after the first is swallowed
P2 · intents · verified by critic: yes · needs live check

- Evidence: The final dispatch branch is PlayerBridge.postMediaKey (MediaController.swift:1016-1017). It posts a CGEvent to cghidEventTap, and its own doc says it 'silently does nothing' without Accessibility (PlayerBridge.swift:204-222). There is no AXIsProcessTrusted call anywhere in Sources. togglePlayPause routes through PlaybackIntent.toggle (MediaController.swift:860-868), which sets inFlight. The only timeout lives in reconcile() (PlaybackIntent.swift:45-80), and reconcile runs only on feed or player reports. This route has neither (no feed, no activeApp), so the next toggle hits `guard inFlight == nil` (PlaybackIntent.swift:34-37) and sends nothing until the panel opens.
- Scenario: A DMG user on the fallback (helper refused), with Music and Spotify closed, has audio playing in a browser and presses a Play or Pause shortcut. Nothing happens because Isla is not in the Accessibility list and was never prompted. If they add it by hand, the first press works and every later press is coalesced and never sent. Every run reports success.
- Fix direction: Either drop the media-key branch and make the intents throw a visible 'Isla cannot reach a player' error, or bypass PlaybackIntent for the key route (a key is a true toggle) and offer the Accessibility request from a user action, with a Settings row explaining it.
- Verification: The swallowed second press is certain from code. Whether a posted key reaches Now Playing on 27 is checked live in session S4.

### J-007 Under Music Only, a filtered source that is playing leaves the Music tab saying 'Nothing is playing.', with no pointer to the switch
P2 · media-route · verified by critic: yes

- Evidence: emptyState prints 'Nothing is playing.' and adds a line only when fallbackReason is set (MediaPane.swift:594-611). MediaController already publishes otherMediaIsPlaying (MediaController.swift:1114, 1152), but only NotchViewModel reads it, to fold the pill (NotchViewModel.swift:361, 549). The helper emits isMusicApp (helper.m:271-272), and nothing in IslaKit decodes it.
- Scenario: YouTube Music, SoundCloud or Bandcamp in a browser, or an mp3 in IINA or VLC, is audibly playing. The user opens the island, which says nothing is playing. Settings > Music Only is the cure, and nothing mentions it.
- Fix direction: When otherMediaIsPlaying is true, say 'Something is playing that Music Only hides' and offer a button that opens Settings at Music Only. Consider using isMusicApp as an admission signal for unlisted apps.
- Verification: Filtering itself is the recorded design and is not challenged. Only the false status copy is promoted.

### J-008 A panel opened with Control-Option-Command-I on the last tab flips to Music as soon as the pointer reaches it
P2 · keyboard-pointer · verified by critic: yes · needs live check

- Evidence: toggle() opens without selecting a tab, so the panel opens on the last tab. It pins and calls pointer.setInside(true) (NotchController.swift:682-688). With the pointer elsewhere, the watcher drops isInside after closeDelay, and the pin turns that into .standsAsItIs (NotchViewModel.swift:172). The later arrival is a false-to-true crossing, which runs pointerArrived(), and that calls select(.media) unconditionally (NotchViewModel.swift:124-127). OpenOnClickTests.swift:100 asserts 'arriving always lands on Music', but only for a pinned panel already on Music.
- Scenario: The user presses Control-Option-Command-I, sees the Clipboard or Settings tab they left, and reaches for a row with the mouse. The pane swaps to Music under the pointer.
- Fix direction: On an already-open panel, have the arrival only drop the pin. Keep select(.media) for arrivals that open a collapsed panel. Amend the test deliberately, since the owner set 'arriving lands on Music'.
- Verification: Traced in code. A one-minute live confirmation is in session S5.

### J-009 Edit Lyrics' Save Copy binds the edited lyrics to the track playing at save time, not the one being edited
P2 · lyric-library · verified by critic: yes · needs live check

- Evidence: The sheet's content closure passes binding: currentLocalTrackIdentity() (MediaPane.swift:117-125). That closure re-evaluates whenever MediaPane's body does, which includes every track change. LocalLyricsEditorView's init keeps the @StateObject draft but stores the new binding (LocalLyricsEditorView.swift:16-27), and save() binds with it (:148-151). Nothing in the sheet names the song.
- Scenario: The user opens the editor on song A, edits for a while, and the playlist advances to song B. Save Copy writes A's edited lyrics as a new import bound to B. Song B now shows A's words. Song A loses nothing, but B is silently wrong until bindings are cleared.
- Fix direction: Capture the identity when editing starts (store it in editingCandidate) and show the song's title in the sheet header.
- Verification: SwiftUI re-evaluating presented sheet content with its parent is standard behaviour. Confirm live in session S6.

### J-010 Word-timed LRC with an [offset] tag shifts lines but not words, so karaoke runs offset-late, and a negative offset makes Save Copy and Export fail
P2 · lyrics-clock · verified by critic: yes

- Evidence: parse() subtracts the offset from line stamps only (LocalLyricsDocument.swift:98-102). Words keep their raw stamps (parseWords, :167-188). serialize() adds the offset to both (:117, :122). The draft re-parses its own serialization (LocalLyricsEditor.swift:32), and the word check `timestamp >= lineStart` (:178) throws when words are emitted before their line. LyricSweep compares the position against word.at.
- Scenario: An enhanced LRC carries [offset:+500]. The line lights on time and its word sweep starts 0.5 s late. Each Save Copy shifts the words another +0.5 s. With [offset:-300], Save Copy and Export show 'This LRC file is invalid.' for a file that imported fine.
- Fix direction: Subtract the offset from word stamps at parse time, and add a round-trip test with a positive and a negative offset on a word-timed file.
- Verification: Traced by hand through parse, serialize and the re-parse. Unit-testable.

### J-011 A watched lyrics folder that is renamed or moved is treated as unreachable for good, because a stale bookmark's resolved URL is thrown away
P2 · lyric-library · verified by critic: yes · needs live check

- Evidence: resolve() returns URL(fileURLWithPath: folder.path) whenever bookmarkDataIsStale is true, discarding the freshly resolved location (LocalLyricsLibrary.swift:558-570). StoredFolder is never refreshed. rescanFolders then keeps the old documents and records an unreadable issue (:236-250). After a relaunch those documents have no records, so their bindings return .invalid(.unreadable) (:301-304, G-004). ShelfStore keeps the resolved URL in the same situation (ShelfStore.swift:143-165).
- Scenario: The user renames ~/Music/Lyrics to ~/Music/LRC in Finder. Isla keeps probing the old path. After a relaunch, every song matched from that folder shows 'No lyrics for this track.' or no lyrics, and Settings still lists the old name.
- Fix direction: Use the resolved URL when stale, re-create the bookmark and path, and persist them.
- Verification: The code is certain. Whether a plain rename sets stale on 27 is checked live in session S6; a move does on every macOS I know of.

### J-012 Imported and edited lyrics are indexed by absolute path, and any import that cannot be read or parsed at launch is silently removed from the index
P2 · lyric-library · verified by critic: yes

- Evidence: StoredDocument.path is written as destination.path (LocalLyricsLibrary.swift:170-175). reloadImportedRecords keeps an import only if String(contentsOfFile: stored.path) and parse() both succeed, and otherwise `continue`s, then rewrites state.documents (:489-499). The next persist() drops it. The file stays in imports/, and its binding becomes .invalid(.unreadable). Folder documents are kept and flagged instead (:236-250).
- Scenario: The account is renamed, or Application Support is restored by Migration Assistant to a different user name. Or a later build's parser rejects a user-authored edit. Every import and every Save Copy edit disappears from the library, and its bound songs show 'No lyrics for this track.', with no message.
- Fix direction: Store import paths relative to importsDirectory (or rebuild them from the id). Keep unreadable imports in the index with an issue instead of dropping them.
- Verification: Verified in code. Unit-testable by copying the root folder to a new temp path. Wave A's 'Home folder renamed' row covers only the Shelf.

### J-013 The screenshot vault decides what it owns by file name, so it trims and clears the user's own macOS screenshots in ~/Pictures/Isla
P2 · shelf-integrity · verified by critic: yes

- Evidence: isOwnFile accepts any .png starting 'Screenshot' and any movie starting 'Screen Recording' (ScreenshotVault.swift:142-149). Those are exactly macOS's native capture names. trimToLimit trashes the oldest beyond 200 (:155-173), clear() trashes all of them (:207-215), and usage() counts them (:183-189). The class doc promises 'nothing already in it is touched' (:5-8). Separately, init creates ~/Pictures/Isla at every launch even with the feature off (:18-44, NotchStores.swift:46).
- Scenario: The user points Screenshot.app's save location at the folder Isla's 'Show Screenshots Folder' revealed, or drops their own captures there. The trim silently moves the oldest to the Trash once more than 200 accumulate, and Clear Screenshots Folder trashes every one of them.
- Fix direction: Mark the vault's own files, for example with an extended attribute or a manifest, and trim and clear only marked files. Create the folder lazily on first save.
- Verification: Verified. Files go to the Trash, which is reversible, so I rated it P2 rather than P1.

### J-014 Editing the text of one word-timed line turns off word karaoke for the whole song
P3 · lyric-library · verified by critic: yes

- Evidence: LocalLyricsDraft.document() clears words on an edited line (LocalLyricsEditor.swift:19-28). Document granularity is `lines.allSatisfy { !$0.words.isEmpty }` (LocalLyricsDocument.swift:38-40), and the karaoke gate needs granularity == .word (LyricsPresentation.swift:85).
- Scenario: The user fixes a typo in one line of a fully word-timed file and saves a copy. Karaoke is gone for every line.
- Fix direction: Make granularity per line (sweep where words exist), or use a majority rule.
- Verification: Verified.

### J-015 The lyric editor cannot insert or reorder lines, retimes lines without their words, reports every validation failure as 'This LRC file is invalid.', and drops blank rows silently
P3 · lyric-library · verified by critic: yes · needs live check

- Evidence: Add Lyric Line appends at last.at + 1 (LocalLyricsEditorView.swift:77-80). There is no move or sort, and parse rejects out-of-order stamps (LocalLyricsDocument.swift:92). The Timestamp field edits only line.at (:56-61). save and export map every error to one string with no row (:148-169). Blank rows serialize as a bare stamp that parse drops as a gap (:160). Rows are ForEach(indices, id: \.self) with $draft.lines[index] bindings and an in-place remove (:55-69), the SwiftUI pattern known to trap on removing a focused row.
- Scenario: The user forgot a line, adds it and sets its time between two others. The save fails with a generic message and no row is named.
- Fix direction: Sort on save or offer insert-after. Name the offending row. Move words with their line. Key rows by a stable id.
- Verification: The code facts are verified. The row-removal trap is checked live in session S6.

### J-016 0.1.0 upgraders keep every LRCLIB lyric cache (*.lrc3.json) forever: the migration deletes only lrc4/lrc5
P3 · lyric-library · verified by critic: yes

- Evidence: v0.1.0 cached LRCLIB answers as <key>.lrc3.json in Application Support/Isla/lyrics (git v0.1.0 LyricsStore.swift:90, :555). The current migration enumerates that same directory as v4Directory (LocalLyricsLibrary.swift:156) but removes only .lrc5.json and .lrc4.json (:539-544). No code mentions lrc3 (grep).
- Scenario: A user who ran 0.1.0 upgrades. Third-party lyric text stays on disk indefinitely, against the migration's stated intent that every cache entry from retired lyric sources is removed (:384-388).
- Fix direction: Include .lrc3.json in removeLegacyCacheEntries, guarded so it never touches a user .lrc.
- Verification: Checked against the v0.1.0 tag.

### J-017 The translate hot key loads an uncapped clipboard string into the Translate editor on the main thread
P3 · keyboard-pointer · verified by critic: yes · needs live check

- Evidence: AppDelegate.swift:49-51 reads NSPasteboard.general.string with no size limit. ClipboardStore caps history at 256 KiB (ClipboardStore.swift:256-261), but this path does not. NotchController.translate only trims (NotchController.swift:553-557) and sets translator.input, which a SwiftUI TextEditor renders and the pane measures on every body pass.
- Scenario: With a multi-megabyte log on the clipboard, an accidental Control-Option-Command-T stalls hover, hot keys and animations, then offers the whole text to the online engine (F-042).
- Fix direction: Cap the hot-key and Services input like history does, and say when it was cut.
- Verification: The missing cap is verified. The size of the stall is checked live in session S5.

### J-018 The hot keys work invisibly behind the first-run welcome: translated text is never shown, and the lyrics page appears only after Get Started
P3 · first-run · verified by critic: yes

- Evidence: The welcome replaces the pane while isShowingWelcome is true (NotchContentView.swift:844-847). select() never clears it; only chooseTab and dismissWelcome do (NotchViewModel.swift:236-257). translate() raises wantsKeyboard with no field mounted and schedules a fold (NotchController.swift:541-574). toggleLyrics sets isShowingLyrics, which dismissWelcome's select(.media) does not reset (tab unchanged).
- Scenario: A new user tries the shortcut the welcome itself prints. Nothing visible happens, typing beeps, and the panel folds, or Get Started lands on a lyrics page they never opened.
- Fix direction: Have a commanded tab change from a hot key retire the welcome, the same as chooseTab.
- Verification: Verified. The window is narrow (first launch only).

### J-019 A known update disappears when a later re-check fails or is merely in flight
P3 · settings · verified by critic: yes

- Evidence: check() sets state = .checking first and assigns the outcome unconditionally, so .failed replaces .available (UpdateCheck.swift:59-78). hasUpdate is true only for .available (:153-156), so the rail dot and the Download row vanish. Any non-200 response, including a 403 rate limit, reads 'Could not reach GitHub'.
- Scenario: The daily automatic check finds 0.3 on Monday and fails offline on Tuesday. The notice is gone until a later successful check.
- Fix direction: Keep the last .available while checking, and on failure unless a newer answer arrives. Tell a rate-limit response apart from a network failure.
- Verification: Verified.

### J-020 Open on Hover opens the panel under a button-held drag, such as a window dragged by its title bar
P3 · keyboard-pointer · verified by critic: yes

- Evidence: PointerWatcher.tick samples only NSEvent.mouseLocation (PointerWatcher.swift:201-205). No pressedMouseButtons check exists in Sources (grep). isDragging() covers file drags and menus only (NotchController.swift:948-950). The default openDelay is 0.05 s.
- Scenario: Open on Hover is on. The user drags a window to the top edge to tile it, or drags a selection through the notch, and the panel opens over the drag.
- Fix direction: Treat NSEvent.pressedMouseButtons != 0 as 'not hovering' for the open decision.
- Verification: Verified. Open on Hover is off by default.

### J-021 TCC usage strings do not match their callers, and the capture-folder list always adds the Desktop and never prunes
P3 · privacy-consent · verified by critic: yes

- Evidence: The Documents and Downloads strings mention only the Shelf (Scripts/bundle.sh:89-92, Resources/*/InfoPlist.strings). The launch scan of a watched lyrics folder under those folders raises the same prompts (LocalLyricsLibrary.swift:159). No NSRemovableVolumes, NSNetworkVolumes or NSFileProviderDomain usage strings are declared. captureFolders appends the Desktop unconditionally and writes back an ever-growing list (RecordingPickup.swift:205-218), which is rescanned on every Shelf open.
- Scenario: A Documents prompt says 'files you put on the Shelf' at launch, with no Shelf in sight. A user whose screenshots go to ~/Pictures still gets the Desktop prompt. A retired USB or SMB capture folder is probed forever.
- Fix direction: Word the strings for every caller, add the volume usage keys, add the Desktop only when it is the configured location, and drop folders that no longer exist.
- Verification: Verified the plist and the code.

### J-022 Shelf selection keeps cards trimmed past the cap, and Command-click never sets the Shift anchor
P3 · shelf-integrity · verified by critic: yes

- Evidence: add() trims with items.removeLast without pruning selection (ShelfStore.swift:250-264). select() sets anchor only on a plain click (:327-348), so Command-click then Shift-click toggles one card instead of selecting a range, despite the 'matching Finder' doc.
- Scenario: The footer reads '3 selected' with two visible. Command-click A then Shift-click D selects only D.
- Fix direction: Intersect selection with items after a trim, and set the anchor on a Command-click.
- Verification: Verified.

### J-023 Recording a shortcut that another action owns silently unbinds that action, including 'Open the panel'
P3 · settings · verified by critic: yes

- Evidence: HotKeyCenter.setBinding clears any other action holding the same binding and stores 'none' (HotKeys.swift:249-255). SettingsPane notes only macOS-refused bindings.
- Scenario: The user gives Show Lyrics the open-panel keys. The keyboard route into the panel, which is also VoiceOver's route in, is gone with no notice.
- Fix direction: Say which action lost its shortcut, or refuse the duplicate with an explanation.
- Verification: Verified.

### J-024 Per-track timing nudges belong to the song, not to the lyric file, so binding or editing a better-timed file inherits the old correction
P3 · lyrics-clock · verified by critic: yes

- Evidence: Nudges are keyed by player, title, artist, album and duration (LyricsStore.swift:265-270, 254-262). importDocument, bind, removeBinding and the editor never touch LyricsStore.
- Scenario: The user nudges an LRCLIB file +0.5 s, then imports a correctly timed LRC or saves a retimed edit. The +0.5 s still applies, double-correcting.
- Fix direction: Key the nudge by document id as well as track, or reset it when the bound document changes.
- Verification: Verified.

### J-025 A saved edit duplicates its source's tags, so once the binding is gone the song turns ambiguous behind two identical choices
P3 · lyric-library · verified by critic: yes

- Evidence: Save Copy writes a new import with the same [ti]/[ar]/[al]/[length] (LocalLyricsLibrary.swift:168-183). Lookup returns .ambiguous for more than one match (:317-332), which shows the chooser, and candidateLabel uses only title, artist and album (LyricsStage.swift:611-617). Every Save Copy press adds another copy, and none can be removed singly.
- Scenario: After Clear Bindings, or when the song plays in another player, the user is asked to choose between two identical buttons.
- Fix direction: Mark copies as edits (label them 'Edited') and prefer the newest owned copy of the same source.
- Verification: Verified. The chooser is intended; the identical labels are the defect.

### J-026 Shortcuts and hot keys open a pinned panel on a sleeping display and restart the media clock
P3 · intents · verified by critic: yes

- Evidence: verdictForDeliberateOpen checks only isLockedPresentation (NotchViewModel.swift:496-498). toggle(), toggleLyrics() and translate() never consult screensAreAsleep (NotchController.swift:513-574, 666-695), while build() does (:1105). setOpen(true) calls media.setActive(true) (:1177).
- Scenario: A 'when AirPods connect, show lyrics' automation runs with the display asleep. The panel opens pinned, unseen, the 10 Hz clock and the 1 Hz Apple events run, and it is still pinned at wake.
- Fix direction: Refuse, or defer to wake, any commanded open while the screens are asleep.
- Verification: Verified.

### J-027 On the fallback, a Spotify denied Automation is indistinguishable from 'not playing', so a paused Music track is shown over a playing Spotify
P3 · media-route · verified by critic: yes · needs live check

- Evidence: state(of:) forwards only .loaded and maps .unknown (-1743) to nil (PlayerBridge.swift:66-77). currentState then picks results.first(where: isPlaying) ?? results.first (:104-121). The -1743 code is never surfaced.
- Scenario: Spotify plays, its Automation consent was refused, and Music sits paused. The island shows the paused Music song, and the transport controls drive Music.
- Fix direction: Carry .unknown through currentState, prefer no display over a stale paused player, and say in Settings that Spotify access is refused.
- Verification: Verified in code. The hunter's claim that the result order is nondeterministic is refuted, because the scripts run on one serial queue.

## Refuted

- The legacy migration cluster affects no shipped release, only the owner's pre-release dev data, so it is demoted to dev-only. This covers tagless overrides losing their binding, tag mismatches, [al]-less overrides, v4 nudge-key reconstruction, interrupted or failed migration, downgrade, a large v4 cache, a [length:1e30] crash loop at migration, an index-loss rerun duplicating overrides, and the invisible unassigned-imports and 'Dismiss <hash>' lists. writeLocalOverride first appears in 3ecdbb0, which no tag contains. v0.1.0 cached only *.lrc3.json with a global offset, and v0.2.0 already shipped the migration. The real 0.1.0 leftover is J-016.
- The claim that the fallback currentState flips between Music and Spotify nondeterministically is refuted. State scripts run on PlayerBridge's single serial queue in submission order, so results arrive in PlayerApp.allCases order and the pick is deterministic. Only the -1743 case survives, as J-027.
- Upgrading from 0.1.0 shows 'No lyrics' because Look Up Online defaults off. This is the approved design (LocalLyricsLibrary.swift:384-388, docs/releases/0.2.0.md), so it is a release-notes item, not a defect.
- Podcast episode titles reaching LRCLIB, and video titles with Music Only off, fall inside the opt-in contract: Settings states the lookup sends title, artist, album and length (SettingsPane.swift:335). It is already a round-1 ledger row.
- Translate result and Copy Line copies landing in clipboard history are the user's own deliberate copies, and recording copies is what history is for. The privacy covers are per pane by design.
- The translate hot key reading concealed copies was already refuted in round 1 (explicit request; owner decision 21).
- Clipboard copy-back of a text cut at 256 KiB duplicates ledger row 266.
- URLSession.shared regressing from 0.1.0's ephemeral session duplicates G-016 and adds only history.
- Two Isla builds clobbering index.json, offsets.json and cache.json is a consequence of F-023 and is merged there.
- A new Spotify client id invalidating stored tokens, legacy-import refresh-token rotation and the denied import hiding its row are merged into G-010: dead grants go undetected and sign-in failures are silent.
- The unreadable and malformed lyric-file issue list never being shown is merged into G-007, where those errors are discarded.
- A typed timestamp of 1e17 or more trapping formatTimestamp is merged into G-019. It is the same trap on a new route, and ordinary typing cannot reach it.
- A paused foreign session adopted after 10 s over a playing Spotify is deliberate behaviour, pinned by MediaControllerTests.testAPersistentForeignSessionIsEventuallyAdopted, because MediaRemote exposes only the active session.
- Music Only filtering browser music, web apps and IINA/VLC is the recorded, measured design (MediaSourcePolicy.swift:10-15). Only the false empty-state copy is promoted, as J-007.
- A bound folder file renamed or briefly unreadable getting a new UUID extends G-004 (dangling binding) and is merged there.
- Hot key and Set Lyric Delay failing on a cold start duplicates the Wave A 'intent while starting' row.

## Remaining gaps

- Live validation first. About forty unknowns, J-001's final severity and F-008, are decided only by the owner's sessions below. Round 3 should re-rate every needs_live_check finding from those results rather than hunt further in those areas.
- Long-run soak and resource growth has never been a hunter dimension. Round 3 should cover multi-day uptime, thousands of track changes, hundreds of lock and unlock cycles (F-026 creates listeners each time), repeated fallback and retry cycles, counts of timers, observers and CoreAudio listeners over time, artwork memory (F-044), and growth of cache.json, offsets.json and captures.folders.
- Translate engines 1 and 2 (Apple Translation sessions and the on-device Apple Intelligence model) have about one row. Round 3 needs language-pack install or uninstall mid-session, model availability flipping, refusal and over-long paths, cancellation under fast typing, engine fallback order and which error wins, plus the first-use download experience.
- The Spotify account cluster beyond G-010 and G-032 is thin. Round 3 needs the 403 development-mode refusal copy, the ISRC/catalogue call, token expiry crossing while the lock card is up, the heart for non-Spotify players, rate-limit (429 Retry-After) handling, and a reconnect after the app is revoked.
- System language beyond en and ru: which .lproj an Uzbek, Kazakh, German or Ukrainian system gets, number and date formats in Settings and the editor's timestamp field (the regional decimal comma), the Translate default target per locale (H-005), and RTL system languages mirroring the rail, wings and lock card.
- Focus, Do Not Disturb, presentation and full-screen suppression of peeks and ambient moments, including a peek over a full-screen film, Keynote play mode and screen sharing. No dimension has asked whether a peek should appear in these states.
- The lock-card output picker and live output tracking under hot-plug: a device removed while the picker is open, AirPods auto-switching mid-lock, virtual devices (BlackHole, Loopback) and devices without volume or mute control, beyond F-032, F-045 and G-023.
- Artwork pipeline edges: non-https or huge artwork, album-mate cover reuse at a skip, the once-per-track cover recovery, and cover loading on the fallback route versus the helper route.
- After this round's fixes, a short verification round should add unit tests for the code-level findings, which are unit-reproducible: J-010, J-012, J-013, J-014, J-019, J-022, J-024, and PlaybackIntent on the no-report route (J-006).
