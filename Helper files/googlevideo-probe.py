#!/usr/bin/env python3
"""Test what googlevideo will and won't serve, without a build/install/launch cycle.

Does the same ANDROID_VR /player extraction the app does, then fires range requests
at the URLs that come back and prints the status codes. Written while chasing
downloads that 403 partway through; kept because every theory about the service is
cheaper to test here than on the phone.

    python3 googlevideo-probe.py [videoId]

Findings so far, all reproducible:
  * `Range: bytes=0-`      → 403, always. Ranges must be closed.
  * `Range: bytes=0-<end>` → 206, reliably, for every adaptive format.
  * closed 4 MB range      → 206, so the size ceiling is higher than the code assumes.
  * whole-file range       → 403. The ceiling is somewhere between 4 MB and whole-file.
  * muxed itag 18          → 403, always, for this client.
  * the URL carries `ip=<public IP>` inside its signed `sparams`, so a request from
    any other address is refused.
"""

import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

UA_VR = ("com.google.android.apps.youtube.vr.oculus/1.65.10 "
         "(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip")
UA_WEB = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
          "(KHTML, like Gecko) Version/18.0 Safari/605.1.15")
HEADERS = {"User-Agent": UA_VR, "Accept": "*/*", "Accept-Encoding": "identity"}


def visitor_data():
    """The blob YouTube hands a real client. /player returns LOGIN_REQUIRED without it."""
    req = urllib.request.Request("https://www.youtube.com/", headers={"User-Agent": UA_WEB})
    html = urllib.request.urlopen(req, timeout=30).read().decode("utf8", "ignore")
    raw = re.search(r'"visitorData":"(.*?)"', html).group(1)
    return raw.replace("\\u003d", "=").replace("\\u0026", "&").replace("\\/", "/")


def player(video_id, vd):
    payload = {
        "context": {"client": {
            "clientName": "ANDROID_VR", "clientVersion": "1.65.10", "hl": "en", "gl": "US",
            "userAgent": UA_VR, "deviceMake": "Oculus", "deviceModel": "Quest 3",
            "osName": "Android", "osVersion": "12L", "androidSdkVersion": 32,
            "timeZone": "UTC", "utcOffsetMinutes": 0, "visitorData": vd}},
        "videoId": video_id, "contentCheckOk": True, "racyCheckOk": True,
        "playbackContext": {"contentPlaybackContext": {"html5Preference": "HTML5_PREF_WANTS"}},
    }
    req = urllib.request.Request(
        "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": UA_VR,
                 "Origin": "https://www.youtube.com", "X-Youtube-Client-Name": "28",
                 "X-Youtube-Client-Version": "1.65.10", "X-Goog-Visitor-Id": vd})
    return json.load(urllib.request.urlopen(req, timeout=30))


def fetch(url, byte_range):
    """One range request. Returns a short printable result."""
    headers = dict(HEADERS)
    if byte_range:
        headers["Range"] = byte_range
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60)
        return f"{r.status} ({len(r.read())}b)"
    except urllib.error.HTTPError as e:
        return str(e.code)
    except Exception as e:                                  # noqa: BLE001 - diagnostics
        return type(e).__name__


def main():
    video_id = sys.argv[1] if len(sys.argv) > 1 else "El6B0gKoo-A"
    data = player(video_id, visitor_data())
    status = data.get("playabilityStatus", {}).get("status")
    print(f"{video_id}: playability={status}")
    if status != "OK":
        print(data.get("playabilityStatus"))
        return 1

    streaming = data["streamingData"]
    formats = [(f, True) for f in streaming.get("formats", [])] + \
              [(f, False) for f in streaming.get("adaptiveFormats", [])]

    # What address are these URLs signed for? A request from anywhere else is refused.
    first = next((f for f, _ in formats if f.get("url")), None)
    if first:
        q = urllib.parse.parse_qs(urllib.parse.urlparse(first["url"]).query)
        print(f"signed for ip={q.get('ip', ['?'])[0]}  (sparams: {q.get('sparams', ['?'])[0]})")

    print("\nfirst 256KB of each format:")
    for f, muxed in formats:
        if not f.get("url"):
            print(f"  itag {f.get('itag'):>4} — ciphered, no direct url")
            continue
        kind = "muxed" if muxed else "adaptive"
        print(f"  itag {f['itag']:>4} {kind:9s} {f.get('mimeType','')[:34]:36s} "
              f"len={str(f.get('contentLength','?')):>10} → {fetch(f['url'], 'bytes=0-262143')}")

    video = next((f for f, m in formats if not m and "avc1" in f.get("mimeType", "") and f.get("url")), None)
    if not video:
        return 0
    clen = int(video["contentLength"])
    print(f"\nrange shapes on itag {video['itag']} (len {clen}):")
    for label, rng in (("open-ended  bytes=0-", "bytes=0-"),
                       ("closed 256KB", "bytes=0-262143"),
                       ("closed 2MB", "bytes=0-2097151"),
                       ("closed 4MB", "bytes=0-4194303"),
                       ("whole file", f"bytes=0-{clen - 1}")):
        print(f"  {label:24s} → {fetch(video['url'], rng)}")

    print("\nsequential chunks on one URL (the phone gets ~one before 403):")
    codes = [fetch(video["url"], f"bytes={i * 2097152}-{(i + 1) * 2097152 - 1}") for i in range(4)]
    print("  " + "  ".join(codes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
