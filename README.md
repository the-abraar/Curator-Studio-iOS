<div align="center">

# Curator Studio

**A media house for one folder — and a YouTube client that fills it for you.**

An offline-first iOS player built for learning and listening, with a full NewPipe-style
YouTube client built in: search it, watch it, download it straight to the phone.
Pitch-preserving speed, ±12 semitone transposition and A–B looping, etc.

`SwiftUI` · `AVFoundation` · `iOS 26` · no accounts, no cloud, no companion machine

</div>

---

## What it is

Point Curator Studio at a single folder in Files. Everything inside — `Songs`,
`Guitar Lessons`, `Bike Stuff`, `Learn Stuff/AI`, `Learn Stuff/German`,
`Randoms`, nested as deep as you like — becomes your library.

Then fill it from the app itself. Search YouTube, open a channel you follow, or
paste a link; pick a quality and a folder; the phone downloads it, merges the
audio and video, cuts the sponsor segments, tags it, and files it away.

```
   your iPhone
   ───────────
   Search / Discover / Subscriptions ──┐
   a pasted link, video or playlist  ──┤
   a channel's latest uploads        ──┘
                    │
                    ▼
            InnerTube extraction        YouTube's own internal API,
                    │                   the same one NewPipe scrapes
                    ▼
        H.264 + AAC streams, chunked     background URLSession
                    │
                    ▼
        AVMutableComposition             mux, SponsorBlock trim, tag
                    │
                    ▼
        your library folder ──►  the player: speed, key, A–B, screen off
```

Nothing leaves the phone. No account, no API key, no server of ours, no Mac.

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

### YouTube

- **Search** videos, channels and playlists, with live suggestions and endless
  scrolling.
- **Discover** shelves by topic, standing in for the Trending feed YouTube
  removed for logged-out users.
- **Channels** with paging video lists; `@handles` resolve automatically.
- **Playlists** read to the last page, so "download all" means all of it.
- **Subscriptions** and **watch history**, kept in one JSON file on the phone —
  no account anywhere.
- **Watch in-app**, with description, chapters and related videos.

### Downloading

- A download button on every row, and a quality sheet that greys out what
  YouTube isn't offering for that particular video.
- **Merging on the phone.** Anything above 720p only exists as separate
  video-only and audio-only streams; both are fetched and muxed into one MP4
  with `AVMutableComposition`, passthrough so nothing is re-encoded.
- **SponsorBlock** segments are cut out of the composition, so they're gone from
  the file — six categories, individually switchable.
- Title, channel, description and poster frame embedded as tags, plus a
  `.curator.json` sidecar with the source link and chapter list.
- Background transfers, a persistent queue, and automatic recovery when a signed
  stream URL expires mid-download.
- Paste a batch of links, import a text file of them, take a channel's latest
  ten, or queue an entire playlist into one folder.

---

## Repository layout

```
.
├── CuratorStudio.xcodeproj
├── Config/
│   └── Info.plist                 background audio + downloads
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
│   ├── YouTube/
│   │   ├── Engine/                InnerTube client, visitor identity,
│   │   │                          search / channel / playlist / stream
│   │   │                          extractors, SponsorBlock
│   │   ├── Download/              queue, chunked fetcher, muxer
│   │   ├── UI/                    browse, watch, channel, downloads
│   │   └── YouTubeStore.swift     subscriptions, history, recent searches
│   └── UI/                        theme, settings, help
```

The Xcode target uses a `PBXFileSystemSynchronizedRootGroup`, so new Swift files
dropped into `CuratorStudio/` are compiled automatically — no project file edits.

---

## Getting started

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
5. Open the **YouTube** tab and search for something.

> **Older Xcode?** Set `IPHONEOS_DEPLOYMENT_TARGET` to `18.0` in build settings.
> Nothing in the codebase uses an API newer than iOS 18.

There is no second half to set up. No daemon, no Homebrew, no pairing token, no
Telegram bot, no Wi-Fi requirement.

---

## How the interesting bits work

