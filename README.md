<div align="center">

# Curator Studio

**A media house for one folder — and a Mac that fills it for you.**

An offline-first iOS player built for learning and listening, paired with a Mac
daemon that turns any link you send it into a file in the right folder on your
phone. Pitch-preserving speed, ±12 semitone transposition and A–B looping, etc.

`SwiftUI` · `AVFoundation` · `iOS 26` · `Python 3` · `yt-dlp` · no dependencies, no accounts, no cloud

</div>

---

## What it is

Point Curator Studio at a single folder in Files. Everything inside — `Songs`,
`Guitar Lessons`, `Bike Stuff`, `Learn Stuff/AI`, `Learn Stuff/German`,
`Randoms`, nested as deep as you like — becomes your library.

Then, from anywhere: send a YouTube link to your Mac with a quality and a folder
name. It downloads, converts, tags, files it, and hands it to your phone the
next time you're on your Wi-Fi.

```
   you, anywhere                    your Mac                      your iPhone
   ─────────────                    ────────                      ───────────
   Telegram message  ─────────►  curator_daemon
   YouTube share sheet ───────►     │  yt-dlp → H.264/AAC MP4
   Inbox tab in the app ──────►     │  SponsorBlock, thumbnail,
                                    │  chapters, JSON sidecar
                                    ▼
                             ~/CuratorStudio/<folder>/
                                    │
                                    │  token-authed HTTP over your LAN
                                    ▼
                            Curator Studio → Inbox  ──►  your library folder
```

Nothing leaves your hardware. The Mac never opens a port to the internet; the
phone reaches it over the local network. Telegram, if you enable it, is used
purely as a message inbox.

---

## Features

### Player

| | |
|---|---|
| **Seek** | Double-tap left/right for ∓10s, stacking on repeat taps (10 → 20 → 30). Centre double-tap toggles play. |
| **Hold for 2×** | Press and hold anywhere for temporary double speed; release to snap back. |
| **Scrub** | Drag sideways with a live time-and-delta preview. |
| **Speed** | 0.25×–3× with presets, slider and fine nudges. **Keep the pitch** switch toggles spectral time-stretch vs. tape mode. |
| **Transpose** | **±12 semitones with speed untouched**, plus ±50 cents of fine tuning. Works on video, not just audio. |
| **A–B loop** | Set A, set B, repeat forever — the region is shaded on the scrub bar. |
| **Bookmarks** | Named timestamps per file, tap to jump. |
| **Screen off** | Blacks the display and keeps the audio going. Double-tap to wake. |
| **Background audio** | Lock the phone and keep playing, with Lock Screen artwork, scrubbing, skip-10s and AirPods gestures. |
| **Extras** | Picture in Picture, AirPlay, sleep timer with a volume fade, fit/fill, repeat, shuffle, autoplay. |

Speed and key are remembered **per file** — a lesson you set to 0.75× at −2
semitones comes back that way.

### Library

- Recursive scan of one security-scoped folder; access survives relaunches.
- List or grid, sortable by name / date / size / last played, searchable across
  the whole tree.
- Folder icons and tints derived from folder names.
- Video poster frames generated and cached; audio gets a waveform glyph.
- Resume position on every file, rewound 5s for context.
- Home shelves: *Pick up where you left off*, collections, starred, recents.
- Star, mark watched, reset progress — swipe or long-press.
- Unplayable containers are counted and explained rather than silently dropped.

### Playlists

- Mix files from **any** folders in one queue.
- Multi-select in a folder, or browse the whole tree in picker mode.
- Reorder, rename, custom SF Symbol icons, shuffle, play-all.
- "Save this folder as a playlist" in one tap.
- Export / import as JSON. Missing files are flagged with one-tap cleanup.

### Ingest

- **Three send channels**: Telegram bot (anywhere, any device), iOS Share Sheet
  shortcut, and an in-app composer with a real folder picker.
- **Grammar**: `<link> mid Learn Stuff/AI` — quality words are recognised after
  the link, everything else becomes the folder path (created if absent). Add
  `playlist` to fan a playlist out into separate jobs.
- **Guaranteed playability**: the daemon probes the output and transcodes to
  H.264/AAC MP4 when YouTube only offered VP9/AV1/Opus.
- SponsorBlock removal, embedded thumbnail / chapters / metadata, and a
  `.curator.json` sidecar with source URL, channel, date and chapter list.
- Bonjour discovery, token auth, live progress for both the Mac's download and
  the Wi-Fi transfer, auto-pull, and a persistent queue on both ends.
- **Browse Mac library** pulls *any* file in the Mac's folder — ripped DVDs,
  camera footage, an old MP3 collection — not just download jobs.

---

## Repository layout

