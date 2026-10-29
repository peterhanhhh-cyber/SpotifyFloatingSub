# SpotifyFloatingSub

Fancy floating subtitles for whatever Spotify is playing — a glassy,
always-on-top overlay that sits above your other windows, shows the synced
lyric line with a karaoke wipe, and never steals a click.

```
./run.sh
```

That's it. Close the overlay window (or Ctrl+C in the terminal) to stop it.

---

## What you get

- **Karaoke wipe** — the current line fills with the album's accent colour as
  the song plays, timed from the real playback position.
- **Album theming** — the dominant colour of the album art drives the lyric
  fill, the glow and the panel border. Cover art is shown alongside.
- **Next line preview** — the upcoming line sits underneath, dimmed.
- **See-through by default** — the panel draws no background at all, so only
  the cover art and the text float over your desktop. The text carries a soft
  shadow to stay readable on both light and dark windows behind it. Raise
  `panelAlpha` if you'd rather have tinted glass.
- **Transport, like Spotify's own bar** — hover the panel and the control
  cluster fades in: shuffle, previous, play/pause, next and repeat, with
  elapsed/total time either side of a progress bar. Repeat cycles off → all →
  one the same way the Spotify client does, and shuffle/repeat light up green
  when they're active.
- **Drag it anywhere** — hover the panel and the cursor turns into a move
  handle; drag it wherever you like. Move away and it goes back to being
  click-through, so it never gets in the way of what's underneath.
