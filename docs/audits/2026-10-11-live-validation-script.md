# Live validation script for the owner

Everything the headless work could not settle, as short sessions to run on a physical notched MacBook, in order. Produced 2026-10-11 by the round 2 hunters and consolidated by the completeness critic. Each session names the findings it settles and the pass criterion. Nothing here was run: the machine is shared with other autonomous sessions and no synthetic input was allowed.

## 1. S1 Pasteboard privacy on macOS 27.0.1 (do this first) (12 min)

1. System Settings > Privacy & Security > Paste from Other Apps: note whether Isla is listed and its value. 2. In Terminal, run `defaults read -g EnablePasteboardPrivacyDeveloperPreview; defaults read com.ctimothe.isla EnablePasteboardPrivacyDeveloperPreview`. The key name comes from a third-party source and is unverified. 3. Copy 'PB-TEST-1' in TextEdit, then click the island > Clipboard: is the row there within 1 s, and did any alert appear? 4. Copy a Finder file and a Safari URL. 5. Turn Save Clipboard Screenshots on, press Cmd-Ctrl-Shift-4 and check that a Shelf card arrives. 6. If Isla is listed, set it to Ask. Copy text, leave the alert unanswered for 20 s while hovering the pill and pressing Ctrl-Opt-Cmd-I, then click Allow and check whether that copy is recorded. 7. Set it to Don't Allow. Copy text 3 times and check the Clipboard tab for a row or a message. Take a screenshot to the clipboard and count alerts in Console. Press Ctrl-Opt-Cmd-T. Try Cmd-V and right-click > Paste in the Translate field. Run TextEdit > Services > Translate in Isla. Drag a Finder file onto the island. 8. In Ask mode with History off and screenshots on, copy plain text: does an alert appear? 9. Restore Allow.

- Settles: J-001, ledger: macOS 27 pasteboard privacy (2 rows), F-040, F-050
- Pass: With Allow, or with no enforcement, every copy is recorded within 1 s and no alert appears. Under Ask or Deny, Isla never freezes, the allowed copy is recorded, the empty list explains itself, and Services and drag still work.

## 2. S2 TCC prompt timing and ad-hoc grant persistence (12 min)

1. Add a lyrics folder under ~/Documents in Settings first. 2. Run `tccutil reset AppleEvents com.ctimothe.isla; tccutil reset SystemPolicyDesktopFolder com.ctimothe.isla; tccutil reset SystemPolicyDocumentsFolder com.ctimothe.isla; tccutil reset SystemPolicyDownloadsFolder com.ctimothe.isla`. 3. Settings > Quit Isla (press twice). Start Spotify playing; Show Lyrics off; Spotify not connected. 4. Launch Isla from Spotlight and keep hands off for 60 s. Note every prompt, its text and its time since launch. Leave one unanswered for 30 s and press Ctrl-Opt-Cmd-I: does the panel come up? 5. Click the island and note when the Automation prompt appears. 6. Open the Shelf tab. While the Desktop prompt is up, move the pointer away for 2 s: does the panel fold? Answer Allow to everything. 7. Run `codesign -d -r- /Applications/Isla.app` and note whether the requirement is a cdhash. 8. Run `bash Scripts/bundle.sh release && bash Scripts/install.sh`, relaunch, and list which prompts return.

- Settles: G-005, J-002, J-021, F-022, checklist: Protected Shelf files prompt only when the Shelf is opened
- Pass: No prompt appears at launch with the panel closed, each prompt's text matches its trigger, the panel does not fold under a dialog, and grants survive a reinstall (expected to fail while builds are ad-hoc).

## 3. S3 Helper restart, fallback route and its consequences (12 min)

1. Spotify playing, panel open on Music. Run `pkill -f libislamedia`, click Pause within 2 s, and repeat 3 times. Count real pauses and any icon flip-backs. 2. Run `tccutil reset AppleEvents com.ctimothe.isla`. Close the panel, then kill the helper 3 times, each right after it returns (`pgrep -fl libislamedia`), to trip the fallback. Does an Automation prompt appear with no panel open? Allow it. 3. Settings > Music: route status and Try Again. Music tab: are shuffle and repeat present? Lock the Mac: is the heart present? 4. Switch to Apple Music, play a song from 2:00 with Show Lyrics on and the panel open, and press Next. Watch the elapsed label and the lit lyric for 20 s. 5. In System Settings > Automation, turn off Spotify for Isla. With Music paused and Spotify playing, which song does the island show? 6. Press Try Again and confirm the controls come back.

