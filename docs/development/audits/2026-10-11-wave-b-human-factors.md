# Wave B: human-factors review of the headless renders

Produced 2026-10-11. Eight Sonnet persona reviewers (first-time user, lyrics fan, VoiceOver user, low-vision user, Russian and CJK listener, keyboard-first screen-sharer, motion designer, Apple designer) looked at 634 headless renders, 21 sampled animation curves and the accessibility dumps from the visual lab; an Opus head of experience design verified, merged and scored. These are renders, not a live app: drawn glass stands in for native glass, keyframes are reconstructed from sampled curves, and hover states are not covered. "Needs live check" lists what only a running app can settle.

## Felt quality today (0 to 10)

| Surface | Score | Why |
|---|---|---|
| compact pill | 6 | Quiet and on-brand: one glyph and one value per state, and charger and headphones moments read well. At rest it is identical to the hardware notch, which is deliberate and offset by the first-run auto-open. But with nothing playing VoiceOver cannot reach it at all (H-001), the playing element's frame is the whole 700x84 window, and the peek can only use the left wing. |
| Music pane | 7 | The cleanest surface. Title, artist and caption hierarchy reads at a glance, the transport is large, and the empty state has real capsule actions. What lowers it: the caption smears for about 120 ms on every line turn (H-014), a new user sees the jargon 'No local lyrics.' on every song (H-008), and the scrubber is AXUnknown in the dump. |
| lyrics stage | 6 | The sung line is unmistakable and the ambience never competes, but only about 3 rows fit. Wrapped neighbours are guillotined at the clip, an instrumental break is a blank hole with an unlabelled selected row, the toolbar sits on the first row, and context lines stay at 0.28/0.34. The Increase Contrast render looks unchanged even though the code has a branch for it. |
| lock card | 5.5 | The top half is elegant: soft bloom, large transport, restrained chrome. Then F-003 washes out every secondary text over the lit corner (confirmed in clear-standard-lyrics__light-ir), lyric rows truncate to one line where the stage wraps two (H-019), miss states are jargon dead ends ('No local lyrics.', 'Lyrics are off.'), and with the output picker open the controls underneath stay in VoiceOver order (H-010). |
| Shelf | 5 | Cards and the selection ring are clear, but the empty state has no words, screenshot names truncate to about 5 characters so every one reads 'Scree…NN.png', the selection footer puts 'Clear' next to '2 selected' even though Clear empties the whole shelf, and cards are not accessibility elements. |
| Clipboard | 5.5 | Rows are legible across scripts, the history-off empty state is a good model, and concealed password copies are never recorded. Against that: the history-on empty state is a lone glyph, the copy confirmation is only a green tint on a 12 pt glyph (H-016), the last row is cut with no scroll cue, the cover is loud TV static that still leaks the count and the link glyph, and every row reads 'Copy Entry' to VoiceOver. |
| Translate | 5 | Big source type and a direct hot-key path make it quick, but the target defaults to Russian for everyone (H-005), the large output breaks Russian words mid-word (H-006), remedies are bare bold text rather than buttons (H-007), the cover leaves the output fully readable (F-002), and nothing on the keyboard copies the result after ⌃⌥⌘T (H-018). |
| Settings | 4.5 | Grouping is sound: inset cards, tracked caps headers, plain-language notes. But switches draw permanently in the inactive style (H-002), the 162 pt viewport ends on a clean card edge with no hint that about 600 pt more follows, so Quit (the only exit for this app) is effectively hidden (H-003), privacy covers are titled only 'Clipboard' and 'Translate' (H-004), and VoiceOver reads SF Symbol names such as 'Audiobook' before every row. |
| welcome pane | 5 | It auto-opens on first launch (AppDelegate:69), says the app is running and fits in both languages. But 'Click it to open' reads as an instruction already satisfied, the Music rail chip is lit over a pane that is not Music, none of the four features is named, and the translate hot key is left out. |
| ambient moments | 7 | Charger and headphones moments are compact, legible white-on-black, and well labelled for VoiceOver. They last a fixed 2.2 s with no hover pause, can resurface after a panel close (F-033), have no status role, are not announced (F-013), and long device names truncate at about 10 pt. |
| motion and transitions | 6.5 | Springs are critically damped and reversal merges with zero velocity jump on every spring, which is excellent. But close uses an ease-in fade that slices an opaque body (H-012), the pill fold is slower than the unfold (H-013), the caption turn smears (H-014), the two 'bump' springs show under a point of overshoot (decision 18), and the Reduce Motion path is a faster, non-interruptible bezier (F-055). |
| accessibility | 3 | Rail, transport and lyric rows are labelled well, but with nothing playing VoiceOver cannot reach the island (H-001). Clipboard rows and Shelf cards are unusable, scrubbers are AXUnknown with no value, decorative symbols are spoken, the rail and pane are interleaved, nothing is announced, the instrumental row is nameless, and the keyboard reaches only Translate. |

