#!/usr/bin/env python3
"""Vela MCP server: transcribe YouTube videos, Instagram reels, TikToks, etc.

Thin bridge to Vela's local API (127.0.0.1:47821, see
Sources/Vela/LocalAPIServer.swift). Vela downloads the audio with yt-dlp and
transcribes it with its Whisper model (auto-detects English / Spanish / …).

Standard library only, Python 3.9+. MCP over stdio, JSON-RPC 2.0, one message
per line.

CLI test:  python3 vela_mcp.py --cli "https://www.youtube.com/watch?v=..."
"""

from __future__ import annotations

import asyncio
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request

VELA = "http://127.0.0.1:47821"
TIMEOUT_SECONDS = 1800  # long videos can take several minutes


def _http(method: str, path: str, body: dict | None = None, timeout: float = 5) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        VELA + path, data=data, method=method,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read())
        except Exception:
            return {"error": f"HTTP {e.code}"}


def _ensure_vela() -> None:
    """Make sure Vela is running; launch it in the background if not."""
    try:
        _http("GET", "/health")
        return
    except Exception:
        pass
    subprocess.run(["open", "-g", "-a", "Vela"], check=False)
    for _ in range(30):
        time.sleep(1)
        try:
            _http("GET", "/health")
            return
        except Exception:
            continue
    raise RuntimeError("Vela is not running and could not be launched. Open /Applications/Vela.app.")


def transcribe_sync(url: str, language: str = "auto") -> str:
    _ensure_vela()
    result = _http("POST", "/transcribe", {"url": url, "language": language}, timeout=TIMEOUT_SECONDS)
    if "error" in result:
        raise RuntimeError(result["error"])
    header = []
    if result.get("title"):
        header.append(f"Title: {result['title']}")
    header.append(f"Language: {result.get('language', '?')} · Duration: {result.get('durationSeconds', '?')}s")
    if result.get("note"):
        header.append(f"Note: {result['note']}")
    return "\n".join(header) + "\n\nTranscript:\n" + (result.get("text") or "")


TOOL = {
    "name": "transcribe_video",
    "description": (
        "Get the spoken transcript of a video you cannot watch: YouTube videos, "
        "Instagram reels, TikToks, X/Twitter videos, or any link yt-dlp supports. "
        "Returns title, detected language, duration and the full transcript. "
        "Runs locally on this Mac via Vela; long videos may take a few minutes."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "url": {"type": "string", "description": "Link to the video or reel"},
            "language": {
                "type": "string",
                "description": "Spoken language code (e.g. 'en', 'es'). Default 'auto' detects it.",
            },
        },
        "required": ["url"],
    },
}


async def handle_request(request: dict) -> dict | None:
    method = request.get("method")
    req_id = request.get("id")
    params = request.get("params") or {}

    if method == "initialize":
        return {
            "jsonrpc": "2.0", "id": req_id,
            "result": {
                "protocolVersion": params.get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "vela", "version": "1.0.0"},
            },
        }
    if req_id is None:  # notifications get no reply
        return None
    if method == "ping":
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}
    if method == "tools/list":
        return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": [TOOL]}}
    if method == "tools/call":
        if params.get("name") != "transcribe_video":
            return {"jsonrpc": "2.0", "id": req_id,
                    "error": {"code": -32602, "message": f"Unknown tool: {params.get('name')}"}}
        args = params.get("arguments") or {}
        try:
            text = await asyncio.to_thread(transcribe_sync, args["url"], args.get("language", "auto"))
            return {"jsonrpc": "2.0", "id": req_id,
                    "result": {"content": [{"type": "text", "text": text}]}}
        except Exception as e:
            return {"jsonrpc": "2.0", "id": req_id,
                    "result": {"content": [{"type": "text", "text": f"Error: {e}"}], "isError": True}}
    return {"jsonrpc": "2.0", "id": req_id,
            "error": {"code": -32601, "message": f"Unknown method: {method}"}}


async def serve() -> None:
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=16 * 1024 * 1024)
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    write_lock = asyncio.Lock()
    tasks = set()

    async def run(request: dict) -> None:
        response = await handle_request(request)
        if response is not None:
            async with write_lock:
                sys.stdout.write(json.dumps(response) + "\n")
                sys.stdout.flush()

    # Each request is its own task so a long transcription doesn't block pings.
    while True:
        line = await reader.readline()
        if not line:
            break
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        task = asyncio.create_task(run(request))
        tasks.add(task)
        task.add_done_callback(tasks.discard)
    if tasks:  # stdin closed: finish in-flight calls before exiting
        await asyncio.gather(*tasks)


if __name__ == "__main__":
    if "--cli" in sys.argv:
        print(transcribe_sync(sys.argv[sys.argv.index("--cli") + 1]))
    else:
        asyncio.run(serve())