**Getting past the bot check.** YouTube's `/youtubei/v1/player` endpoint answers
anonymous requests with `LOGIN_REQUIRED` — "sign in to confirm you're not a bot" —
unless the request carries a visitor identity. A real client has one because it
loaded youtube.com first and was handed a `visitorData` blob. So the app does the
same: one homepage fetch, scrape the blob, and echo it back in `X-Goog-Visitor-Id`
on every call. Verified live: identical requests return `LOGIN_REQUIRED` without
that header and `OK` with it. Cookies make no difference either way. That single
header is the difference between "some videos play" and "videos play".

**Why the downloader fetches in chunks.** googlevideo now refuses an open-ended
`GET` on a stream URL with `403`, while serving the same URL happily for a
`Range: bytes=0-10485759`. So each stream is pulled as a run of sequential ranged
requests appended into one file — the same shape yt-dlp uses. The URLs are also
signed, IP-bound and short-lived, so when one starts being refused part-way
through, the app re-extracts a fresh URL for the same format and continues from
the byte it stopped at.

**Muxing without ffmpeg.** YouTube stopped serving muxed streams above 720p:
higher qualities exist only as separate video-only and audio-only renditions. The
two files are laid into an `AVMutableComposition` and exported with
`AVAssetExportPresetPassthrough`, so H.264 and AAC are copied rather than
re-encoded — seconds of work instead of minutes, and no battery drain. Removing
SponsorBlock segments falls out of the same mechanism for free: the flagged
ranges are simply never inserted into the composition.

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

---

## Supported formats

| | |
|---|---|
| **Video** | MP4, M4V, MOV, MPEG-1/2, 3GP |
| **Audio** | MP3, M4A, M4B, AAC, WAV, AIFF, CAF, FLAC |
| **Not playable** | MKV, AVI, WEBM, WMV, FLV, OGG/Opus — iOS has no decoder |

Downloads always land as H.264/AAC MP4 (or M4A for audio-only), so anything the
app fetches is playable by definition. For files you copy in yourself:

```bash
ffmpeg -i input.mkv -c copy output.mp4                        # remux if codecs allow
ffmpeg -i input.mkv -c:v libx264 -c:a aac output.mp4          # otherwise re-encode
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| *Sign in to confirm you're not a bot* | YouTube is refusing anonymous extraction from your address for a while. The app fetches a fresh visitor identity and retries automatically; if it persists, wait and try again later. |
| A download fails part-way | The signed stream URL expired or was refused. Swipe → Retry; the app re-extracts a new URL. Repeated failures usually mean YouTube is rate-limiting the connection, not that the video is broken. |
| No 4K option | YouTube only offers 4K as VP9/AV1, which iOS can't put in a playable MP4. 1080p H.264 is the real ceiling. |
| "Can't play this video" but the download works | Streaming uses the single muxed format; downloading merges the separate higher-quality streams. They're different paths, and the second one succeeds more often. |
| A download stalls when you leave the app | Transfers continue in the background, but merging and filing wait for the app to be open again. Reopen it and the job finishes itself. |
| Transposition sounds odd | Spectral stretching and pitch shifting stack; past ~2× with a large transposition you'll hear it. The engine can be switched off in Settings. |
| Video is black / won't open | Unsupported container — see the format table. |
| Extraction stops working entirely | YouTube changed something. Start with `CuratorStudio/YouTube/Engine/Innertube.swift`, which holds the client identities and the visitor-id logic. |

---

## Status & scope

Built as a personal tool, not a product. There are no analytics, no accounts and
no network calls beyond YouTube's own endpoints and SponsorBlock. Like NewPipe
itself, this can't go on the App Store — it's for personal builds and sideloading.
Downloading is subject to YouTube's terms and your local copyright law; this is
built for the personal-archive case.

Not affiliated with NewPipe or TeamNewPipe. The extraction engine is a native
Swift reimplementation of the same idea, not a port of their Java library.

---

## Licence

MIT. Do what you like with it.