## New findings

### H-001 With nothing playing, the compact island is hidden from accessibility, so VoiceOver cannot find or open Isla
P1 · a11y-voiceover · verified: yes · reported by: VoiceOver user, First-time user

- Felt: A blind user lands on nothing. The one control that opens the app exists only while music, a peek or an ambient moment is up, and the welcome tells them to 'click it'.
- Evidence: NotchContentView.swift:572-583 sets .accessibilityHidden(!shown) on the only element that carries the open action; a11y/pill/idle-resting-in-notch__dark.txt, locked-nothing-playing and synthetic-notch-idle dumps contain only the bare 700x84 hosting view
- Fix direction: Keep an always-present AXButton 'Isla' sized to the real notch/pill frame, value describing the state, press action opening the panel; hide only the decorative wing content when folded.
- Verification: Read the modifier chain and three resting dumps.

### H-002 Settings switches always draw in AppKit's inactive style: on/off by knob side only, no accent, no Increase Contrast change
P1 · contrast-type · verified: yes · reported by: First-time user, Low-vision user, Keyboard/screen-share user, Apple designer

- Felt: Four personas could not confirm their privacy settings at a glance. That matters most on the privacy rows the screen-sharer checks before a call.
- Evidence: panel-settings/viewport-top__dark.png (Show Charging on vs Launch at Login off differ only by knob side and a slightly lighter track); viewport-top__increase-contrast; dump frames 36x16; visual-lab finding 9
- Fix direction: Draw an explicit on-state (accent or white-filled track) independent of key status, with an outlined track under Increase Contrast; pair with owner decision 2 (row-wide target).
- Verification: Viewed the render. Lab #9 recorded the cause; not in the backlog's F list.

### H-003 Settings shows a 162 pt window onto about 700+ pt of rows with no cue that more exists; Quit, the app's only exit, is the last row
P2 · discoverability · verified: yes · reported by: First-time user, Keyboard/screen-share user

- Felt: Settings looks like five switches. The Privacy and Application sections, and Quit, which the welcome promised, are never found by someone who does not think to scroll.
- Evidence: panel-settings/viewport-top__dark.png ends on a clean card edge after five rows; a11y dump scroll area 488x162 with content past y=700; Quit at SettingsPane.swift:602; WelcomePane comment notes an LSUIElement app is absent from Force Quit
- Fix direction: Bottom fade mask plus a flashed overlay scroller on first entry; move Privacy higher; consider a pinned Quit/About footer.
- Verification: Viewed the render and the dump frames. P2 because trackpad scrolling is habitual.

### H-004 Privacy cover switches are titled only 'Clipboard' and 'Translate' (ru 'Буфер', 'Перевод'), directly under 'Clipboard History', with no note
P2 · privacy-cover · verified: yes · reported by: First-time user, Russian/CJK user, Keyboard/screen-share user, VoiceOver user

- Felt: Users fear the switches turn features off, and the screen-sharer cannot tell what protects them. Three personas raised it independently.
- Evidence: SettingsPane.swift:511-517 uses privacySection.title for the toggle title with no noteRow; ru.lproj 'Clipboard' = 'Буфер'; panel-settings/all-sections-defaults__dark.png PRIVACY card
- Fix direction: 'Cover Clipboard Rows' / 'Cover Translate Text' with a one-line note, and a note under Hide from Screen Recording on what it hides.
- Verification: Read the Settings code. The backlog listed 'privacy switch titles' as unverified and unranked; now verified.

