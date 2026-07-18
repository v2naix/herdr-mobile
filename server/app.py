"""FastAPI application for the tailnet-only herdr mobile UI."""

import asyncio
import json
import logging
import os
import time
from collections import deque
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Request, Response, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .auth import SessionStore, load_or_create_token
from .herdr import HerdrAdapter, HerdrError, SubprocessRunner
from .protocol import Action, ProtocolError, SendKeys, SendText, parse_command, validate_lines

ROOT = Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
COOKIE = "herdr_mobile_session"
MAX_WS_MESSAGE = 8 * 1024
MAX_CONNECTIONS = 8
RATE_COUNT = 30
RATE_WINDOW = 10.0

logger = logging.getLogger("herdr_mobile")


class ConnectionLimit:
    def __init__(self, maximum: int):
        self.maximum = maximum
        self.active = 0
        self.lock = asyncio.Lock()

    async def acquire(self) -> bool:
        async with self.lock:
            if self.active >= self.maximum:
                return False
            self.active += 1
            return True

    async def release(self) -> None:
        async with self.lock:
            self.active = max(0, self.active - 1)


def create_app(
    adapter: HerdrAdapter,
    sessions: SessionStore,
    allowed_origins: set[str],
    secure_cookie: bool = True,
    auth_enabled: bool = True,
) -> FastAPI:
    app = FastAPI(title="herdr-mobile", docs_url=None, redoc_url=None, openapi_url=None)
    limit = ConnectionLimit(MAX_CONNECTIONS)
    session_attempts: deque[float] = deque()

    @app.middleware("http")
    async def security_headers(request: Request, call_next):
        response = await call_next(request)
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; "
            "connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
        )
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/healthz")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    def exchange_bearer(request: Request, audience: str) -> str:
        now = time.monotonic()
        while session_attempts and session_attempts[0] <= now - 60.0:
            session_attempts.popleft()
        if len(session_attempts) >= 10:
            raise HTTPException(429, "too many authentication attempts")
        session_attempts.append(now)
        if not auth_enabled:
            return sessions.issue(audience)
        authorization = request.headers.get("authorization", "")
        if not authorization.startswith("Bearer "):
            raise HTTPException(401, "bearer token required")
        session = sessions.exchange(authorization[7:], audience)
        if session is None:
            logger.warning(json.dumps({"event": "auth_failed", "audience": audience}))
            raise HTTPException(401, "invalid bearer token")
        return session

    @app.post("/api/session", status_code=204)
    async def exchange_session(request: Request, response: Response) -> None:
        if request.headers.get("origin") not in allowed_origins:
            raise HTTPException(403, "origin rejected")
        if not auth_enabled:
            return
        session = exchange_bearer(request, "browser")
        response.set_cookie(
            COOKIE, session, httponly=True, secure=secure_cookie, samesite="strict",
            max_age=sessions.ttl_seconds, path="/",
        )

    @app.post("/api/native/session")
    async def exchange_native_session(request: Request) -> dict[str, str | int]:
        session = exchange_bearer(request, "native")
        return {"token": session, "expires_in": sessions.ttl_seconds}

    @app.delete("/api/native/session", status_code=204)
    async def revoke_native_session(request: Request) -> None:
        authorization = request.headers.get("authorization", "")
        if not authorization.startswith("Bearer "):
            raise HTTPException(401, "native bearer token required")
        if auth_enabled and not sessions.revoke(authorization[7:], "native"):
            raise HTTPException(401, "invalid native session")

    @app.post("/api/logout", status_code=204)
    async def logout(request: Request, response: Response) -> None:
        if request.headers.get("origin") not in allowed_origins:
            raise HTTPException(403, "origin rejected")
        if auth_enabled:
            sessions.revoke(request.cookies.get(COOKIE), "browser")
        response.delete_cookie(
            COOKIE, httponly=True, secure=secure_cookie, samesite="strict", path="/"
        )

    @app.websocket("/ws")
    async def websocket_endpoint(ws: WebSocket) -> None:
        origin = ws.headers.get("origin")
        if origin not in allowed_origins:
            await ws.close(code=1008, reason="origin rejected")
            return
        await ws.accept()
        if auth_enabled and not sessions.valid(ws.cookies.get(COOKIE), "browser"):
            await ws.close(code=1008, reason="authentication required")
            return
        if not await limit.acquire():
            await ws.close(code=1013, reason="too many connections")
            return
        logger.info(json.dumps({"event": "ws_connected", "active": limit.active}))
        try:
            await _serve_socket(ws, adapter)
        finally:
            await limit.release()
            logger.info(json.dumps({"event": "ws_disconnected", "active": limit.active}))

    @app.get("/")
    async def index() -> FileResponse:
        return FileResponse(WEB / "index.html")

    @app.get("/sw.js")
    async def service_worker() -> FileResponse:
        return FileResponse(WEB / "sw.js", media_type="application/javascript")

    app.mount("/static", StaticFiles(directory=WEB), name="static")
    return app


