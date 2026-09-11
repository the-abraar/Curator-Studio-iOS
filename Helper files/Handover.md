# Handover — downloads that never land

**Status: open.** As of 2026-09-11 no download has yet reached the library. Several
real bugs were found and fixed along the way; the one still standing is in the last
section, along with the decision it needs.

Everything below was verified against the live service or read out of the phone's
own log. Where something is still a theory it says so.

**2026-09-11 update:** the IP-rotation theory below is now disproven by fresh
evidence — see *"2026-09-11: the IP-rotation theory is dead"* further down for
what actually happened, what was ruled out this round, and what's left standing.
Playback was also reported broken this session ("loads but never starts") — that
one's understood, see the note right after this paragraph.

## Playback doesn't start (separate from downloads, same underlying cause)

`VideoScreen.swift` hands `AVPlayer` a single progressive (muxed video+audio)
stream URL directly (`VideoDetails.streamableURL` in `Models.swift`, itag 18/22).
This was already tested live before today and is in the *Ruled out* table: **muxed
progressive itag 18 gets refused 403 on the very first chunk, always, for this
client.** So playback gets metadata (title, thumbnail — hence "it loads") but the
actual media request is refused immediately and `AVPlayer` buffers forever. This
is a dead end as built, not a transient bug, and there is currently no logging on
the playback path at all (`Log` is only wired into the download path) — so if this
gets picked up, instrument `VideoScreen.load()` before doing anything else.

---

## The symptom chain

Three different faults wearing the same costume. Worth knowing which is which,
because two are fixed and the third is not.

1. **"Progress bar reaches 100%, sits there forever, no error."**
   The queue had several silent dead ends — a finished transfer could be dropped on
   the floor with no error and no state change. Fixed; see *Fixed* below.

2. **"YouTube kept cutting this download off — it never got past 1 MB."**
   Not a regression. This is fault 3 finally being *reported* instead of hanging,
   which is what the fault-1 fixes bought.

3. **Every stream URL serves roughly one range request, then 403s.** ← still open.

---

## Fixed and committed

| What was wrong | Where |
|---|---|
| Delegate callbacks for a transfer the current process doesn't know about were dropped silently — the chunk loop's byte offset lives in memory, so an app relaunch stranded the job at "Downloading" forever | `StreamFetcher.swift:9`, `:428` → `fetcherLostTransfer`, handled in `DownloadManager.swift:572` (requeues the job) |
| `liveJobIDs()` counted finished and cancelled tasks as live, so `resume()` skipped recovery in exactly the case needing it | `StreamFetcher.swift:184` — only `.running`/`.suspended` tasks, plus transfers active within `stallWindow` (`:71`) |
| An interrupted merge re-downloaded the whole video instead of using the staged parts still on disk | `DownloadManager.swift:118`, `:137`, `:146` |
| An empty 206 body reset the failure budget → infinite silent loop | `StreamFetcher.swift` `appendChunk` |
| `fail()` left the sibling part of an adaptive pair running, writing into staging that had just been deleted | `DownloadManager.swift` `fail()` |
| **`Range: bytes=0-` (open-ended) is refused 403 by googlevideo, always.** Every part opened with one. Six trials, fresh URLs, video and audio: open-ended → 403, closed range on the same URL → 206 | `StreamFetcher.swift:123` — always chunked, closed ranges only |
| Ranged requests could be answered from `NSURLCache`, which keys on URL and ignores `Range` | `StreamFetcher.swift:98`, `:232` |
| Library only refreshed after an import, so files arriving another way stayed invisible | `CuratorStudioApp.swift:53` — rescan on every foreground |
| No logging anywhere, so every diagnosis was guesswork | `Core/Log.swift` (new) — os_log + a file in the app container |

---

## Ruled out — don't re-litigate these

Each was tested against the live service, not reasoned about.