### H-005 Translate's target language defaults to Russian for every user regardless of system language
P2 · translate · verified: yes · reported by: First-time user

- Felt: An English, German or Uzbek user opens Translate and is offered Russian, a language they never chose.
- Evidence: Translator.swift:128 target = stored ?? .russian; alternative(to:) flips only between English and Russian (:231); a11y/panel-translate/empty__dark.txt 'Translate To' = Russian
- Fix direction: Default the target to appLanguage or the first preferred language that is supported, falling back to English when the source matches.
- Verification: Read the Translator init.

### H-006 Large Translate output breaks Russian words mid-word ('железнодорожна' / 'я станция?')
P2 · translate · verified: yes · reported by: First-time user, Low-vision user, Russian/CJK user, Keyboard/screen-share user, Apple designer

- Felt: The user's own language arrives looking torn, which reads as a rendering bug in a glance tool. Five personas flagged it.
- Evidence: panel-translate/result__dark.png, result__ru.png, result__increase-contrast.png
- Fix direction: Choose the size tier by the longest word as well as the total length, or allow minimumScaleFactor before a character-level break; add a long-Cyrillic-word fixture.
- Verification: Viewed the render.

### H-007 Translate remedies ('Turn On Translate Online', 'Retry', 'Translation Languages…') are bare bold caption text, not buttons
P2 · feedback-errors · verified: yes · reported by: First-time user, Apple designer, VoiceOver user

- Felt: The only way forward from the errors a newcomer hits first does not look clickable, unlike the 'Show Lyrics' and 'Open Spotify' capsules.
- Evidence: panel-translate/needs-online__dark.png, offline-error, missing-language-pack, apple-intelligence-off; visual-lab finding 7
- Fix direction: Use the shared capsule style. For Turn On Translate Online, say in the sentence that the text leaves the Mac.
- Verification: Viewed needs-online. Lab #7, not an F item.

### H-008 Lyric miss copy is jargon and inconsistent: with online off by default, a new user sees 'No local lyrics.' on nearly every song; four different miss strings; the caption and lock card offer no action
P2 · lyrics-clock · verified: yes · reported by: First-time user, Music lover, Russian/CJK user

- Felt: The headline feature greets every first song with internal vocabulary and a dead end, on the pane and on the lock screen.
- Evidence: LyricsPresentation.swift:18-36 maps .noLocalLyrics to 'No local lyrics.' (online off), 'No lyrics found.', invalid file to 'No lyrics for this track.', disabled to 'Lyrics are off.'; lock-card-states no-lyrics-found and lyrics-off tiles show dim status lines with no action; ru 'Текст песен выключен.' is ungrammatical (ru.lproj:178); visual-lab finding 11
- Fix direction: One vocabulary ('No lyrics for this song'), with an actionable 'Look Up Online' or 'Turn On' on the caption and lock card, or a one-time ask. Fix the ru string to 'Текст песни выключен.'
- Verification: Read LyricsPresentation and viewed the lock-card-states contact sheet.

### H-009 Decorative SF Symbols are exposed to VoiceOver with system names ('Audiobook', 'Flash', 'Click Cursor', 'Download Multiple', 'Paste'), and empty states consist only of them
P2 · a11y-voiceover · verified: yes · reported by: VoiceOver user

- Felt: Every Settings row doubles its stops and some names are wrong ('Audiobook' for headphones). Empty panes speak only a symbol name.
- Evidence: a11y/panel-settings/viewport-top__dark.txt: every row has an AXImage label before its toggle; a11y/panel-shelf/empty__dark.txt 'Download Multiple'; a11y/panel-clipboard/empty__dark.txt 'Paste'
- Fix direction: accessibilityHidden on row icons and decorative glyphs; give empty states a real localized sentence (with F-036).
- Verification: Read three dumps.

### H-010 With the lock card's output picker open, the scrubber, transport and volume underneath stay in VoiceOver order, interleaved with picker rows
P2 · a11y-voiceover · verified: yes · reported by: VoiceOver user, Low-vision user

