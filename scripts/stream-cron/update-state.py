#!/usr/bin/env python3
"""Write site/state.json — the pointer the site reads to pick its director-cam embed.

Modes:
  live    -> the site shows the channel's current live stream (live_stream?channel=…)
  replay  -> the site loops a specific archived match; this fetches the channel's most
             recent COMPLETED live stream via the YouTube Data API (read-only, YT_API_KEY).

Usage:
  update-state.py --mode live   --channel UC... [--out site/state.json]
  update-state.py --mode replay --channel UC... [--out site/state.json]   # needs YT_API_KEY

Robustness: on replay, if the API returns nothing AND there's no previous videoId to fall
back on, it writes mode=live instead of a blank replay — the site never breaks to an empty
embed. stdlib only (urllib), so it runs on a bare GitHub Actions runner with no pip installs.
"""
import argparse
import json
import os
import sys
import urllib.parse
import urllib.request


def latest_completed_video(channel, api_key):
    """Return the videoId of the channel's most recent finished live stream, or None."""
    q = urllib.parse.urlencode({
        "part": "snippet",
        "channelId": channel,
        "eventType": "completed",
        "type": "video",
        "order": "date",
        "maxResults": 1,
        "key": api_key,
    })
    url = "https://www.googleapis.com/youtube/v3/search?" + q
    with urllib.request.urlopen(url, timeout=30) as resp:
        data = json.load(resp)
    items = data.get("items") or []
    if not items:
        return None
    return items[0]["id"]["videoId"]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mode", required=True, choices=["live", "replay"])
    ap.add_argument("--channel", required=True, help="YouTube channel id (UC…)")
    ap.add_argument("--out", default="site/state.json")
    args = ap.parse_args()

    state = {"mode": args.mode, "channelId": args.channel, "videoId": ""}

    # Preserve any existing videoId so a transient API miss can fall back to the last match.
    try:
        with open(args.out) as f:
            prev = json.load(f)
        if isinstance(prev, dict):
            state["videoId"] = prev.get("videoId", "") or ""
    except (OSError, ValueError):
        pass

    if args.mode == "replay":
        key = os.environ.get("YT_API_KEY")
        if not key:
            print("ERROR: YT_API_KEY not set (required for replay)", file=sys.stderr)
            sys.exit(1)
        vid = None
        try:
            vid = latest_completed_video(args.channel, key)
        except Exception as exc:  # network / API error -> fall back to previous id
            print("WARN: YouTube API lookup failed: %s" % exc, file=sys.stderr)
        if vid:
            state["videoId"] = vid
        elif not state["videoId"]:
            # No archived match to show and nothing cached — stay live rather than
            # publish a blank replay embed.
            print("WARN: no completed stream and no cached videoId; writing mode=live",
                  file=sys.stderr)
            state["mode"] = "live"

    with open(args.out, "w") as f:
        json.dump(state, f, indent=2)
        f.write("\n")
    print("wrote %s: %s" % (args.out, json.dumps(state)))


if __name__ == "__main__":
    main()