- **No account, no API keys, no installs.** Lyrics come from the free
  [LRCLIB](https://lrclib.net) database; playback comes from the Windows media
  session API. Everything needed is already on your machine.

## Requirements

- Windows 10/11 with the **Spotify desktop app** (the Microsoft Store build and
  the standalone one both work).
- WSL with Windows interop enabled (the default) — `run.sh` launches things on
  the Windows side.
- Windows PowerShell 5.1 — ships with Windows, nothing to install.

No Python, no Node, no pip, no npm.

## Moving it

Just hover over the panel — the pointer becomes a move handle and you can drag
it wherever you want. Move the pointer away and it's click-through again, so
clicks land on whatever is behind the overlay rather than on the overlay.

While you're hovering, the transport controls fade in on the right. They're
part of the same hover, so they're only clickable when the panel is, and a
click on a button is never mistaken for the start of a drag.

| Hotkey | Action |
| --- | --- |
| `Ctrl+Alt+L` | Pin the panel grabbable, or release it back to hover. Use it if you'd rather not have to hover first, or if you set `dragMode` to `hotkey`. |
| `Ctrl+Alt+K` | Fade the overlay out / back in. |

The position is saved when you finish dragging and on close, so it comes back
where you left it. It's also pinned inside the desktop, so a stray drag can't
park it off the edge of the screen.

Every transport button is a *request* to the media session, and the session is
free to refuse — `floatsub.log` records the answer (`transport next:
accepted=True`), so it's the place to look if a button does nothing.

## Commands

```bash
./run.sh              # start the overlay
./run.sh --selftest   # check playback detection + lyrics lookup, then exit
./run.sh --stop       # kill a running overlay
./run.sh --logs       # tail the app log
```

`--selftest` is the one to reach for if something looks wrong: it prints the
detected track, the artwork accent it sampled, the parsed lyric lines, and runs
the LRC parser/sync assertions. It needs no window.

## Configuration

Config lives at `%LOCALAPPDATA%\SpotifyFloatingSub\config.json` and is created
on first run. Edit it and restart. `left`/`top` are written automatically when
you move the window — set them to `null` to go back to centred-at-the-bottom.

| Key | Default | Meaning |
| --- | --- | --- |
| `width` / `height` | `940` / `180` | Panel size, in DPI-independent pixels. |
| `lyricFontSize` | `30` | Current line. |
| `nextFontSize` | `17` | Upcoming line. |
| `metaFontSize` | `13` | Title / artist line. |
| `bottomOffset` | `120` | Distance above the work-area bottom. |
| `panelAlpha` | `0.0` | Transparency of the glass panel, `0`–`1`. `0` (the default) draws no background at all — just text and art floating over your desktop, with a text shadow for legibility. Raise it towards `1` for a solid panel. Only the background fades — the text stays fully opaque. |
| `opacity` | `1.0` | Opacity of the whole overlay, text included. `Ctrl+Alt+K` toggles this. |
| `showAlbumArt` | `true` | Hide the cover thumbnail (keeps the theming). |
| `showControls` | `true` | Show the hover-revealed transport cluster and progress bar. |
| `dragMode` | `hover` | When the panel accepts the mouse: `hover` (while the pointer is over it), `always`, or `hotkey` (only via `Ctrl+Alt+L`). |
| `syncOffsetMs` | `0` | Nudge the lyrics in milliseconds. **Positive shows them later**, negative earlier — e.g. `250` if they run a quarter-second ahead. |
| `left` / `top` | `null` | Window position; `null` = bottom centre. |
| `pollMs` / `frameMs` | `400` / `33` | Playback poll / render cadence. |

## How it works

Spotify is running on Windows, and a floating overlay has to be a Windows
window — so the renderer runs on the Windows side and `run.sh` is only a
launcher. It copies `src/FloatingSub.ps1` to
`%LOCALAPPDATA%\SpotifyFloatingSub\` and runs it there, because PowerShell
can't reliably load a script straight off `\\wsl.localhost`.

1. **Playback state** comes from the Windows
   `GlobalSystemMediaTransportControlsSessionManager` — the same API behind the
   volume-key now-playing popup. It exposes title, artist, album, cover art and
   playback position, and works regardless of which Spotify build you run. The
   transport buttons drive the same object (`TrySkipNextAsync`,
   `TryTogglePlayPauseAsync`, `TryChangeAutoRepeatModeAsync`, …), so they
   control whichever app owns the media session — not necessarily Spotify.
2. **Position** is corrected and then interpolated. The API's `Position` is a
   step function — it only refreshes every few seconds, and in between it keeps
   returning the value from the last refresh. `LastUpdatedTime` says when that
   value was true, so the age is added on to get the position *now*; without
   that the lyrics would jump backwards by up to a few seconds on every poll.
   Between polls the position is interpolated against a local clock and
   re-anchored only on a real discontinuity (a seek, or play/pause).
3. **Lyrics** are fetched from LRCLIB on a background runspace so a slow
   request never stalls the animation, and cached to disk so replays are
   instant. Matching goes: exact lookup (title + artist + album + duration),
   then — if that misses, *or* hits but has no timings — a search for any entry
   that does have them, accepted only if its duration agrees within the same
   ±2s, so a live or cover version can't win and drag the wipe onto the wrong
   recording. The response is decoded as UTF-8 by hand rather than by
   `Invoke-RestMethod`, which mangles every non-ASCII lyric (see
   Troubleshooting).
4. **Accent colour** is sampled from the cover art by picking the most vivid
   pixel, then lifted so it stays readable on the dark panel. Falls back to a
   hue derived from the track name for art-less tracks.
5. **The wipe** is a hard-stop gradient across the text whose two middle stops
   are moved to the elapsed fraction of the current line. The progress bar runs
   off the same interpolated clock, so it advances smoothly instead of stepping
   once per poll.

Everything is cached under `%LOCALAPPDATA%\SpotifyFloatingSub\cache\`. Deleting
that folder is safe and only costs a refetch. `floatsub.log` in the same folder
records startup, hotkeys and any errors.

## Troubleshooting

**"Spotify is not playing"** — nothing is active in the Windows media session.
Start playback in the desktop app. Browser-based Spotify (`open.spotify.com`)
shows up as a browser session, which the overlay will also follow.

**A track shows "no synced lyrics for this track"** — LRCLIB has plain lyrics
for it but no timestamped version, so there is nothing to sync against. The
overlay shows the track instead of an arbitrary static line. Coverage is good
but not universal, and remixes/live versions are the usual gaps.

**Nothing appears** — check `./run.sh --logs`. On a multi-monitor setup the
overlay is placed on the primary monitor's work area; if it lands somewhere
unexpected, hover it and drag it.

**Lyrics are consistently early or late** — set `syncOffsetMs` in the config.
It shifts every line by a fixed amount, so it's the right knob for a track
whose timestamps are uniformly off. For a one-off, a positive value shows the
lyrics later. Tracks streamed as ads or with a long silent intro are the usual
reason for a constant offset.

**Lyrics in the wrong language or a bad match** — LRCLIB matches on
title/artist/album plus duration (±2s). Compilations and covers occasionally
match the wrong entry; deleting the track's cache file forces a refetch.

**Chinese (or any non-ASCII) lyrics show as gibberish** — if you're on a build
from before 2026-09-16, this is a known fixed bug: LRCLIB sends its JSON
without a `charset`, and PowerShell 5.1 decoded it as Latin-1, so every
accented or CJK character came back as mojibake (`晴天` → `æ´å¤©`,
`Pokémon` → `PokÃ©mon`). The mangled result is cached, so update the script
**and** clear `%LOCALAPPDATA%\SpotifyFloatingSub\cache\lyrics\`. Deleting that
folder is always safe — it only costs a refetch.

**`--selftest` prints the track as `????`** — that's the console, not the
lyrics. PowerShell 5.1 writes console output in the legacy ANSI codepage; the
overlay window renders the same text correctly. The self-test sets
`[Console]::OutputEncoding` to UTF-8 to avoid this, so if you still see
question marks the track really does have a non-ASCII title that the terminal
can't draw.

**A transport button does nothing** — the controls only accept the mouse while
you're hovering the panel, so the click has to land after the hover registers;
move onto the panel, pause briefly, then click. If it still does nothing, check
`./run.sh --logs` for the `transport <name>: accepted=…` line — `False` means
the media session declined, which is normal for an app that doesn't implement
that action.