- Felt: Picking an output by ear means wading through hidden controls.
- Evidence: a11y/lock-card/glass-standard-output__dark.txt: Playback Position sits between MacBook Pro Speakers and AirPods Pro; Previous Track between Studio Display and Living Room; plus two unlabelled 690x690 and 460x300 images
- Fix direction: Treat the picker as modal (accessibilityHidden on siblings while open, or an isModal container) and hide the cover-light and grain images.
- Verification: Read the dump.

### H-011 An instrumental break shows a blank stage row that VoiceOver exposes as a selected, unlabelled button
P2 · lyrics-clock · verified: yes · reported by: Music lover, VoiceOver user

- Felt: Sighted listeners wonder whether sync was lost during a solo, and VoiceOver users land on a nameless current line.
- Evidence: panel-lyrics-stage/instrumental-gap__dark.png; a11y/panel-lyrics-stage/instrumental-gap__dark.txt AXButton with help only, selected, 444x14; visual-lab finding 6
- Fix direction: Draw a breathing-dots or progress glyph on empty current rows and label them 'Instrumental'.
- Verification: Read the dump. The sighted half is lab #6.

### H-012 Panel close fades the body on an ease-in 0.12 s, so the clip slices still-opaque rail and text; close does not mirror the open choreography
P2 · motion · verified: yes · reported by: Motion designer, Apple designer

- Felt: Close feels like a blind dropping, and a different animation from the open.
- Evidence: Theme.swift:70 paneOut = .easeIn(duration: 0.12) vs paneIn easeOut 0.20 +40 ms; contact-sheets/keyframes-close.png t033-t050 show the time label and rail cut while bright; visual-lab finding 3
- Fix direction: pane-out as ease-out about 0.09 s, with the body under 40% opacity before the clip has moved 8 pt, or the shape delayed about 30 ms; scale 0.97 to mirror the open.
- Verification: Read Theme.swift and viewed the keyframe sheet. Keyframes are reconstructions, so live check the feel.

### H-013 Pill fold (0.50 s, settle 529 ms) is slower than unfold (0.42 s) and outlasts its content by about 300 ms
P2 · motion · verified: yes · reported by: Motion designer

- Felt: An empty black slab lingers wider than the notch after the content has gone. Leaving takes longer than arriving.
- Evidence: visual-lab README curve table: pill fold 0.50 s / 529 ms, unfold 0.42 s / 444 ms, content-out 0.22 s / 233 ms; keyframes-pill-fold t120-t300
- Fix direction: Fold response about 0.32 s and content-out about 0.16 s so both finish within about 100 ms of each other.
- Verification: From the metrics table. Not in the backlog or decisions.

### H-014 Music-pane caption line turn blurs old and new lines over each other for about 120 ms per line
P2 · motion · verified: yes · reported by: Music lover, Motion designer

- Felt: The one place lyrics are read without opening the stage stutters on every line.
- Evidence: contact-sheets/keyframes-caption-line-turn.png t083-t200 (smeared, overlapping); LyricLineTurn on lyricScroll 0.42 s (90% at 216 ms)
- Fix direction: Shorter turn (about 0.30 s) with blur capped at about 2 pt and the incoming line legible by about 120 ms; offset the outgoing line so the two never overprint.
- Verification: Viewed the keyframe sheet. Model-based.

### H-015 With cards selected, the Shelf footer reads '2 selected · Deselect · Clear', but Clear empties the whole shelf
P2 · shelf-integrity · verified: yes · reported by: Keyboard/screen-share user, First-time user

- Felt: A user expects Clear to act on the selection. Only the armed label 'Clear Everything' warns them, and it sits in the same spot as the second press.
- Evidence: ShelfPane.swift:93-110 ConfirmTextButton Clear -> shelf.clear() shown beside the selection count; panel-shelf/two-selected__dark.png; Clear hit frame 27x13 in the dump
- Fix direction: With a selection, offer 'Remove 2' scoped to it and move Clear All elsewhere; give Delete a key on selected cards.
- Verification: Read the footer code and viewed the render.

