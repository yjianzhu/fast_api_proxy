#!/bin/bash
set -e

log() { printf '[bootstrap] %s\n' "$*"; }

if [ -z "$TUNNEL_TOKEN" ]; then
  log "TUNNEL_TOKEN not set in env"
  exit 1
fi
HOSTNAME='mimo.yjianzhu.us.ci'
PROXY_KEY_ENV='MIMO_PROXY_KEY'
MIMO_PROXY_KEY='sk-2d3ee225988de22acc49176733e4276d540cff16eeae33e561c1375f9737f86b'
export MIMO_PROXY_KEY
log "proxy access key env: $PROXY_KEY_ENV"

log "install cloudflared via apt repo"
if ! command -v cloudflared >/dev/null 2>&1; then
  sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    | sudo tee /etc/apt/sources.list.d/cloudflared.list
  sudo apt-get update
  sudo apt-get install -y cloudflared
fi
log "cloudflared: $(command -v cloudflared)"

log "write proxy.py (heredoc, no base64)"
cat > /tmp/proxy.py <<'PYEOF'
"""claw 沙箱内跑的 OpenAI 兼容反代。

从 $MIMO_API_KEY 读 key, 转发到 api-oc.xiaomimimo.com。
每次请求实时读 env, key 轮换时无需重启。
"""

from __future__ import annotations

import asyncio
import hmac
import json
import os

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse

UPSTREAM = "https://api-sgp-oc.xiaomimimo.com"
KEY_ENV = "MIMO_API_KEY"
PROXY_KEY_ENV = "MIMO_PROXY_KEY"
MAX_CONCURRENCY = 4
CONNECT_TIMEOUT = 10.0
READ_TIMEOUT = 600.0

FORBIDDEN_FIELDS = {
    "conversation_id",
    "parent_message_id",
    "session_token",
    "user_id",
    "request_id",
    "trace_id",
}

STRIP_RESP_HEADERS = {"content-encoding", "content-length", "transfer-encoding", "connection"}

app = FastAPI(title="mimo-proxy")
sem = asyncio.Semaphore(MAX_CONCURRENCY)


def _sanitize_body(body: bytes, content_type: str) -> bytes:
    if not body or not content_type.startswith("application/json"):
        return body
    try:
        data = json.loads(body)
    except Exception:
        return body
    if not isinstance(data, dict):
        return body
    for f in FORBIDDEN_FIELDS:
        data.pop(f, None)
    return json.dumps(data, ensure_ascii=False).encode()


@app.get("/healthz")
async def healthz() -> JSONResponse:
    key = os.environ.get(KEY_ENV)
    if not key:
        return JSONResponse({"status": "no_key"}, status_code=503)
    return JSONResponse({"status": "ok", "key_len": len(key)})


ALLOWED_PREFIXES = {"v1", "anthropic"}


def _require_proxy_key(request: Request) -> None:
    proxy_key = os.environ.get(PROXY_KEY_ENV)
    if not proxy_key:
        raise HTTPException(503, "MIMO_PROXY_KEY not set in env")

    auth = request.headers.get("authorization", "")
    scheme, _, token = auth.partition(" ")
    if scheme.lower() != "bearer" or not hmac.compare_digest(token, proxy_key):
        raise HTTPException(401, "Invalid proxy key")


@app.api_route("/{prefix}/{path:path}", methods=["GET", "POST", "OPTIONS"])
async def proxy(prefix: str, path: str, request: Request):
    if prefix not in ALLOWED_PREFIXES:
        raise HTTPException(404, "Not Found")

    _require_proxy_key(request)

    key = os.environ.get(KEY_ENV)
    if not key:
        raise HTTPException(503, "MIMO_API_KEY not set in env")

    raw = await request.body()
    content_type = request.headers.get("content-type", "application/json")
    body = _sanitize_body(raw, content_type)

    is_stream = False
    if body and b'"stream"' in body:
        try:
            parsed = json.loads(body)
            is_stream = bool(parsed.get("stream"))
        except Exception:
            pass

    upstream_headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": content_type,
        "Accept": request.headers.get("accept", "*/*"),
        "User-Agent": request.headers.get("user-agent", "mimo-proxy/1.0"),
    }

    async with sem:
        client = httpx.AsyncClient(
            timeout=httpx.Timeout(READ_TIMEOUT, connect=CONNECT_TIMEOUT)
        )
        req = client.build_request(
            request.method,
            f"{UPSTREAM}/{prefix}/{path}",
            headers=upstream_headers,
            content=body,
        )
        upstream = await client.send(req, stream=True)

        resp_headers = {
            k: v for k, v in upstream.headers.items() if k.lower() not in STRIP_RESP_HEADERS
        }

        async def iterator():
            try:
                async for chunk in upstream.aiter_bytes():
                    yield chunk
            finally:
                await upstream.aclose()
                await client.aclose()

        return StreamingResponse(
            iterator(),
            status_code=upstream.status_code,
            headers=resp_headers,
            media_type=upstream.headers.get("content-type"),
        )
PYEOF

log "install python deps"
pip install --break-system-packages --quiet --no-input fastapi uvicorn httpx 2>&1 | tail -3 || {
  log "pip install failed"
  exit 1
}

log "stop old processes"
pkill -f "uvicorn.*proxy:app" 2>/dev/null || true
sudo systemctl stop cloudflared 2>/dev/null || true
sudo cloudflared service uninstall 2>/dev/null || true
sleep 1

log "start proxy on :8080"
nohup python3 -m uvicorn --app-dir /tmp proxy:app \
  --host 127.0.0.1 --port 8080 --log-level warning \
  > /tmp/proxy.log 2>&1 &
PROXY_PID=$!
log "proxy pid: $PROXY_PID"

log "wait for local proxy health"
for i in $(seq 1 20); do
  if curl -sf http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    log "local proxy healthy"
    break
  fi
  sleep 1
done

log "install + start cloudflared as systemd service"
sudo cloudflared service install "$TUNNEL_TOKEN"
sudo systemctl start cloudflared 2>/dev/null || true

log "wait for tunnel up"
for i in $(seq 1 40); do
  if sudo systemctl is-active --quiet cloudflared 2>/dev/null; then
    if curl -sf "https://${HOSTNAME}/healthz" >/dev/null 2>&1; then
      log "tunnel + external healthz ok"
      break
    fi
  fi
  sleep 2
done

log "bootstrap ok"