| Theory | Test | Verdict |
|---|---|---|
| Wrong `User-Agent` (desktop Chrome on an `ANDROID_VR` URL) | Old Chrome UA + `Sec-Fetch-Mode: navigate` against a fresh URL | **Wrong.** 206. The UA now matches the extractor client for consistency, but it was never the cause |
| The audio stream specifically is refused | Every format on a fresh extraction | **Wrong.** itags 137/136/134/160/139/140 all 206. Earlier "audio is broken" readings came from reusing minutes-old URLs |
| Responses served from local cache | `URLSessionTaskMetrics.resourceFetchType` on device | **No cache hits.** Fixed anyway — it is still wrong to cache a ranged request |
| HTTP connection reuse upsets googlevideo | 4 sequential ranges on one keep-alive connection | **Fine.** 4/4 × 206 |
| Concurrent video+audio to the same host | Parallel vs serialised pulls | **Fine** either way |
| Fetch the whole file in one request | `Range: bytes=0-<clen-1>` | **Refused**, all six formats. A 4 MB range *is* served, so the ceiling sits somewhere between 4 MB and whole-file — the `initialChunkSize` comment claiming "4MB and above are refused" is out of date. Chunking is unavoidable either way |
| Muxed progressive itag 18 | First chunk | **403 always** for this client. `FormatSelector`'s progressive fallback is a dead end if it ever triggers |

---

## The original open fault (2026-08-20): URLs are signed for the requesting IP — DISPROVEN 2026-09-11

Every googlevideo URL carries `ip=<public IP>` **inside its signed parameter list**:

```
ip      = 165.99.197.39          ← exactly the machine that made the /player call
sparams = expire,ei,ip,id,itag,source,requiressl,xpc,bui,spc,vprv,svpuc,mime,rqh
```

From a Mac on one stable IP, a single URL serves six 2 MB chunks without complaint.
The phone gets about one request per URL, then 403 — including a re-extracted URL,
which buys exactly one more chunk. From the device log:

```
19:42:25.792  response video code=206 at=0/9612434          ← 2 MB lands
19:42:25.816  response video code=403 at=2097152/9612434    ← 24 ms later, refused
19:42:29.239  response video code=206 at=2097152/9612434    ← fresh URL, one more chunk
19:42:29.265  response video code=403 at=2621440/9612434    ← and refused again
```

The hypothesis at the time was that the phone's public address moves between
requests. **This is now ruled out — see below.**

---

## 2026-09-11: the IP-rotation theory is dead. Here's what a live retest found instead.

Pulled a fresh `diagnostics.log` from a real download attempt on the phone.
`signedFor=110.76.128.191` was **identical** across the initial extraction and two
later mid-download re-extractions, several seconds apart. The phone's public IP is
not rotating. That kills the theory above outright.

What the same log actually shows is **flaky, not permanent**, refusals: the exact
same URL and byte offset can 403 and then 206 on a bare retry two seconds later,
with nothing else changed:

```
04:08:27.247  video 403 at=2097152   ← fails
04:08:29.305  video 206 at=2097152   ← same offset, same URL, succeeds 2s later
```

### Tried and ruled out this round