### H-016 Clipboard copy confirmation is only a green tint on the row's 12 pt kind glyph
P2 · feedback-errors · verified: yes · reported by: Low-vision user, Keyboard/screen-share user

- Felt: In sunlight, or for a colour-blind user, nothing changes, so the copy is uncertain.
- Evidence: panel-clipboard/row-just-copied__dark.png vs populated__dark.png (only the first row glyph turns green)
- Fix direction: Swap the glyph to a checkmark for about 1.2 s, optionally with a 'Copied' word, and announce it (F-013).
- Verification: Viewed both renders.

### H-017 Lists clip their last row hard with no edge fade or scroll cue (Clipboard 5 of 6 rows, Shelf at the cap, stage neighbours)
P2 · layout · verified: yes · reported by: Low-vision user, Apple designer, Music lover

- Felt: Content looks cropped rather than scrollable, and the header count disagrees with what is visible.
- Evidence: panel-clipboard/populated__dark.png row 5 cut square against 'Clear'; panel-shelf/at-the-60-cap__w480.png; panel-lyrics-stage/long-lines-wrapping__w480.png (lab #5)
- Fix direction: An 8-10 pt scroll-edge fade on every list, sized to the real clip.
- Verification: Viewed the clipboard and stage renders.

### H-018 After ⌃⌥⌘T there is no key that copies the translation; ⌘C copies the source
P2 · keyboard-shell · verified: yes · reported by: Keyboard/screen-share user

- Felt: The copy, hot key, read, copy loop breaks at the last step and forces the mouse.
- Evidence: NotchPanel.swift:103-115 routes ⌘C to the first responder (the source editor); no keyboardShortcut anywhere in panes except LocalLyricsEditorView; Copy is a 22x22 icon (a11y/panel-translate/privacy-covered-input__dark.txt)
- Fix direction: ⌘⇧C or ⌘Return copies the output (optionally closing), with the key hint shown on the button.
- Verification: Grepped keyboardShortcut and read editingAction.

### H-019 Lock card truncates every lyric row to one line, including the sung line, while the stage wraps two
P2 · lock-card · verified: yes · reported by: Music lover

- Felt: The lock screen knows less than the island, and the line being sung is the one cut.
- Evidence: lock-card-states/lyrics-long-lines__dark-ir.png ('…past the point wh…') vs panel-lyrics-stage/long-lines-wrapping__dark.png
- Fix direction: Let the current row wrap to two lines and shrink the window to three rows when it does.
- Verification: Viewed the render.

### H-020 Welcome pane: Music rail chip lit over a non-Music pane, 'Click it to open' reads as already satisfied, and the four features and the translate key are never named
P2 · onboarding · verified: yes · reported by: First-time user, Keyboard/screen-share user, VoiceOver user

- Felt: The first screen of an invisible app does not say what the app is for or how to come back after Get Started.
- Evidence: panel-welcome/first-run__dark.png; a11y dump shows Music selected; NotchContentView.swift:462-469 blanks the header because vm.tab is left on Music but the rail still highlights it; WelcomePane.swift lists only open and lyrics keys
- Fix direction: Select no tab while welcoming; one line per tab with its glyph; 'No Dock or menu-bar icon: click the notch or press ⌃⌥⌘I to come back'.
- Verification: Read WelcomePane and the header code, and viewed the render. The 'only reachable when already open' framing is wrong (it auto-opens) but the copy issue stands.

### H-021 Each Translate language picker is exposed as two AXMenuButtons (label and 7x4 chevron)
P3 · a11y-voiceover · verified: yes · reported by: VoiceOver user

- Felt: Every picker is heard twice, and one stop is a 7x4 pt target.
- Evidence: a11y/panel-translate/empty__dark.txt lines 4-8: 'Translate From' twice, 'Translate To' twice
- Fix direction: Combine label and chevron into one accessibility element.
- Verification: Read the dump.

### H-022 Refusal shake drives its sine phase through ease-out progress, so frequency halves over the shake and the first frame jumps about 9 pt
P3 · motion-reduce · verified: yes · reported by: Motion designer

- Felt: If F-018 is fixed and it plays, it reads as a rattle winding down rather than a head shake.
- Evidence: RefusalShake.swift:32 withAnimation(.easeOut(duration: 0.50)), :53 sin(progress * 2π * shakes); animation/refusal-shake-offset.csv 8.8 pt at 16 ms
- Fix direction: Fix together with F-018: keyframeAnimator with equal-spaced offsets, or linear phase with a separate decaying envelope ramped in over about 30 ms.
- Verification: Read RefusalShake.swift.

### H-023 Playback Position and Volume surface as AXUnknown with no value in the dump although the code declares value and adjustable action
P2 · a11y-voiceover · verified: no · reported by: VoiceOver user, Low-vision user

- Felt: If live VoiceOver matches the dump, position and volume can be neither heard nor adjusted.
- Evidence: MediaPane.swift:368-385 and LockScreenCard.swift:663-734 declare accessibilityValue/AdjustableAction; a11y/panel-music/playing-lyrics-caption__dark.txt shows [AXUnknown] label only
- Fix direction: Check live; if confirmed, use accessibilityRepresentation { Slider(...) } so AppKit vends AXSlider with value.
- Verification: Code and dump disagree; needs VoiceOver on a real panel.

### H-024 Settings slider values have no units ('560', '0') and section titles are plain static text, not headings
P3 · a11y-voiceover · verified: yes · reported by: VoiceOver user

- Felt: About 60 stops with no rotor landmarks, and numbers without meaning.
- Evidence: a11y/panel-settings/viewport-top__dark.txt AXSlider Panel Width value=560, Lyric Delay value=0; GENERAL/MUSIC/PRIVACY as AXStaticText
- Fix direction: accessibilityValue with units; .isHeader on section titles.
- Verification: Read the dump. Listed as unranked in the backlog; now verified.

### H-025 Shelf card names keep about 5 characters each side, so similar files are indistinguishable
P3 · shelf-integrity · verified: yes · reported by: First-time user, Apple designer

- Felt: Every screenshot reads as the same card.
- Evidence: panel-shelf/two-selected__dark.png 'Scree….44.png', 'Meeti…otes.txt'
- Fix direction: Two-line names, or truncate before the extension and keep the distinguishing tail; full name on hover.
- Verification: Viewed the render. Real previews (QuickLook) would partly help live.

### H-026 Clipboard privacy cover still shows the item count and per-row kind glyph (link vs text)
P3 · privacy-cover · verified: yes · reported by: Keyboard/screen-share user

- Felt: A screen-share audience learns how many items there are and that one is a URL.
- Evidence: panel-clipboard/privacy-covered__dark.png (header '6', link glyph on row 5)
- Fix direction: Neutral glyph and hidden count while covered.
- Verification: Viewed the render.

### H-027 Russian copy drift: 'пт' for points reads as Friday, 'Вывод' alone for Output, three names for the clipboard
P3 · localization · verified: yes · reported by: Russian/CJK user

- Felt: Small stumbles for the primary non-English audience.
- Evidence: ru.lproj:196 '%d pt' = '%d пт'; :181 'Output' = 'Вывод'; :7 'Clipboard' = 'Буфер' vs 'буфера обмена' elsewhere
- Fix direction: Keep 'pt' or drop the unit; 'Вывод звука'; a short ru glossary.
- Verification: Grepped the ru table.

### H-028 Panel close and tab swap use an ease-in exit that ends at peak speed; re-open mid-close restarts the fade from zero
P3 · motion · verified: yes · reported by: Motion designer

- Felt: Text is yanked out rather than released, and a reversal decouples text from shape.
- Evidence: metrics.json pane-out handOff; Theme.swift:70
- Fix direction: Covered by the H-012 fix (ease-out exit).
- Verification: Same root as H-012; kept separate only for the hand-off note.

## Known findings the personas make worse

- F-003: Confirmed in lock-card/clear-standard-lyrics__light-ir.png: context lyric lines and the artist dissolve over the lit corner. Low-vision arithmetic: Increase Contrast lifts card tokens only to about 2.4-2.6:1 over that backdrop, and the light renders also make the volume end caps and empty track fill (0.22) about 1.2-1.7:1.
- F-036 -> P2: Four personas. Both Shelf and Clipboard empty states are wordless, VoiceOver speaks only the SF Symbol names ('Download Multiple', 'Paste'), and the history-off state proves the right pattern exists one state away.
- F-030: Beyond the missing label and placeholder, the target defaults to Russian for everyone (H-005), and the AXTextArea reports disabled in the dump.
- F-002: The screen-share persona adds that the 'ENGLISH (DETECTED)' header stays visible over the dust, and the covered dump drops the source text area while exposing the full translation as static text.
- F-005: The covered and revealed dumps are byte-identical, so reveal state is invisible to assistive tech, and a copy changes only the selected trait.
- F-006: The Shelf dump shows ages interleaved across cards (one card's name sits beside another's age) and the selection badge is a separate 13x13 image.
- F-055 -> P2: Motion numbers make it worse than rated: the Reduce Motion open is an ease-out 0.12 s that peaks around 2,500 pt/s (the spring peaks around 1,200), jumps 37 pt in the first frame, and as a bezier cannot merge on reversal (velocity kink of -14.4/s). The people who asked for calm get the fastest, least interruptible path.
- F-018: Even if it plays, the shake chirps (H-022). The keyframe reconstruction shows an 8.8 pt jump on the first frame.
- F-013: Raised by four personas across copy, armed confirmations, translate errors, lock-card track change and ambient moments. The armed confirmation also drops its hint without saying 'press again'.
- F-011: Visible in panel-music/playing-word-sweep-caption__dark.png. The music lover notices it most because line changes are on time.
- F-009: The ru render shows the generic 'Для этого трека нет текста.' although 'Этот LRC-файл недействителен.' exists in the table.
- F-014: Dump frames: Shelf Clear 27x13 and Deselect 13 pt tall, next to each other. The keyboard persona adds that a miss lands on the neighbour, and with a selection the neighbour is the destructive one (H-015).
- F-033: Low-vision persona: 2.2 s at about 10 pt bold with truncation ('Beats Studio Pr…') is not readable as status for someone who has to find the notch first.
- F-053: The selected output is marked by the accent circle and semibold weight only, with no checkmark, and the picker covers the title and transport row.
- F-007: Confirmed again in panel-music/live-stream-no-duration__dark.png ('Lyrics are off.').
- F-004: Felt cost for a keyboard-first user: an ⌃⌥⌘I open can be neither navigated nor dismissed from the keyboard outside Translate. This strengthens owner decision 1.

## Delights to protect

- Every spring is critically damped and reversal merges with zero velocity jump (open/close, compact, pill fold/unfold, content in/out): interrupting anything is seamless.
- Open choreography: the shape leads, pane-in waits 40 ms with a 0.97 scale; pill content arrives 70 ms late with blur 5→0 and scale 0.72→1.
- The sung lyric line is unmistakable: bold white over a calm blurred ambience; the unlit remainder of a sweeping line stays brighter than the context lines; the soft one-glyph sweep edge reads as music.
- Lock card's large shadowed transport, soft bloom and hairline stroke; Increase Contrast adds a real outline and Reduce Transparency a solid popover.
- Music empty state with one-tap 'Open Apple Music' / 'Open Spotify' capsules, and the stage's one-sentence-plus-one-capsule empty states with the privacy note beside 'Look Up Online'.
- 'Clipboard history is off in Settings.' as the model empty state: glyph plus a plain sentence.
- Concealed password-manager pasteboard types are never recorded; Hide from Screen Recording is on by default.
- Hot keys matched by physical key code (Cyrillic layouts work), Escape yields to IME composition, the recorder demands two modifiers and explains Delete/Escape in its hint.
- Increase Contrast changes shape, not only tone: white ring on the selected rail chip, check disc and border on selected Shelf cards, fills 0.16→0.28, tertiary text 4.6→8.6:1.
- Armed confirmations rename themselves ('Clear Everything', 'Quit Isla', 'Очистить всё') and the Quit row swaps to a warning triangle.
- First launch auto-opens the welcome so an invisible accessory app is visible exactly once, and the keycaps show the live bindings.
- Accessibility labels that read as sentences and follow state: 'Playing: title, artist', 'Charging, 82 percent', Play/Pause by state, heart Add/Remove from Liked Songs, lyric rows as 'Jumps the song to this line' with the current one selected, all localized.
- Inset-grouped Settings cards with tracked uppercase headers and plain-language privacy footnotes ('Lyrics stay on this Mac.').
- Russian copy that fits everywhere at 560 pt with correct typography ('82 %', spaced em dash) and language-first error sentences; en/ru key parity.
- CJK titles and lyric lines render at the same size and weight with no tofu; mixed-script clipboard rows share one baseline.

## Refuted

- Caret '^' for Control in keycaps (four personas): the AX value is ⌃ (U+2303), whose glyph in the system font is an up-arrowhead that looks like a caret. This is the macOS convention, not a substitute character.
- Peek title squeezed into a ~100 pt stub with empty black to its right (Russian user): the middle of the pill is the physical camera housing; NotchContentView keeps the title on the left wing on purpose. Not a defect; a two-line peek is a separate idea.
- Settings icon column 'wobbles' 6 pt (Apple designer): dump frames put every symbol's centre at x≈148, so they already sit centred in a fixed cell; differing left edges are differing glyph widths.
- Armed Quit row is a hue-only cue (keyboard user, Apple designer): Confirmation.swift:118-123 swaps the icon to exclamationmark.triangle.fill and the label 'Quit' to 'Quit Isla'. Only the wording ('press again') remains a P3 nit.
- Shelf 'Deselect' stays English in ru (Russian user): Button("Deselect") and localized() both resolve through Bundle.main in the shipped app. This is most likely the lab's localization-swap gap; confirm live before filing.
- Welcome 'only reachable once the panel is already open' (first-time user): AppDelegate:69 auto-opens the welcome 0.8 s after first launch. The copy problem stands as H-020; the reachability framing does not.
- Resting pill pixel-identical to the notch as a P1 (first-time user): deliberate design, compensated by the first-run auto-open. Folded into H-020 rather than filed.
- Lyrics stage has 'no Increase Contrast branch at all' (low-vision user): LyricRow.swift:57-75 lifts the floor to 0.38 and the neighbour to 0.44 under Increase Contrast, and the lab sets SystemAppearance. That the renders look identical is unexplained and goes to live check, but the 'no branch' claim is false.
- Panel looks flat with no glass or layering (Apple designer): a known lab limit; every render uses the drawn recipe.
- Disabled AXScrollArea/AXTextArea everywhere (VoiceOver user, P1): consistent with the hosting window never being key in the lab; not shown to be what VoiceOver hits live. Kept only as a live check under F-004/decision 1.
- Lab #9-style 'blocky glow' on the stage ambience (Apple designer): the hosting render is fed a pre-blurred cover by the lab; blockiness is likely the upscaled stand-in, so needs a live look rather than a finding.

## Needs a live check

- Whether the lyrics stage's Increase Contrast lift (0.34→0.44 neighbour) is visible live; lab renders look identical to dark.
- Scrubber and volume: does VoiceOver hear a value and accept increment/decrement (code declares them; dump shows AXUnknown with no value) — H-023.
- Shelf 'Deselect' in a real Russian-system launch.
- Close and caption-turn feel (H-012, H-014): keyframes are reconstructions; screen-record the app.
- Whether the 162 pt Settings viewport shows any overlay scroller on entry in the live app (H-003).
- Pointer-lift on a playing pill: render identical to playing-equalizer; confirm the wing brightening is visible.
- Lock card: whether paused intentionally hides the lyrics view; how long the blank 'resolving' stage lasts between tracks.
- Disabled scroll areas and text area in the AX tree when the panel is actually key (VoiceOver focus into the panel).
- Stage ambience blockiness with a real cover through the live 60 pt blur.
- Source label in the panel header on a Russian Mac (fixture shows 'Music'/'Radio'; should come from NSRunningApplication.localizedName).
- F-008 capture exclusion and whether the peek is visible to a screen-share audience.