async def _serve_socket(ws: WebSocket, adapter: HerdrAdapter) -> None:
    selected: tuple[str, str, int] | None = None
    recent: deque[float] = deque()
    last_snapshot = ""
    last_output = ""
    while True:
        try:
            text = await asyncio.wait_for(ws.receive_text(), timeout=2.0)
        except TimeoutError:
            text = None
        except WebSocketDisconnect:
            return
        now = time.monotonic()
        if text is not None:
            if len(text.encode("utf-8")) > MAX_WS_MESSAGE:
                await ws.close(code=1009, reason="message too large")
                return
            while recent and recent[0] <= now - RATE_WINDOW:
                recent.popleft()
            if len(recent) >= RATE_COUNT:
                await ws.send_json({"type": "error", "error": "rate limit exceeded"})
                continue
            recent.append(now)
            try:
                data = json.loads(text)
                if isinstance(data, dict) and data.get("type") == "subscribe":
                    if set(data) != {"type", "pane_id", "pane_ref", "lines"}:
                        raise ProtocolError("invalid subscribe command")
                    pane_id, pane_ref = data["pane_id"], data["pane_ref"]
                    if (
                        not isinstance(pane_id, str) or not 1 <= len(pane_id) <= 64
                        or not isinstance(pane_ref, str) or not 1 <= len(pane_ref) <= 128
                    ):
                        raise ProtocolError("invalid pane identity")
                    selected = (pane_id, pane_ref, validate_lines(data["lines"]))
                    last_output = ""
                else:
                    command = parse_command(data)
                    if isinstance(command, SendText):
                        await adapter.send_text(command.pane_id, command.pane_ref, command.text)
                    elif isinstance(command, SendKeys):
                        await adapter.send_keys(command.pane_id, command.pane_ref, command.keys)
                    elif isinstance(command, Action):
                        await adapter.action(command.pane_id, command.pane_ref, command.action)
                    await ws.send_json({"type": "ack", "command": data.get("type")})
            except (json.JSONDecodeError, ProtocolError, HerdrError, KeyError) as error:
                await ws.send_json({"type": "error", "error": str(error)})
        try:
            panes = await adapter.list_panes()
            serialized = json.dumps(panes, sort_keys=True)
            if serialized != last_snapshot:
                await ws.send_json({"type": "snapshot", "panes": panes})
                last_snapshot = serialized
            if selected:
                output = await adapter.read(*selected)
                if output != last_output:
                    await ws.send_json({"type": "output", "pane_id": selected[0], "text": output})
                    last_output = output
        except HerdrError as error:
            await ws.send_json({"type": "error", "error": str(error)})


def default_app() -> FastAPI:
    token_path = Path(os.environ.get("HERDR_MOBILE_TOKEN_FILE", ROOT / ".herdr-mobile-token"))
    token = os.environ.get("HERDR_MOBILE_TOKEN") or load_or_create_token(token_path)
    if len(token) < 32:
        raise ValueError("HERDR_MOBILE_TOKEN must contain at least 32 characters")
    origins = {
        item.strip().rstrip("/")
        for item in os.environ.get(
            "HERDR_MOBILE_ALLOWED_ORIGINS", "http://127.0.0.1:8787,http://localhost:8787"
        ).split(",") if item.strip()
    }
    return create_app(
        HerdrAdapter(SubprocessRunner()), SessionStore(token), origins,
        secure_cookie=os.environ.get("HERDR_MOBILE_COOKIE_SECURE", "1") != "0",
        auth_enabled=os.environ.get("HERDR_MOBILE_AUTH", "1") != "0",
    )


app = default_app()
