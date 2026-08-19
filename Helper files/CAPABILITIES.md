# Capabilities

Everything Curator Studio does, in full. The [README](README.md) is the pitch and
the setup guide; this is the inventory.

- [Library](#library)
- [Player — transport & gestures](#player--transport--gestures)
- [Player — audio processing](#player--audio-processing)
- [Player — practice & listening](#player--practice--listening)
- [Progress & state](#progress--state)
- [Playlists](#playlists)
- [YouTube — browsing](#youtube--browsing)
- [YouTube — subscriptions & history](#youtube--subscriptions--history)
- [Downloading — sending links](#downloading--sending-links)
- [Downloading — what the phone does](#downloading--what-the-phone-does)
- [Settings & housekeeping](#settings--housekeeping)
- [Platform & privacy](#platform--privacy)
- [Known limits](#known-limits)

---

## Library

| Capability | Detail |
|---|---|
| Single-folder library | Pick one folder in Files — On My iPhone, iCloud Drive, or an external drive. Nothing outside it is ever touched. |
| Persistent access | Security-scoped bookmark, so access survives app relaunches and device restarts. |
| Recursive tree | Any depth. `Learn Stuff/AI`, `Learn Stuff/Programming/Rust`, and so on. |
| Automatic folder icons | Icon and colour tint derived from the folder name — guitar → guitars, bike → bicycle, AI → brain, German → book, podcast → mic, and ~20 more. |
| List or grid | Per-folder preference, remembered. |
| Sorting | Name, date modified, file size, or last played. Ascending or descending. |
| Flatten a branch | "Include subfolders" pulls an entire subtree into one list. |
| Search | Across every file in the library, by display name or path. |
| Thumbnails | Video poster frames generated at ~10% in, cached to memory and disk. Audio files get a waveform glyph. |
| Breadcrumbs | Search and playlist rows show `Learn Stuff › German` so you know where a file lives. |
| Unplayable file reporting | Counts files iOS can't decode and says so, with the ffmpeg fix — rather than hiding them. |
| Refresh | Pull to rescan, or a toolbar button. |

---

## Player — transport & gestures

| Capability | Detail |
|---|---|
| Double-tap seek | Left third −10s, right third +10s. **Stacks on repeat taps** — 10 → 20 → 30 — with a ripple badge and haptics. |
| Double-tap centre | Play / pause. |
| Single tap | Show / hide controls. They auto-hide after 4.5s during video playback. |
| Hold for 2× | Press and hold anywhere for temporary double speed; release to snap back. |
| Drag to scrub | Horizontal drag with a live time readout and a ± delta from where you started. |
| Scrub bar | Draggable, with the A–B loop region shaded in and an enlarged thumb while dragging. |
| Next / previous | Previous restarts the current item unless you're within 3 seconds of the start. |
| Skip buttons | ∓10s buttons alongside the transport, plus the same from the Lock Screen. |

---

## Player — audio processing

| Capability | Detail |
|---|---|
| Speed 0.25×–3× | Presets, a continuous slider, and ±0.05 nudge buttons. |
| Keep the pitch | **On** — spectral time-stretch, voices stay natural at any speed. **Off** — tape mode, faster means higher. |
| Transposition | **±12 semitones with playback speed untouched.** Quick-jump grid from −6 to +6, and arrow steppers beyond. |
| Fine tuning | ±50 cents on top, for recordings that sit slightly off concert pitch. |
| Key readout | Shows what C becomes at your current transposition. |
| Works on video | Not just audio files — transposition applies to the audio track of a video lesson too. |
| Per-file memory | Speed and key are stored per file. A lesson set to 0.75× at −2 semitones comes back that way. |
| Time-remaining maths | "≈14:20 left at 1.5×" — real remaining time at your current speed. |
| Engine toggle | Transposition can be switched off entirely if a specific file misbehaves, for the shortest possible path to the speakers. |
| Graceful failure | If the processing tap can't initialise, playback continues untransposed rather than breaking. |

**How.** An `MTAudioProcessingTap` on the player item's audio track runs Apple's
`AUNewTimePitch` with its rate parameter pinned at 1.0 and only its pitch
parameter driven — so `AVPlayer.rate` keeps sole control of speed while the tap
owns key. Speed's own pitch behaviour is a separate lever:
`AVPlayerItem.audioTimePitchAlgorithm` set to `.spectral` or `.varispeed`.

---

## Player — practice & listening

| Capability | Detail |
|---|---|
| A–B loop | Set A, set B, repeats until cleared. The region is shaded on the scrub bar. Built for drilling a lick. |
| Bookmarks | Named timestamps per file. Tap to jump, swipe to delete. |
| Screen off | Blacks the display and holds the idle timer while audio keeps playing. Double-tap to wake. |
| Background audio | Lock the phone and keep playing — including video files, via `audiovisualBackgroundPlaybackPolicy`. |
| Lock Screen controls | Title, folder, artwork, duration, scrubbing, play/pause, ∓10s, next/previous, and playback rate. |
| Headphone controls | AirPods and Bluetooth transport buttons work throughout. |
| Interruption handling | Pauses for calls, resumes afterwards when the system says it should. |
| Sleep timer | 5 / 15 / 30 / 45 / 60 minutes, or end-of-item. Fades the volume out over ~1.5s rather than cutting. |
| Picture in Picture | Auto-starts from inline when supported. |
| AirPlay | Route picker in the player controls. |
| Fit / fill | Toggle between letterboxed and edge-to-edge. |
| Repeat & shuffle | Repeat off / queue / one, shuffle with a stable shuffled order, autoplay-next. |
| Queue view | See and jump around the current queue with the playing item highlighted. |
| File info | Container, size, duration, current speed and key, output route, progress percentage. |

---

## Progress & state

| Capability | Detail |
|---|---|
| Resume everywhere | Every file remembers its position and resumes **5 seconds earlier** so you re-hear the context. |
| Auto-complete | Past 97% an item marks itself watched; rewinding below 90% un-marks it. |
| Home shelves | *Pick up where you left off*, collection tiles, *Starred*, *Recently played*. |
| Progress rings | Partially-watched items show a progress bar on their thumbnail in grid, list and mini player. |
| Star / unstar | Swipe right on any row, or long-press. |
| Watched / unwatched | Swipe left, or long-press. |
| Reset progress | Per item, from the long-press menu. |
| Debounced persistence | Written to JSON in Application Support, throttled so scrubbing doesn't thrash the disk. |

---

## Playlists

| Capability | Detail |
|---|---|
| Cross-folder | Mix files from anywhere in the tree — three guitar lessons, a German podcast and two songs in one queue. |
| Two ways to build | Multi-select inside a folder, or browse the whole tree in a collapsible picker with per-folder "select all". |
| Save a folder | Turn any folder (optionally including its subfolders) into a playlist in one tap. |
| Reorder | Drag to reorder; swipe to remove. |
| Custom identity | Rename, and pick from twelve SF Symbol icons. |
| Play or shuffle | Play in order, or shuffle the whole list. |
| Add to queue | Append individual items or a whole selection to what's currently playing. |
| Missing-file handling | Entries whose files have gone show as a count, with one-tap cleanup. |
| Export / import | JSON via the share sheet and the document picker. |

---

## YouTube — browsing

A full NewPipe-style client, built on YouTube's own internal "InnerTube" endpoints —
the same ones youtube.com and the official apps call. No API key, no account, no
Google sign-in, and no third-party server in the middle.

| Capability | Detail |
|---|---|
| Search | Videos, channels and playlists, with filter chips for each. Endless scrolling through continuation pages. |
| Search suggestions | Live autocomplete from YouTube's own suggest service, plus your recent searches. |
| Discover | Topic shelves — Music, Guitar lessons, Technology, Science, News — fetched in parallel. (YouTube killed its logged-out Trending feed; this stands in for it.) |
| Channels | Header with avatar, subscriber count and description; newest-first video list with paging. `@handles` resolve through search. |
| Playlists | Whole playlist listing, every continuation page walked, with one-tap "download all". |
| Watch | Streams in-app with AVPlayer, with the description, chapter list and an "up next" list of related videos. |
| Paste a link | A video, Short, `youtu.be`, `/live/`, `/embed/`, playlist or channel URL — pasted into search or the link sheet — jumps straight to the right screen. |
| Share out | Share sheet for any video or channel. |

## YouTube — subscriptions & history

| Capability | Detail |
|---|---|
| Subscriptions | Follow channels without an account. Stored in one JSON file on the phone. |
| Subscription feed | Newest uploads across every channel you follow, interleaved round-robin so one prolific channel can't bury the rest. |
| Watch history | Every video you open, newest first, swipe to remove, one tap to clear. Local only. |
| Recent searches | Offered back as suggestions; clearable. |

---

## Downloading — sending links

| Channel | Notes |
|---|---|
| **Download button** | On every video row, in every list — search results, channel, playlist, related, history. |
| **Download sheet** | Quality list with plain-English descriptions, greyed out for anything YouTube isn't offering for that video, plus a folder picker drawn from your real library tree with inline folder creation. |
| **Quick download** | One tap on the video screen, using your default quality and folder. |
| **Paste links** | One URL, or a whole batch separated by commas or newlines, or imported from a text file. Playlist URLs fan out into one job per video. |
| **Channel / playlist bulk** | "Download latest 10" on a channel, "Download all" on a playlist. |

Quality words are the same vocabulary as before — `best` · `high` (1080p) · `mid`
(720p) · `low` (480p) · `audio` — and the folder can be nested (`Learn Stuff/German`),
created if it doesn't exist yet.

---

## Downloading — what the phone does

| Capability | Detail |
|---|---|
| Format selection | Prefers H.264 video + AAC audio at the requested ceiling, because those are the only codecs AVFoundation will put in a playable MP4. VP9, AV1 and Opus renditions are parsed and deliberately skipped. |
| **On-device muxing** | Anything above 720p exists only as separate video-only and audio-only streams. Both are downloaded and merged into one MP4 with `AVMutableComposition` — the job ffmpeg used to do on the Mac. |
| Passthrough export | H.264/AAC is copied, not re-encoded, so merging a 40-minute lecture takes seconds rather than draining the battery. |
| Audio extraction | The `audio` tier saves the AAC stream on its own as `.m4a`. |
| SponsorBlock | Community-marked segments are cut out of the composition itself, so they're gone from the file. Six categories, individually switchable. |
| Embedded metadata | Title, channel, description and the poster frame written into the file as tags. |
| JSON sidecar | `<name>.curator.json` beside each file: source URL, video id, channel, quality, duration, chapter list and exactly which segments were removed. |
| Chunked transfers | googlevideo refuses open-ended GETs, so streams are pulled as sequential ranged requests, the way yt-dlp does it. |
| **Expiry recovery** | Stream URLs are signed and short-lived. When one starts being refused mid-download, the app re-extracts a fresh URL and carries on from the byte it stopped at — restarting the part from zero if even that keeps being turned down. |
| **Unattended retries** | A refusal is usually YouTube deciding an address has asked too often, and it passes. A refused job waits ten minutes and tries itself again, up to three times, before it needs you. |
| Background downloads | A background `URLSession` keeps transfers running when you leave the app or lock the phone; merging and filing finish next time the app is open. |
| Persistent queue | Written to disk on every change. Killing the app mid-download loses nothing — interrupted parts restart, finished ones are picked up. |
| Concurrency | Two jobs at a time by default, 1–4 configurable. |
| Retry, cancel, remove | Swipe any job. Failures explain themselves rather than just going red. |
| Collision handling | An existing filename gets ` (2)` appended rather than being overwritten. |
| Badge | The YouTube tab badges with the number of active jobs. |

---

## Settings & housekeeping

- Change or rescan the library folder.
- Playback defaults: keep-pitch, transposition engine, autoplay-next.
- Download settings: default quality, how many at once, SponsorBlock categories,
  metadata embedding, sidecar writing.
- Reset all progress, stars, watched marks and bookmarks. Files are never touched.
- Clear the thumbnail cache.
- In-app help: supported formats with conversion commands, every gesture, and a
  five-step walkthrough of how downloading works.

---

## Platform & privacy

| | |
|---|---|
| **App** | SwiftUI, iOS 26 (drops to 18.0 with one build-setting change), iPhone and iPad, portrait and landscape, dark throughout. |
| **Dependencies** | None. No SPM packages, no CocoaPods, no companion machine. |
| **Extraction** | A from-scratch Swift reimplementation of the InnerTube scraping NewPipe does on Android. Not a port of, or a bridge to, NewPipeExtractor — that's JVM code and can't run here. |
| **Network** | YouTube's own endpoints, googlevideo for the streams, and SponsorBlock for segment lists. Nothing else. |
| **Accounts** | None. No analytics, no telemetry, no sign-in, no server of ours. |
| **Data** | Resume state, playlists, subscriptions, history and the download queue all live on-device. Media stays in your folder. |

### Supported formats

| | |
|---|---|
| **Video** | MP4, M4V, MOV, MPEG-1/2, 3GP |
| **Audio** | MP3, M4A, M4B, AAC, WAV, AIFF, CAF, FLAC |
| **Not playable** | MKV, AVI, WEBM, WMV, FLV, OGG/Opus — iOS has no decoder for these, in any app |

Downloads always land as H.264/AAC MP4 (or M4A for audio-only), so anything the app
fetches for you is playable by definition.

---

## Known limits

- **YouTube fights anonymous downloads.** Requests are answered from a signed,
  IP-bound, short-lived URL, and YouTube will refuse one part-way through — or
  refuse a whole run for a while if it thinks you're a bot. The app re-extracts
  and resumes automatically, but a download can still fail and need retrying
  later. This affects every tool that doesn't sign in, `yt-dlp` included.
- **1080p is the ceiling.** YouTube only serves H.264 up to 1080p; 4K exists
  only as VP9 and AV1, which iOS won't put in a playable MP4. "Best" means the
  best this phone can actually decode.
- **Merging needs the app open.** Transfers keep running in the background, but
  muxing and filing happen when the app is next foregrounded.
- **Some videos won't resolve.** Age-restricted, members-only and region-blocked
  videos need a signed-in session, which this app deliberately doesn't have.
- **Extreme speed + transposition stack.** Past roughly 2× with a large
  transposition, artefacts become audible. That's the algorithms, not a bug.
- **Free Apple ID builds expire after 7 days** and need re-running from Xcode.
  A paid developer account extends this to a year.
