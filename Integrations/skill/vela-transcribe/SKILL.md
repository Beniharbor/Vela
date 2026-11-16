---
name: vela-transcribe
description: Get the spoken transcript of a YouTube video, Instagram reel, TikTok or any other video link, so you can understand a video you cannot watch. Use whenever the user sends a video or reel link, or asks what a video says.
---

# Transcribe a video with Vela

You can't watch videos, but Vela (a local app on this Mac) can turn a video link into text.

```bash
curl -s -X POST http://127.0.0.1:47821/transcribe \
  -H "Content-Type: application/json" \
  -d '{"url": "<VIDEO_URL>"}'
```

The JSON reply has `text` (the transcript), `title`, `language`, and `durationSeconds`. If something fails, the reply has `error` instead.

- Optional `"language": "es"` (or `"en"`, …) forces a language. The default auto-detects it.
- A local file works too: `{"path": "/path/to/video.mp4"}`.
- Short reels take seconds. For anything longer than a few minutes, use the async form below so the request can't time out.
- `warnings` lists any stretch of audio that had to be skipped; the rest of the transcript is still good.
- If the connection is refused, Vela isn't running. Start it with `open -g -a Vela`, wait a few seconds and retry.
- An empty `text` with a `note` means the video has no speech (music only).

## Long videos: submit, then poll

```bash
# 1. Submit. Replies at once with {"jobId": "...", "status": "queued"}
curl -s -X POST http://127.0.0.1:47821/transcribe \
  -H "Content-Type: application/json" \
  -d '{"url": "<VIDEO_URL>", "async": true}'

# 2. Poll every few seconds until "status" is "done" or "error"
curl -s http://127.0.0.1:47821/transcribe/<jobId>
```

While it works, the reply is `{"status": "running", "detail": "Transcribing…", "progress": 0.42}`. When `status` is `done`, the same reply carries `text`, `title`, `language` and `durationSeconds`. A 90-minute video takes several minutes; keep polling. Finished jobs are kept for 2 hours.

The transcript is speech only. Say so when visuals might matter: on-screen text, captions burned into the video, and what is shown are not included.