| Theory | Test | Verdict |
|---|---|---|
| Concurrent video+audio transfers compete/throttle each other | Serialized the two parts (`DownloadManager.swift` — `pendingParts` / `startNextPart`, one part at a time instead of both firing at once) and re-ran on device | **Wrong.** A single, unaccompanied video stream hit the identical wall |
| Retry budget too stingy, gives up before a transient refusal clears | Extended backoff ceiling 16s → 32s (`StreamFetcher.swift` retry loop) | Made no difference — the failure isn't about backoff length, see below |
| Wrong Innertube client identity for extraction (`ANDROID_VR`) | Wrote `client-probe.py`, ran the same extraction with `ANDROID_VR` from a **stable Mac connection**: 6 clean 2 MB chunks (12 MB) before any refusal — 4x further than the phone ever gets. `IOS`/`ANDROID` client payloads attempted too but got HTTP 400 (bad request shape, not investigated further since ANDROID_VR already proved not to be the bottleneck); `TVHTML5` came back `UNPLAYABLE` (needs a proof-of-origin token this app doesn't have) | **Wrong.** The client already in use works fine; it's not the limiting factor |
| Force HTTP/1.1, avoid the mid-transfer upgrade to HTTP/3 seen in the connection metrics | Checked the actual SDK header (`NSURLRequest.h`): the only public lever, `assumesHTTP3Capable`, only controls *speculative* H3 racing before the server confirms support, and **already defaults to `NO`**. There is no public iOS API to block the normal Alt-Svc-driven upgrade once a server advertises H3. Nothing to change or test | **Not implementable**, not merely untested |

### CORRECTION — the "Mac reaches 12MB, phone reaches 3MB" finding above was an artifact

That comparison used **two different formats without realizing it**: the phone's
download job requested itag 135 (480p), while the Mac's `client-probe.py` test
picked whatever "first avc1 adaptive format" it found, which was itag 137 (1080p).
Once re-tested on the same itag, the Mac gets refused at **exactly the same byte
offset the phone does.** Device, network path, background-vs-foreground session —
none of it matters. See the two rounds of testing below for what was actually
learned once this was caught.

### Round 2 — HTTP/3, tested properly and disproven

Hypothesis: `URLSession` auto-upgrades to HTTP/3 (confirmed via
`URLSessionTaskMetrics`, `proto=h3` on the very first request against
`rr2---sn-3noxufvg3-q5js.googlevideo.com`), and that upgrade is what breaks range
requests after the first chunk. Built a from-scratch HTTP/1.1-only fetcher
(`NWConnection` + TCP, TLS ALPN restricted to `http/1.1` via
`sec_protocol_options_add_tls_application_protocol` — HTTP/3 is UDP/QUIC so a TCP
transport rules it out by construction) to test it.

**Result: identical wall.** On itag 135 the raw fetcher, plain `URLSession`, and
Python's `urllib` all stop at byte 2,097,152. On itag 137 all three get to roughly
12.6MB. HTTP/3 is not the cause — the earlier "Mac wins" result was purely the itag
mismatch above. The raw-socket fetcher was deleted (never committed) once this
was clear; it added real complexity for zero benefit.

### Round 3 — real-time pacing, tested properly and disproven

Better-supported hypothesis at the time: the byte cap scales with each format's
bitrate (itag 135 stops at ~15s of playback-equivalent data, itag 137 at ~25s),
which is the signature of a token-bucket-style throttle that penalizes downloading
faster than real time. Tested by pacing chunk requests to exactly 1x the stream's
own bitrate (sleep `bytesReceived / bytesPerSecond - elapsedTime` before each
request) against a live URL, via `urllib` on the Mac.

**Result: identical wall, at the identical byte offset, despite correctly staying
paced to real time throughout.** Pacing does not help. This theory is wrong too —
the ~15–25s figures across two formats were likely coincidence from a two-point
sample, not a real relationship.

### Where this leaves things

Five independent, actually-tested theories are now ruled out: IP rotation, part
concurrency, wrong client identity, HTTP/3 negotiation, and real-time pacing.
Every one of them reproduces the exact same failure at the exact same byte offset
for a given format, regardless of device, session type, network stack, or request
timing. That consistency is itself informative — this is a deterministic
per-format-and-URL serving limit, not flakiness — but nothing tried today explains
*what* determines it or how to get past it.

**Not yet tried, because it needs different tooling than "iterate on the fetch
logic":** capture what a genuine YouTube client (the real Android/iOS app, or a
browser) actually does differently on the wire — e.g. via a MITM proxy — while
successfully streaming past this point on the same video. Real players send
periodic telemetry/QoS pings during playback (`api/stats/...`-style endpoints);
it's plausible the CDN ties continued serving of a stream to receiving those,
which nothing in this app currently sends. That's a hypothesis, not a finding —
it has not been tested.

