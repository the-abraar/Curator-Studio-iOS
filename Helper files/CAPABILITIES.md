# Capabilities

Everything Curator Studio does, in full. The [README](README.md) is the pitch and
the setup guide; this is the inventory.

- [Library](#library)
- [Player — transport & gestures](#player--transport--gestures)
- [Player — audio processing](#player--audio-processing)
- [Player — practice & listening](#player--practice--listening)
- [Progress & state](#progress--state)
- [Playlists](#playlists)
- [Ingest — sending links](#ingest--sending-links)
- [Ingest — what the Mac does](#ingest--what-the-mac-does)
- [Ingest — getting files to the phone](#ingest--getting-files-to-the-phone)
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

## Ingest — sending links

Three channels, one queue.

| Channel | Works from | Notes |
|---|---|---|
| **Telegram bot** | Anywhere, any device, on mobile data | Your own bot. Forward links straight out of other chats. Replies when a job starts and when it's ready. |
| **iOS Share Sheet shortcut** | The YouTube app, Safari, anywhere with a share button | Asks for quality and folder, then posts to Telegram or straight to the Mac. |
| **In-app composer** | The Inbox tab | Paste button, quality list with plain-English descriptions, folder picker drawn from your real tree, and inline folder creation. |

**Request grammar** — the same everywhere:

```
<link>
<link> mid
<link> audio Learn Stuff/German
<link> best Guitar Lessons
<link> low Bike Stuff playlist
```

- Quality words: `best` · `high`/`1080` · `mid`/`720` · `low`/`480` · `audio`/`podcast`/`music`
- Everything else after the link becomes the folder path, created if absent. `/` nests.
- `playlist` fans a playlist URL out into one job per video.
- Only text **after the last URL** counts as options, so pasting a link mid-sentence still works.
- Multiple links in one message create multiple jobs.

Bot commands: `/status` for the queue, `/folders` for what it knows, `/help`.

---

## Ingest — what the Mac does

| Capability | Detail |
|---|---|
| yt-dlp with iPhone-safe formats | Prefers H.264 video + AAC audio streams at the requested ceiling. |
| **Guaranteed playability** | Probes the finished file with `ffprobe`; if YouTube only offered VP9/AV1/Opus, transcodes to H.264/AAC MP4 with `+faststart`. Nothing ever lands unplayable. |
| Audio extraction | `audio` tier produces M4A at maximum quality, video stripped. |
| SponsorBlock | Removes sponsor, self-promo and interaction segments. Categories configurable. |
| Embedded metadata | Thumbnail, title, and chapter markers baked into the file. |
| JSON sidecar | `<name>.curator.json` beside each file: source URL, video id, channel, upload date, duration, description, full chapter list, requested quality, timestamp. |
| Folder mirroring | Files land in the same folder names your phone uses, so both machines stay in sync. |
| Collision handling | Existing filename? Appends the video id rather than overwriting. |
| Persistent queue | Survives restarts; anything mid-flight when the daemon died goes back to queued. |
| Concurrency | Two jobs at a time by default, configurable. |
| Retry & delete | Swipe a failed job in the app, or use the API. |
| Always running | launchd agent — starts with the Mac, restarts on crash, logs to `~/.curator-studio/daemon.log`. |
| CLI | `--add`, `--status`, `--token`, `--foreground` for debugging. |

---

## Ingest — getting files to the phone

| Capability | Detail |
|---|---|
| Bonjour discovery | The Mac advertises `_curator._tcp`; the app finds it with no configuration. Manual IP + port as fallback. |
| Token auth | A shared token generated at install, sent as `X-Curator-Token`. Only `/health` is open. |
| Auto-pull | Finished files transfer on their own next time you're home with the app open. Can be switched off. |
| Live progress | Separate progress for the Mac's download and the Wi-Fi transfer, with speed and ETA. |
| Range streaming | Server supports HTTP Range, so transfers resume rather than restart. |
| Offline queueing | Links entered while the Mac is unreachable are held on the phone and sent automatically when it reappears. |
| Delivery acknowledgement | The Mac marks a job delivered so it's never pulled twice. |
| **Browse Mac library** | Pull *any* media file in the Mac's folder — ripped DVDs, camera footage, an old MP3 collection — not just download jobs. Searchable. |
| Safe paths | Every requested path is resolved and checked against the library root; traversal is rejected. |
| Badge | The Inbox tab badges with active + ready + pending count. |

### HTTP API

All routes except `/health` require the token.

| Method | Route | Purpose |
|---|---|---|
| `GET` | `/health` | Service identity, queue counts |
| `GET` | `/jobs` | Full job list with status and progress |
| `POST` | `/jobs` | Queue a request — `{text, quality?, folder?}` |
| `POST` | `/jobs/<id>/ack` | Mark delivered |
| `POST` | `/jobs/<id>/retry` | Requeue a failure |
| `DELETE` | `/jobs/<id>` | Drop a job |
| `GET` | `/folders` | Folder names on the Mac |
| `GET` | `/shelf` | Every media file in the library root |
| `GET` | `/files/<id>` | Stream a job's file (Range) |
| `GET` | `/shelf/file?path=` | Stream any library file (Range) |

---

## Settings & housekeeping

- Change or rescan the library folder.
- Playback defaults: keep-pitch, transposition engine, autoplay-next.
- Mac connection status, pairing sheet, auto-pull toggle.
- Reset all progress, stars, watched marks and bookmarks. Files are never touched.
- Clear the thumbnail cache.
- In-app help: supported formats with conversion commands, every gesture, and a
  four-step walkthrough of the Mac pipeline.

---

## Platform & privacy

| | |
|---|---|
| **App** | SwiftUI, iOS 26 (drops to 18.0 with one build-setting change), iPhone and iPad, portrait and landscape, dark throughout. |
| **Dependencies** | None. No SPM packages, no CocoaPods. |
| **Daemon** | Python 3 standard library only, plus the `yt-dlp` / `ffmpeg` / `atomicparsley` binaries. |
| **Network** | The Mac never opens a port to the internet. The phone reaches it over your LAN. Telegram, if enabled, is polled outbound only. |
| **Accounts** | None. No analytics, no telemetry, no sign-in. |
| **Data** | Resume state, playlists and pairing details live on-device. Media stays in your folder. |

### Supported formats

| | |
|---|---|
| **Video** | MP4, M4V, MOV, MPEG-1/2, 3GP |
| **Audio** | MP3, M4A, M4B, AAC, WAV, AIFF, CAF, FLAC |
| **Not playable** | MKV, AVI, WEBM, WMV, FLV, OGG/Opus — iOS has no decoder for these, in any app |

Anything the daemon downloads is converted automatically.

---

## Known limits

- **LAN transfers need the app open.** They run in the foreground. Audio playback
  is unaffected — that uses the background audio mode, which is a different
  mechanism.
- **A sleeping Mac can't download.** The queue is persistent, so nothing is lost;
  jobs run when it next wakes.
- **yt-dlp goes stale.** YouTube changes often; most download failures are fixed
  by `brew upgrade yt-dlp` and a retry.
- **Age-restricted videos** need cookies — add `"--cookies-from-browser", "safari"`
  to `build_download_command` in `curator_daemon.py`.
- **Extreme speed + transposition stack.** Past roughly 2× with a large
  transposition, artefacts become audible. That's the algorithms, not a bug.
- **Free Apple ID builds expire after 7 days** and need re-running from Xcode.
  A paid developer account extends this to a year.
