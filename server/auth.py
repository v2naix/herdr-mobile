"""Local bearer token and short-lived browser sessions."""

import hashlib
import hmac
import os
import secrets
import time
from collections.abc import Callable
from pathlib import Path


def load_or_create_token(path: Path) -> str:
    if path.exists():
        if path.stat().st_mode & 0o077:
            raise PermissionError(f"token file must have mode 0600: {path}")
        token = path.read_text(encoding="utf-8").strip()
        if len(token) < 32:
            raise ValueError("token must contain at least 32 characters")
        return token
    path.parent.mkdir(parents=True, exist_ok=True)
    token = secrets.token_urlsafe(32)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(token + "\n")
    return token


class SessionStore:
    def __init__(
        self,
        bearer_token: str,
        ttl_seconds: int = 12 * 60 * 60,
        clock: Callable[[], float] = time.monotonic,
        max_sessions: int = 100,
    ):
        if max_sessions < 1:
            raise ValueError("max_sessions must be positive")
        self._token_hash = hashlib.sha256(bearer_token.encode()).digest()
        self._sessions: dict[str, float] = {}
        self._ttl = ttl_seconds
        self._clock = clock
        self._max_sessions = max_sessions

    def exchange(self, bearer_token: str) -> str | None:
        candidate = hashlib.sha256(bearer_token.encode()).digest()
        if not hmac.compare_digest(candidate, self._token_hash):
            return None
        now = self._clock()
        expired = [session for session, expires in self._sessions.items() if expires <= now]
        for session in expired:
            self._sessions.pop(session)
        while len(self._sessions) >= self._max_sessions:
            self._sessions.pop(next(iter(self._sessions)))
        session = secrets.token_urlsafe(32)
        self._sessions[session] = now + self._ttl
        return session

    def revoke(self, session: str | None) -> bool:
        if not session:
            return False
        return self._sessions.pop(session, None) is not None

    def valid(self, session: str | None) -> bool:
        if not session:
            return False
        expires = self._sessions.get(session)
        if expires is None or expires <= self._clock():
            self._sessions.pop(session, None)
            return False
        return True