- Settles: G-040, J-003, G-003, G-009, J-004, J-027
- Pass: Taps during a restart reach Spotify. The fallback raises no prompt with the panel closed and keeps shuffle, repeat and heart (expected to fail per G-003). A skip shows 0:00 and the first lyric line of the new song at once. A denied Spotify is never replaced by a paused Music track.

## 4. S4 Intents, media keys and Music Only (10 min)

1. Shortcuts.app: search Isla and count the actions (8). Spotlight: 'Show lyrics in Isla'. 2. With Music Only on and Music and Spotify quit, pause a YouTube video in Safari, open the island and read the Music tab. Run Play or Pause from Shortcuts: does the video start? Run Next. 3. With the panel open and pinned, run Show Isla twice. With the panel closed and a synced track playing, run Get Current Lyric 3 times 5 s apart and compare with Spotify's lyrics view. Ask Siri 'What is playing in Isla' and note what is spoken. 4. On the fallback from S3 with Music and Spotify quit and Chrome playing, run Play or Pause twice a minute apart. Check Privacy & Security > Accessibility for Isla. 5. Quit Isla, run Set Lyric Delay -0.4, then `defaults read com.ctimothe.isla lyrics.userOffset`.

- Settles: J-005, J-006, J-007, F-024, G-024, checklist: verbs visible in Shortcuts and Spotlight
- Pass: Transport intents never touch a session the island hides, and they fail visibly when nothing is shown. The empty tab says when something hidden is playing. Show Isla never hides an open panel. Get Current Lyric matches the sung line. Set Lyric Delay persists on a cold start.

## 5. S5 Keyboard, pointer and Translate editing (12 min)

1. Leave the panel on the Clipboard tab and close it. Press Ctrl-Opt-Cmd-I, wait 1 s with the pointer elsewhere, then move onto the panel: does it flip to Music? 2. Reopen with the hot key, press Escape, then Cmd-Tab to Finder: does it close? 3. Translate: with Caps Lock on, try Cmd-A and Cmd-V. With a German layout, Cmd-Z. With Japanese, start composing and press Escape. 4. Copy an image and press Ctrl-Opt-Cmd-T. Run `yes 'lorem ipsum dolor' | head -c 5000000 | pbcopy`, press Ctrl-Opt-Cmd-T, and check whether hover still responds within 1 s. 5. Turn the Translate cover on and type. 6. Drag the Panel Width knob 300 pt right and 150 pt down, hold 2 s and release; do the same with the scrubber. 7. Turn Open on Hover on (delay 0.05), drag a Safari window by its title bar across the notch, then move in and out 5 times. Turn Open on Hover off.

- Settles: J-008, F-004, G-006, F-039, F-040, J-017, F-021, F-028, J-020
- Pass: The tab stays put on arrival. Escape and Cmd-Tab close a hot-key panel. Editing keys work regardless of Caps Lock and layout. The island never stalls over 0.5 s. A drag never folds the panel or opens it unasked.

## 6. S6 Lyric editor and lyrics library (12 min)

1. Bind a folder .lrc to a 30 s track A followed by track B. Open the pencil, edit a line without saving, let A end, and press Save Copy on B: whose lyrics does B show now? 2. Edit again and press Ctrl-Opt-Cmd-T: are the sheet and the edits gone? 3. In the Title field type a character and press Return. 4. Focus the last row's lyric field and click its minus: does it crash or log? 5. Read the Cancel, Export and Save buttons in en and ru. Move the pointer below the panel for 3 s with the sheet open. 6. Press Import LRC on song A and pick the file after Spotify moves to B. 7. Quit, rename the watched folder in Finder, relaunch, and check the Settings row name and the lyrics of a song from that folder. 8. Remove a folder that holds a bound file.

- Settles: J-009, J-011, J-015, G-012, G-013, G-004
- Pass: Edits bind to the song they were made for. A draft is never lost without warning. Return in a field does not save. Deleting a row never crashes. A renamed folder keeps working. A removed binding falls back to matching.

## 7. S7 Capture exclusion (Hide from Screen Recording) (12 min)

1. Hide from Screen Recording on; copy SECRET-CAPTURE-TEST. 2. Make a QuickTime full-screen recording while opening the panel (Clipboard tab) and letting a track peek, then replay it frame by frame. 3. Press Cmd-Shift-3, Cmd-Shift-4 then Space on the panel, Cmd-Shift-5, and run `screencapture -x $TMPDIR/t.png`. 4. Share the entire screen and a single window in Zoom, Teams and Meet in Chrome, and watch from a phone. 5. During a recording open Quick Look, AirDrop and About Isla from the Shelf and Settings. 6. Toggle the switch off with the panel open and confirm Isla now appears in a capture.

