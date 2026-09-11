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

### What's actually left standing

The phone reaches roughly **3 MB** into a stream before the wall becomes
unrecoverable (two independent restart-from-zero attempts, same session, both
stalled at exactly byte 3,145,728). The Mac, on the same client, same video, same
extraction method, reaches **12 MB**. Same request pattern, wildly different
outcome — so whatever is refusing these requests is reading something about the
*connection itself* (the phone's specific network path), not the client identity,
not concurrency, and not the signed IP.

Concretely testable next steps, in roughly cheapest-to-most-invasive order:

1. **Wi-Fi-only** (`allowsCellularAccess = false`). Low expectation — the phone's
   own connection logs already show `cellular=false` throughout, so it's already on
   Wi-Fi. Worth ruling out formally anyway since it's a one-line change.
2. **One persistent streamed connection** instead of discrete `Range`-chunked
   requests — i.e. actually behave like a real player pulling one continuous
   response rather than a chunk loop issuing a fresh request every 512KB–2MB. This
   is a materially different `StreamFetcher` design, not a tweak, and hasn't been
   tried at all yet.
3. The original options 1 and 2 from the superseded section above (in-process
   download sharing one connection pool; re-extract per chunk) are worth
   re-examining now that the *reason* they might help is different — not IP
   rotation, but whatever is specific to backgrounded/`nsurlsessiond`-managed
   transfers on this network path.

Also fixed and kept regardless of whether they turn out to matter: parts now
download serialized rather than racing (`DownloadManager.swift`), and the retry
backoff ceiling is 32s instead of 16s (`StreamFetcher.swift`). Neither is harmful;
neither was sufficient on its own.

Option 2 above (or resurrecting original options 1/2) is a product decision, not a
technical one. Ask before building.

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
