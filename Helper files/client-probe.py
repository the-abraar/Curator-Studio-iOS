#!/usr/bin/env python3
"""Compare how far different Innertube client identities let a range-chunked
download get before googlevideo starts refusing it, run from a stable Mac
connection (no phone NAT/cellular variables in the way).

python3 client-probe.py [videoId]
"""

import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

UA_WEB = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
          "(KHTML, like Gecko) Version/18.0 Safari/605.1.15")

CLIENTS = {
    "ANDROID_VR": dict(
        clientName="ANDROID_VR", clientVersion="1.65.10", clientID="28",
        userAgent=("com.google.android.apps.youtube.vr.oculus/1.65.10 "
                   "(Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"),
        extra={"deviceMake": "Oculus", "deviceModel": "Quest 3", "osName": "Android",
               "osVersion": "12L", "androidSdkVersion": 32, "timeZone": "UTC",
               "utcOffsetMinutes": 0},
    ),
    "IOS": dict(
        clientName="IOS", clientVersion="19.45.4", clientID="5",
        userAgent="com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X;)",
        extra={"deviceMake": "Apple", "deviceModel": "iPhone16,2",
               "osName": "iPhone", "osVersion": "17.5.1.21F90"},
    ),
    "ANDROID": dict(
        clientName="ANDROID", clientVersion="19.44.38", clientID="3",
        userAgent="com.google.android.youtube/19.44.38 (Linux; U; Android 14) gzip",
        extra={"androidSdkVersion": 34, "osName": "Android", "osVersion": "14"},
    ),
    "TVHTML5": dict(
        clientName="TVHTML5", clientVersion="7.20240101.00.00", clientID="7",
        userAgent="Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
        extra={},
    ),
}


def visitor_data():
    req = urllib.request.Request("https://www.youtube.com/", headers={"User-Agent": UA_WEB})
    html = urllib.request.urlopen(req, timeout=30).read().decode("utf8", "ignore")
    raw = re.search(r'"visitorData":"(.*?)"', html).group(1)
    return raw.replace("\\u003d", "=").replace("\\u0026", "&").replace("\\/", "/")


def player(video_id, vd, spec):
    client = {
        "clientName": spec["clientName"], "clientVersion": spec["clientVersion"],
        "hl": "en", "gl": "US", "userAgent": spec["userAgent"], "visitorData": vd,
    }
    client.update(spec["extra"])
    payload = {
        "context": {"client": client},
        "videoId": video_id, "contentCheckOk": True, "racyCheckOk": True,
        "playbackContext": {"contentPlaybackContext": {"html5Preference": "HTML5_PREF_WANTS"}},
    }
    req = urllib.request.Request(
        "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "User-Agent": spec["userAgent"],
                 "Origin": "https://www.youtube.com", "X-Youtube-Client-Name": spec["clientID"],
                 "X-Youtube-Client-Version": spec["clientVersion"], "X-Goog-Visitor-Id": vd})
    return json.load(urllib.request.urlopen(req, timeout=30))


def fetch(url, byte_range, ua):
    headers = {"User-Agent": ua, "Accept": "*/*", "Accept-Encoding": "identity"}
    if byte_range:
        headers["Range"] = byte_range
    try:
        r = urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60)
        return f"{r.status}({len(r.read())}b)"
    except urllib.error.HTTPError as e:
        return str(e.code)
    except Exception as e:                                  # noqa: BLE001
        return type(e).__name__


def main():
    video_id = sys.argv[1] if len(sys.argv) > 1 else "El6B0gKoo-A"
    # Pin one itag across every client tested. The byte cap where googlevideo starts
    # refusing scales with a format's bitrate (see Handover.md, 2026-09-11 round 2/3) — comparing
    # two clients that silently landed on different itags looks exactly like a real difference
    # between them and isn't one. 135 (480p avc1) is a safe default: small enough to hit its wall
    # in a few requests, common enough that every client should offer it.
    target_itag = int(sys.argv[2]) if len(sys.argv) > 2 else 135
    vd = visitor_data()

    for name, spec in CLIENTS.items():
        print(f"\n=== {name} ===")
        try:
            data = player(video_id, vd, spec)
        except Exception as e:
            print(f"  request failed: {e}")
            continue
        status = data.get("playabilityStatus", {}).get("status")
        print(f"  playability={status}")
        if status != "OK":
            reason = data.get("playabilityStatus", {}).get("reason")
            print(f"  reason={reason}")
            continue

        streaming = data.get("streamingData", {})
        adaptive = streaming.get("adaptiveFormats", [])
        video = next((f for f in adaptive if f.get("itag") == target_itag and f.get("url")), None)
        if not video:
            video = next((f for f in adaptive if "avc1" in f.get("mimeType", "") and f.get("url")), None)
            if video:
                print(f"  itag {target_itag} not offered by this client — falling back to "
                      f"itag {video['itag']}; byte-cap comparisons against other clients are NOT valid")
        if not video:
            print("  no direct-url avc1 adaptive format (ciphered signature?)")
            continue

        clen = int(video.get("contentLength", 0) or 0)
        print(f"  itag={video['itag']} len={clen} mime={video.get('mimeType','')[:40]}")

        # Walk up to 24MB in 2MB steps on ONE url, from a stable Mac connection.
        steps = 12
        codes = []
        for i in range(steps):
            start, end = i * 2097152, (i + 1) * 2097152 - 1
            code = fetch(video["url"], f"bytes={start}-{end}", spec["userAgent"])
            codes.append(code)
            if not code.startswith("206") and not code.startswith("200"):
                break
        print("  sequential 2MB chunks: " + "  ".join(codes))


if __name__ == "__main__":
    sys.exit(main())