```
.
├── CuratorStudio.xcodeproj
├── Config/
│   └── Info.plist                 background audio, local network, Bonjour
├── CuratorStudio/
│   ├── CuratorStudioApp.swift
│   ├── Core/                      folder bookmark & scan, resume state,
│   │                              playlists, thumbnails, formatting
│   ├── Audio/
│   │   ├── PitchProcessor.swift   MTAudioProcessingTap + AUNewTimePitch
│   │   └── AudioSessionManager.swift
│   ├── Player/                    player model, Now Playing, gestures,
│   │                              controls, sheets, mini player
│   ├── Library/                   folder picker, browser, home shelves
│   ├── Playlists/                 cross-folder playlists
│   ├── Sync/                      Bonjour discovery, HTTP client, ingest
│   │                              queue, Inbox UI
│   └── UI/                        theme, settings, help
└── Mac/
    ├── curator_daemon.py          HTTP API + yt-dlp runner + Telegram bridge
    ├── install.sh
    └── uninstall.sh
```

The Xcode target uses a `PBXFileSystemSynchronizedRootGroup`, so new Swift files
dropped into `CuratorStudio/` are compiled automatically — no project file edits.

---

## Getting started

### 1. The app

Requires Xcode 26 and an iPhone. A **free Apple ID is enough**; the build simply
needs re-running every 7 days, which is the normal free-account limit.

```bash
git clone https://github.com/<you>/curator-studio.git
cd curator-studio
open CuratorStudio.xcodeproj
```

1. Target **CuratorStudio** → **Signing & Capabilities**
   - **Team**: your personal Apple ID (add it under Xcode → Settings → Accounts)
   - **Bundle Identifier**: change `com.blankframe.curatorstudio` to something
     unique to you. Free accounts reject identifiers already claimed elsewhere.
2. Select your iPhone as the destination, press <kbd>⌘R</kbd>.
3. On the phone: **Settings → General → VPN & Device Management → Developer App**
   → trust the certificate.
4. In the app, tap **Choose your media folder**. No folder yet? Files → On My
   iPhone → new folder `Curator Studio`, and pick that.

> **Older Xcode?** Set `IPHONEOS_DEPLOYMENT_TARGET` to `18.0` in build settings.
> Nothing in the codebase uses an API newer than iOS 18.

### 2. The Mac daemon

```bash
cd Mac
chmod +x install.sh uninstall.sh
./install.sh
```

Installs `yt-dlp`, `ffmpeg` and `atomicparsley` via Homebrew, copies the daemon
to `~/.curator-studio/`, creates `~/CuratorStudio/` with the usual folders, and
registers a launchd agent that starts with the Mac and restarts on failure.

It prints your pairing details at the end:

```
Host:  192.168.1.20:8787
Token: 3f9a2c1e8b7d4a6f0c52
```

Library somewhere else? `CURATOR_LIBRARY=/Volumes/Media/Curator ./install.sh`

**Pair the phone:** Inbox → ⋯ → **Connect to Mac**. The Mac advertises itself
over Bonjour and should appear on its own; paste the token and connect.

### 3. Telegram (optional, recommended)

This is what makes "forward a link from a group chat" work — you forward it into
your own bot instead. WhatsApp has no personal automation API; Telegram's is free.

1. Message **@BotFather** → `/newbot` → get a token.
2. Put it in `~/.curator-studio/config.json` under `telegram.bot_token`.
3. `launchctl kickstart -k gui/$(id -u)/com.blankframe.curatorstudio.daemon`
4. Message your bot once — the first chat to talk to it gets paired; everyone
   else is refused.

Then, from anywhere:

```
https://youtu.be/…
https://youtu.be/…  mid
https://youtu.be/…  audio Learn Stuff/German
https://youtu.be/…  best Guitar Lessons
https://youtube.com/playlist?list=…  low Bike Stuff playlist
```

`/status` shows the queue, `/folders` lists what it knows.

### 4. YouTube share sheet shortcut (optional)

Shortcuts → **+** → name it *Curator Studio* → ⓘ → **Show in Share Sheet**,
types: **URLs**. Then: *Choose from Menu* for quality → *Choose from Menu* for
folder → *Text* combining `[Input] [quality] [folder]` → **Get contents of URL**
pointing at either

- `https://api.telegram.org/bot<TOKEN>/sendMessage` with JSON `chat_id` + `text`
  (works on mobile data), or
- `http://<mac-ip>:8787/jobs` with header `X-Curator-Token` and JSON `text`
  (home Wi-Fi only, no third party).

Full step-by-step table is in the in-app help: Settings → How the Mac pipeline works.

---

## Configuration

`~/.curator-studio/config.json`:

```jsonc
{
  "library_root": "/Users/you/CuratorStudio",
  "port": 8787,
  "token": "…",
  "device_name": "Abraar's Mac",
  "default_quality": "mid",              // best · high · mid · low · audio
  "default_folder": "Randoms",
  "force_compatible": true,              // transcode anything iOS can't decode
  "embed_metadata": true,                // thumbnail, title, chapters
  "sponsorblock": true,
  "sponsorblock_categories": "sponsor,selfpromo,interaction",
  "write_sidecar": true,                 // <name>.curator.json beside each file
  "max_concurrent_jobs": 2,
  "advertise_bonjour": true,
  "telegram": { "bot_token": "", "allowed_chat_ids": [] }
}
```

Restart the daemon after editing.

### Daemon commands

```bash
tail -f ~/.curator-studio/daemon.log
python3 ~/.curator-studio/curator_daemon.py --status
python3 ~/.curator-studio/curator_daemon.py --token
python3 ~/.curator-studio/curator_daemon.py --add "https://youtu.be/… mid Songs"
python3 ~/.curator-studio/curator_daemon.py --foreground
launchctl kickstart -k gui/$(id -u)/com.blankframe.curatorstudio.daemon
```

### HTTP API

All routes except `/health` require `X-Curator-Token`.

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/health` | Service identity, queue counts |
| `GET` | `/jobs` | Full job list with status and progress |
| `POST` | `/jobs` | Queue a request — `{text, quality?, folder?}` |
| `POST` | `/jobs/<id>/ack` | Mark delivered to the phone |
| `POST` | `/jobs/<id>/retry` | Requeue a failed job |
| `DELETE` | `/jobs/<id>` | Drop a job |
| `GET` | `/folders` | Folder names on the Mac |
| `GET` | `/shelf` | Every media file in the library root |
| `GET` | `/files/<id>` | Stream a job's file (Range supported) |
| `GET` | `/shelf/file?path=` | Stream any library file (Range supported) |

---

## How the interesting bits work

**Transposition without changing speed.** An `MTAudioProcessingTap` is attached
to the player item's audio track through an `AVAudioMix`. Inside the tap runs
Apple's `AUNewTimePitch` unit with its *rate* parameter pinned at 1.0 and only
its *pitch* parameter driven — so `AVPlayer.rate` keeps sole control of speed
while the tap owns key. Speed's own pitch behaviour is a separate lever:
`AVPlayerItem.audioTimePitchAlgorithm` set to `.spectral` (natural voices) or
`.varispeed` (tape). If the tap fails to initialise, playback falls through
untransposed rather than breaking.

**Screen-off listening.** `UIBackgroundModes: audio` plus
`audiovisualBackgroundPlaybackPolicy = .continuesIfPossible` keeps video files
playing audio when the phone locks. The in-app *Screen off* mode is separate — it
drops display brightness to zero and holds the idle timer for when you want the
phone unlocked but dark.

**Why LAN, not AirDrop.** macOS has no headless AirDrop API — every send needs a
human tap on the share sheet, which defeats the purpose of automating it. A
token-authed HTTP pull over the local network does the same job with zero taps,
at Wi-Fi speed, and never leaves the house.

---

## Supported formats

| | |
|---|---|
| **Video** | MP4, M4V, MOV, MPEG-1/2, 3GP |
| **Audio** | MP3, M4A, M4B, AAC, WAV, AIFF, CAF, FLAC |
| **Not playable** | MKV, AVI, WEBM, WMV, FLV, OGG/Opus — iOS has no decoder |

```bash
ffmpeg -i input.mkv -c copy output.mp4                        # remux if codecs allow
ffmpeg -i input.mkv -c:v libx264 -c:a aac output.mp4          # otherwise re-encode
```

Anything the daemon downloads is handled automatically.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| *Mac not reachable* | Same Wi-Fi? Mac awake? Check `launchctl list \| grep curatorstudio`. If you dismissed iOS's Local Network prompt, re-enable it under Settings → Curator Studio. |
| Bonjour finds nothing | Some routers block mDNS between clients. Type the IP and port manually — identical behaviour. |
| A download fails | Almost always a stale yt-dlp. `brew upgrade yt-dlp`, then swipe the job → Retry. Age-restricted videos need `"--cookies-from-browser", "safari"` added to `build_download_command`. |
| Transposition sounds odd | Spectral stretching and pitch shifting stack; past ~2× with a large transposition you'll hear it. The engine can be switched off in Settings. |
| Video is black / won't open | Unsupported container — see the format table. |
| Transfer stops when you leave the app | Expected: LAN transfers run in the foreground. Audio playback is unaffected — different mechanism. |
| Jobs don't run overnight | A sleeping Mac can't download. The queue is persistent, so nothing is lost — it resumes on wake. |

---

## Status & scope

Built as a personal tool, not a product. There are no analytics, no accounts, no
network calls beyond yt-dlp's own traffic and — if you switch it on — Telegram
polling. Downloading is subject to YouTube's terms and your local copyright law;
this is built for the personal-archive case.

---

## Licence

MIT. Do what you like with it.
