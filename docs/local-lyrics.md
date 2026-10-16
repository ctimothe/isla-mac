# Your own lyrics files

Isla shows time-synced lyrics from `.lrc` files on your Mac. It can also look
lyrics up on [LRCLIB](https://lrclib.net), but only if you turn on **Settings →
Music → Look Up Lyrics Online**. A local file always wins over an online match.

## Adding files

- **For the song playing now:** open the lyrics page and click the document
  icon (Import Local LRC). The file is tied to that song, so it works even
  without tags.
- **One file for later:** **Settings → Music → Import LRC…**. Isla keeps its
  own copy.
- **A folder:** **Settings → Music → Add Lyrics Folder…**. Isla reads the folder
  and its subfolders where they are and never changes them. If a new file in a
  subfolder doesn't show up, use **Rescan Local Lyrics** in the same place.

To be found by itself, a file needs `[ti:]`, `[ar:]` and `[length:]` tags, and
the length has to be within two seconds of the song. `[al:]` helps pick between
versions. For live versions, remasters and covers, import the file from the
lyrics page while the song plays.

To fix timing, click the pencil (Edit Lyrics) on the lyrics page while a local
file is showing. Your edits go into a copy that belongs to Isla, and **Export
LRC** saves it wherever you like.

## The format

A line is a timestamp and its text:

```lrc
[00:12.40]First line
[00:15.10]Second line
```

These tags are read: `[ti:]` title, `[ar:]` artist, `[al:]` album, `[length:]`,
`[offset:]` and `[ve:]`. Other tags are ignored, not rejected.

Word timing goes after the line's timestamp:

```lrc
[00:00.00]<00:00.00>One <00:00.50>two
```

Word times must go up, and none can come before its line. Words sweep one by one
only when the player reports its position precisely enough; otherwise Isla
highlights the whole line.

## Checking a file

```bash
bash Scripts/validate-lrc.sh /absolute/path/song.lrc
```

If you add a test fixture to this repository, use text you wrote yourself, not
real song lyrics.