- Settles: F-008, S2-d system windows (Quick Look/AirDrop/About), F-048
- Pass: No pixel of Isla appears in any capture or share with the switch on. The switch applies live. Leaks from system windows are either excluded or documented.

## 8. S8 Clean account: first run, DMG Gatekeeper, Launch at Login, single instance (15 min)

1. Create a Standard user 'isla-test' and fast-switch to it. 2. Download the latest DMG in Safari, copy Isla to ~/Applications, and launch it. Note any malware alert about libislamedia.dylib and the route status. 3. Time the welcome opening and read it. Click Get Started. Try to get Isla back with no hint. 4. Run once from the mounted DMG and turn Launch at Login on; watch the switch and Login Items. 5. With Isla running, open it again from Spotlight, run `pgrep -lf 'Isla.app/Contents/MacOS'`, and check for a doubled pill. 6. Quit from Settings.

- Settles: H-001, H-020, memory: Gatekeeper helper block, F-027, F-023
- Pass: The welcome appears within about 1 s and says how to come back. No malware alert on a Developer ID build. Launch at Login sticks or says why. Exactly one Isla runs.

## 9. S9 Russian system locale (10 min)

1. In isla-test set Russian as the primary language and log out and in. 2. Press Cmd-Shift-3 and `ls ~/Desktop`. Open the Shelf: is the card there? 3. Check Safari > Services for the Isla item and its language. 4. Check the Shelf footer 'Deselect', the Music header source name and the Translate default target. 5. Finally delete the isla-test user.

- Settles: G-001, G-031, H-005, Wave B: Deselect and source label on a Russian Mac
- Pass: A Russian-named screenshot reaches the Shelf, and every visible string is Russian.

## 10. S10 Lock screen (15 min)

1. With Spotify playing, run 5 lock and wake cycles (Ctrl-Cmd-Q), photographing the card each time, plus 2 cycles with display sleep. Look for a leftover card after unlock. 2. With nothing playing, lock and click the password field, the avatar and the screen centre. 3. Run `(sleep 15; printf LOCKED-COPY-TEST | pbcopy) &`, lock, unlock after 25 s, and check Clipboard. 4. While locked, press Ctrl-Opt-Cmd-I, L and T (shake, nothing opens). Click the pill 4 times 1 s apart and repeat with Reduce Motion on. 5. Use the card transport, volume, output picker (7+ devices via Audio MIDI aggregates, Yellow accent) and heart. 6. Play a near-white cover in Transparent, Tinted and Solid styles and read every label at arm's length; repeat with no artwork.

- Settles: checklist: lock card centred across cycles, F-026, G-011, F-018, H-022, F-032, F-053, G-023, F-003, F-012
- Pass: The card is centred every cycle and never stranded. No invisible window swallows login clicks. Copies made while locked are not recorded. Every click gives a visible refusal. Every label is readable over a pale cover.

## 11. S11 VoiceOver and Full Keyboard Access (15 min)

1. Quit all players and turn VoiceOver on (Cmd-F5). Can VO reach Isla at the notch? Start Spotify: is there a 'Playing:' button, and does VO-Space open the panel? 2. Close it with Escape, VoiceOver gestures, Cmd-Tab and the hot key. 3. Scrubber: is a value announced, and what does VO-Up move on a song and on a 1-hour podcast? Panel Width and Hover Delay with VO increments: do they change before you leave the control? Is the lock-card volume reachable? 4. Clipboard rows, Shelf cards and the Translate field: names and actions. 5. Hot keys with VO on: which wins? 6. Full Keyboard Access on: Tab through the panel; check rail tooltips.

- Settles: H-001, G-015, F-004, H-023, G-034, F-005, F-006, F-030, H-009, H-021, checklist.md:658 hot key collisions, round-1 gap: Slider onEditingChanged under VO
- Pass: Isla is reachable and closable without a mouse. Sliders commit under VO. Every row and card has a distinguishable name (expected to fail today).

## 12. S12 Displays, Spaces and full screen (12 min)

1. With the panel open, plug in an external monitor, make it main and switch back. Arrange it above the built-in display and test top-edge hover. 2. Close the lid (clamshell): synthetic pill, then open the lid again. 3. Plug and unplug while locked. 4. Safari full screen: is the pill visible and clickable? 5. Swipe Spaces with text typed in Translate. 6. Turn on Stage Manager and Mission Control. 7. Check that long Xcode menus are not covered by the left wing.

