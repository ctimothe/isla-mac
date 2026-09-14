# Contributing local lyrics

Isla is offline-only. It never downloads, uploads, or shares lyric text.

Import an `.lrc` file from the Music panel, or add a folder in Settings. Isla
copies explicit imports into its support folder; selected folders remain yours
and are only read locally. A match is automatic only when one file matches the
current title, artist, album, and duration without ambiguity. Choose a file
yourself for alternate cuts, live versions, remasters, and covers.

Supported metadata tags are `[ti:]`, `[ar:]`, `[al:]`, `[ve:]`, `[length:]`,
and `[offset:]`. Ordinary lines use `[mm:ss.xx]text`. Enhanced word timing uses
word markers after a line timestamp:

```lrc
[00:00.00]<00:00.00>One <00:00.50>two
```

Word markers must be ordered and cannot precede their line. Enhanced timing
animates word by word only when the active player has a measured precision
clock; otherwise Isla highlights the current line. Use the editor to make an
Isla-owned copy, correct timing, and export it. Keep shared fixtures limited to
original non-copyrighted sample text.

Validate before import or contribution:

```bash
bash Scripts/validate-lrc.sh /absolute/path/song.lrc
```
