# Daily 3-hour stream + library-fed site

Run the GPU box ~3 hours a day instead of 24/7 (~80% GPU cost cut). The box streams a
live match during its window; YouTube auto-archives every stream into the channel library.
The rest of the day the site loops the latest archived match. Nothing to record or upload —
YouTube is the archive.

## Pieces

### A. Site playback (`site/`)
`index.html` reads `site/state.json` at load and chooses its director-cam embed:

```json
{ "mode": "live" | "replay", "channelId": "UC…", "videoId": "…" }
```

- `live`   → `embed/live_stream?channel=<channelId>` (whatever is currently live)
- `replay` → `embed/<videoId>?loop=1&playlist=<videoId>` (that archived match, looped)

If `state.json` can't be read, the hardcoded live embed stays (safe default). Fully static —
Netlify/Vercel just serves the files; no serverless, no browser API calls.

### B. Daily orchestration (`.github/workflows/`)
Two scheduled GitHub Actions (free — public repo). Each also has a manual "Run workflow"
button (`workflow_dispatch`).

- **`stream-start.yml`** — `vastai start instance` (box boots → pm2 auto-runs war+stream →
  goes live) → write `state.json` `mode:live` → commit/push → site shows live.
- **`stream-stop.yml`** — look up the channel's most recent completed stream via the YouTube
  Data API → write `state.json` `mode:replay` + that `videoId` → commit/push → `vastai stop
  instance`. Site is flipped to the archive *before* the box stops.

`scripts/stream-cron/update-state.py` does the YouTube lookup + writes `state.json` (stdlib
only). It never publishes a blank replay: if no completed stream exists and there's no cached
`videoId`, it writes `mode:live` instead.

## Required repo config

Secrets (Settings → Secrets and variables → Actions → **Secrets**):

| Secret | Value |
|---|---|
| `VAST_API_KEY` | Vast.ai API key |
| `YT_API_KEY` | YouTube Data API v3 key (read-only) |

Variables (same page → **Variables**):

| Variable | Value |
|---|---|
| `VAST_INSTANCE_ID` | `45096377` |
| `YT_CHANNEL_ID` | `UCTZ2PNoiJvryW6s47uKFTog` |

**You must add these by hand** in the GitHub UI (repo → Settings → Secrets and variables →
Actions). The assistant's token can't write repo secrets, and entering your own keys in the UI
is the safer path anyway. The `YT_CHANNEL_ID` is `UCTZ2PNoiJvryW6s47uKFTog` and
`VAST_INSTANCE_ID` is `45096377`; the two keys are the values you already hold.

## Activation (do this to turn it on)

1. **Merge this branch to the default branch (`master`).** Scheduled workflows only fire from
   the default branch — until merged, nothing runs automatically (safe to review first).
2. **Point Netlify/Vercel at `master`.** The workflows commit `state.json` to the branch they
   run on (the default branch). The site must deploy from that same branch so the redeploy
   picks up the new `state.json`. (Today the site file lives on `pump/bam-solana`; this branch
   brings it onto `master` as the single source of truth.)
3. **Set the schedule.** Edit the two `cron:` lines to your window (they're `17:00`/`20:00`
   UTC placeholders = a 3-hour window). Cron is UTC.

## First run / testing

- **Test the site swap without touching the box:** run `stream-stop`'s state step logic
  locally — `YT_API_KEY=… python3 scripts/stream-cron/update-state.py --mode replay --channel
  UCTZ2PNoiJvryW6s47uKFTog` — and open `site/index.html`; it should load the latest match on
  loop.
- **Test the box lifecycle:** trigger `stream-start` manually (no-op if already running), then
  later `stream-stop` manually. `stream-stop` WILL stop the box and end the live stream — only
  run it when you're ready for the box to go down.

## Notes / edge cases

- **Archive lag:** a 3-hour stream takes a while for YouTube to finalize into a seekable VOD.
  `stream-stop` intentionally uses `eventType=completed`, so if today's isn't finalized yet it
  shows the previous fully-processed match rather than a "processing" video — always playable,
  at most a day behind on the worst day.
- **Box persistence:** `stop` (not `destroy`) preserves the container filesystem, so `start`
  brings the whole install back and pm2 resurrects war+stream on boot (verified). Never wire
  `destroy` into the schedule or you'd re-deploy the ~2 GB install every morning.
- **AI override reminder:** the CircuitAI commitment override lives in the (gitignored) engine
  dir and is NOT reapplied by a rebuild — only `stop`/`start` (which preserves the fs) keeps it.
  A `recycle`/`destroy` would drop it.