- Settles: checklist: synthetic notch on external display, F-047, checklist.md:649, checklist: above the menu bar on every Space
- Pass: The island is always on the notch display, never doubled or stranded. A synthetic pill appears in clamshell mode. Spaces fold the panel and keep the text. No menu item is covered.

## 13. S13 Shelf, Settings and screenshot vault (12 min)

1. Run `hdiutil create -size 20m -fs HFS+ -volname ISLATEST $TMPDIR/t.dmg && hdiutil attach $TMPDIR/t.dmg`, put a file from it on the Shelf, detach, reopen the Shelf, then reattach. 2. Drag a Desktop card into a Finder folder, then double-click the card. 3. Quick Look while typing in TextEdit, press Esc and keep typing. AirDrop with AirDrop off. 4. Cmd-click two cards, Clear: what is cleared? 5. Copy a native capture into the vault: `cp ~/Desktop/Screenshot*.png ~/Pictures/Isla/` (one file). In Settings press Clear Screenshots Folder twice and check the Trash. 6. Find Quit as a new user with a stopwatch, with scroll bars set to Always. Click a row label to toggle it.

- Settles: F-001, F-020, F-049, H-015, J-013, H-002, H-003, F-014
- Pass: Cards on an ejected volume survive, a moved file keeps its card, focus returns to TextEdit, Clear affects only the vault's own files, and Quit is found within 20 s.

## 14. S14 Motion, Reduce Motion and contrast, filmed (15 min)

1. With ProMotion on, film at 240 fps: open ×3, close ×3, a mid-animation reversal, the pause fold and the unfold. 2. Film a lyric caption line turn and the karaoke edge with Word Karaoke on. 3. Morph versus cut on play/pause and on the lock-card heart. 4. Turn Reduce Motion on live with the panel pinned, switch tabs, close and reopen, skip a track, then turn it off. 5. Turn Increase Contrast and Reduce Transparency on live on the stage and on the lock card. 6. Repeat step 1 once at 60 Hz.

- Settles: H-012, H-013, H-028, H-014, F-011, F-046, F-017, F-055, Wave B: Increase Contrast lift
- Pass: No opaque slicing on close. The fold ends within about 100 ms of its content. No legible overprint beyond 2 frames. The karaoke edge is within one word. Reduce Motion removes all travel live. The contrast settings apply without relaunch.

## 15. S15 Glass over wallpapers and stage ambience (10 min)

1. Turn Hide from Screen Recording off for this session. Over white, black, saturated and dynamic wallpapers, open Music, Clipboard and Settings and sample secondary text against its background with Digital Color Meter. 2. Compare with `defaults write com.ctimothe.isla drawnGlass -bool true`, relaunch, then `defaults delete com.ctimothe.isla drawnGlass`. 3. Leave the lyrics stage open for 5 min on a 3000 px cover and watch for blockiness, CPU, Energy Impact and memory over 10 skips. 4. Turn Hide from Screen Recording back on.

- Settles: Wave B: real glass not rendered, F-012, F-044, stage ambience blockiness
- Pass: Body text is at least 4.5:1 on every wallpaper, the glow shows no tile edges, and memory does not grow across skips.

## 16. S16 Lyric lead by ear, and ambient moments (15 min)

1. Play a track with a trusted onset LRC, Lyric Delay 0, stage open. Film at 240 fps with the audio for 20 s each on built-in speakers, wired headphones and AirPods (bud against the phone mic). Measure frame offsets between line light and onset, then find the Lyric Delay that centres AirPods. 2. Connect AirPods while plugging in power. Open the panel at 0.5 s and close it at 1.5 s. Flap the charger 5 times in 10 s. Sleep and wake with the charger in.

- Settles: lyrics-lab P1 0.20 s lead, G-033, F-033, F-013
- Pass: On built-in speakers the line lights within -125/+45 ms of onset, the AirPods correction is recorded, each moment shows once, and no moment resurfaces after a panel close.

## 17. S17 Performance by hand and clean exit (10 min)

1. Run `top -pid $(pgrep -x Isla) -stats cpu,idlew`. Record CPU and idle wake-ups for: panel closed and idle (5 min), music playing with the panel closed, the panel open on Shelf, on Clipboard, on Settings, and on the stage (1 min each). 2. Settings > Quit Isla (press twice). Run `pgrep -lf 'Isla|libislamedia'` and expect nothing. Spotlight 'Isla' should show exactly one app. 3. Relaunch from /Applications.

- Settles: F-015, F-016, F-054, checklist.md:210-212 CPU gate, memory: duplicate registrations
- Pass: Non-music tabs show near-zero CPU, wake-ups are recorded next to the checklist's 0.3 percent figure, no process survives Quit, and one registration exists.