Also fixed and kept regardless: parts now download serialized rather than racing
(`DownloadManager.swift` — `pendingParts`/`startNextPart`), and the retry backoff
ceiling is 32s instead of 16s (`StreamFetcher.swift`). Neither is harmful; neither
was sufficient on its own, and neither should be mistaken for progress on the real
issue.

The original options 1 and 2 several sections up (in-process download sharing one
connection pool; re-extract per chunk) remain unexplored and are still a product
decision, not a technical one — ask before building. Given today's results, treat
them as unproven rather than promising; nothing found today points at them
specifically.

---

## How to work on this

Device: Abraar's iPhone, `685CDD88-64C7-54FC-AE2B-57D90C28857F`.

```bash
# Build, install, launch (Release). Use `clean` — incremental builds have
# regenerated Assets.car *after* codesign, producing an "invalid code signature"
# launch failure that looks like a provisioning problem and is not.
xcodebuild -project CuratorStudio.xcodeproj -scheme CuratorStudio \
  -configuration Release -destination 'id=<DEVICE>' \
  -derivedDataPath /tmp/DD -allowProvisioningUpdates clean build
codesign --verify --strict /tmp/DD/Build/Products/Release-iphoneos/CuratorStudio.app
xcrun devicectl device install app --device <DEVICE> /tmp/DD/.../CuratorStudio.app
xcrun devicectl device process launch --device <DEVICE> --terminate-existing com.blankframe.curatorstudio
```

The phone must be **unlocked** to launch, and don't use `--console`: when that
session ends it kills the app.

```bash
# Pull the diagnostics log (survives crashes and relaunches; self-trims at 1 MB)
xcrun devicectl device copy from --device <DEVICE> \
  --domain-type appDataContainer --domain-identifier com.blankframe.curatorstudio \
  --user mobile --source "Library/Application Support/CuratorStudio/diagnostics.log" \
  --destination ./diagnostics.log

# Same mechanism reaches the queue state and the staging directory
#   Library/Application Support/CuratorStudio/downloads.json
#   Library/Application Support/CuratorStudio/Staging/
```

`Helper files/googlevideo-probe.py` does an `ANDROID_VR` extraction from the Mac and
fires range requests at the result — the fastest way to test a theory about the
service without a build/install/launch cycle. `python3 "Helper files/googlevideo-probe.py" <videoId>`.

`Helper files/client-probe.py` (added 2026-09-11) does the same but across several
Innertube client identities, and walks further into the file (up to 24 MB in 2 MB
steps) to compare how far each gets before being refused. `IOS` and `ANDROID` in
there currently 400 — their payload shape needs fixing before they say anything
useful. `TVHTML5` reaches the endpoint fine but comes back `UNPLAYABLE` (needs a
proof-of-origin token). Only `ANDROID_VR` actually returns a working stream right
now. `python3 "Helper files/client-probe.py" <videoId>`.

**Pitfall that cost real time on 2026-09-11: `client-probe.py` picks "the first
avc1 adaptive format" per client, which is not necessarily the same itag across
runs or across clients.** The byte cap where googlevideo starts refusing scales
with the format's bitrate (see the round-2/round-3 write-up above), so comparing
two runs that silently used different itags looks exactly like a real difference
between whatever you changed and isn't one. Pin the itag explicitly (see
`get_url.py`-style scripts, not currently checked in) before drawing any
conclusion from a "gets further" result.

### Notes for whoever picks this up

- **The library root is the app's own Documents folder**, already visible in Files
  (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`). Downloads target
  `Documents/Randoms`, which is empty because nothing has ever reached the import
  step. There is no missing "save to the filesystem" feature.
- `downloads.json` held ten jobs, all `failed`, none newer than the fixes. If a job
  seems to vanish from the queue, check that file before believing the UI — and note
  a `.cancelled` job renders in no section of `DownloadsScreen` at all.
- `Innertube.swift` says it is the first file to revisit when extraction breaks. That
  is still true, but extraction is *not* what is broken right now — `/player` returns
  `OK` with working URLs. The failure is downstream, in fetching them.
