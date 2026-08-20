# Handover — downloads that never land

**Status: open.** As of 2026-08-20 no download has yet reached the library. Several
real bugs were found and fixed along the way; the one still standing is in the last
section, along with the decision it needs.

Everything below was verified against the live service or read out of the phone's
own log. Where something is still a theory it says so.

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

## The open fault: URLs are signed for the requesting IP

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

**Hypothesis:** the phone's public address moves between requests — carrier NAT
handing out a different egress IP per connection, or the `/player` call (foreground
`URLSession.shared`) and the media transfers (background session, run by the
`nsurlsessiond` daemon) leaving on different interfaces. A URL signed for address A
is refused the moment a request arrives from address B.

**Not yet proven.** The build on the phone right now logs the two things that settle it:

- `signedFor=<ip>` at every extraction and re-extraction (`StreamFetcher.swift:399`,
  `DownloadManager.swift:613`). If that value changes between two calls seconds
  apart, the public IP is rotating and the hypothesis is confirmed.
- Per-request connection metrics (`StreamFetcher.swift:509`): `cellular=`, `proxy=`,
  `reused=`, local and remote address, protocol. Shows whether media requests leave
  on a different interface than the API calls.

**Next step: run one download, pull the log, read those two lines.**

### If it is confirmed

The fix is structural, not another header. Options, worst to best understood:

1. **Download in-process instead of via the background session**, so extraction and
   transfer share one connection pool and NAT mapping. Costs the stated design goal
   — "transfers keep going when you leave the app" — and doesn't help if the carrier
   rotates IP per connection regardless.
2. **Re-extract per chunk.** Correct-ish but absurd: a `/player` round trip per 2 MB,
   and still no guarantee the two sessions share an egress IP.
3. **Pin the network interface** (`allowsCellularAccess = false` to force Wi-Fi).
   Cheap to try, worth measuring — but it makes cellular downloads impossible.
4. **Ask for the biggest range the service allows** (~3 MB) to minimise the number of
   coin flips. Mitigation, not a fix.

Option 1 vs 3 is a product decision, not a technical one. Ask before building.

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
