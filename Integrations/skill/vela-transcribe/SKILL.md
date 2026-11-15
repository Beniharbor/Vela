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
- Short reels take seconds, but a long YouTube video can take several minutes. Allow up to 30 minutes (`--max-time 1800`).
- If the connection is refused, Vela isn't running. Start it with `open -g -a Vela`, wait a few seconds and retry.
- An empty `text` with a `note` means the video has no speech (music only).

The transcript is speech only. Say so when visuals might matter: on-screen text, captions burned into the video, and what is shown are not included.
