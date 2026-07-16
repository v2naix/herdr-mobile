"""Strict client protocol validation."""

from dataclasses import dataclass
from typing import Any

MAX_TEXT_BYTES = 4096
MAX_TEXT_LINES = 20
MAX_READ_LINES = 300
ALLOWED_KEYS = frozenset({
    "Enter", "Tab", "Escape", "Up", "Down", "Left", "Right",
    "Ctrl+c", "Ctrl+l", "Ctrl+p", "Ctrl+o",
})
# always_allow stays disabled until its real pi dialog key sequence is verified.
ALLOWED_ACTIONS = frozenset({"approve_once", "deny"})


class ProtocolError(ValueError):
    pass


@dataclass(frozen=True)
class SendText:
    pane_id: str
    pane_ref: str
    text: str


@dataclass(frozen=True)
class SendKeys:
    pane_id: str
    pane_ref: str
    keys: tuple[str, ...]


@dataclass(frozen=True)
class Action:
    pane_id: str
    pane_ref: str
    action: str


def validate_lines(value: Any) -> int:
    if value is None:
        return 120
    if type(value) is not int:
        raise ProtocolError("lines must be an integer")
    return max(1, min(value, MAX_READ_LINES))


def _pane_id(value: Any) -> str:
    if not isinstance(value, str) or not value or len(value) > 64:
        raise ProtocolError("invalid pane_id")
    return value


def _pane_ref(value: Any) -> str:
    if not isinstance(value, str) or not value or len(value) > 128:
        raise ProtocolError("invalid pane_ref")
    return value


def _exact_fields(data: dict[str, Any], allowed: set[str]) -> None:
    if set(data) - allowed:
        raise ProtocolError("unknown field")


def parse_command(data: Any) -> SendText | SendKeys | Action:
    if not isinstance(data, dict):
        raise ProtocolError("command must be an object")
    kind = data.get("type")
    pane_id = _pane_id(data.get("pane_id"))
    pane_ref = _pane_ref(data.get("pane_ref"))
    if kind == "send_text":
        _exact_fields(data, {"type", "pane_id", "pane_ref", "text"})
        text = data.get("text")
        if not isinstance(text, str) or not text:
            raise ProtocolError("text must be non-empty")
        if len(text.encode("utf-8")) > MAX_TEXT_BYTES or text.count("\n") + 1 > MAX_TEXT_LINES:
            raise ProtocolError("text exceeds limit")
        if any((ord(char) < 32 and char != "\n") or ord(char) == 127 for char in text):
            raise ProtocolError("text contains control characters")
        return SendText(pane_id, pane_ref, text)
    if kind == "send_keys":
        _exact_fields(data, {"type", "pane_id", "pane_ref", "keys"})
        keys = data.get("keys")
        if not isinstance(keys, list) or not 1 <= len(keys) <= 8 or any(k not in ALLOWED_KEYS for k in keys):
            raise ProtocolError("invalid keys")
        return SendKeys(pane_id, pane_ref, tuple(keys))
    if kind == "action":
        _exact_fields(data, {"type", "pane_id", "pane_ref", "action", "confirmed"})
        action = data.get("action")
        if action not in ALLOWED_ACTIONS:
            raise ProtocolError("invalid action")
        if "confirmed" in data and type(data["confirmed"]) is not bool:
            raise ProtocolError("confirmed must be boolean")
        return Action(pane_id, pane_ref, action)
    raise ProtocolError("invalid command type")
