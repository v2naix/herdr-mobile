"""Narrow, shell-free adapter around the herdr pane CLI."""

import asyncio
import json
from collections.abc import Sequence
from typing import Protocol

VALID_STATUSES = frozenset({"idle", "working", "blocked", "done", "unknown"})
MAX_OUTPUT_BYTES = 128 * 1024
ACTION_KEYS = {
    "approve_once": ("Enter",),
    "deny": ("Escape",),
}


class HerdrError(RuntimeError):
    pass


class PaneNotFound(HerdrError):
    pass


class PaneRefMismatch(HerdrError):
    pass


class Runner(Protocol):
    async def run(self, argv: Sequence[str]) -> str: ...


class SubprocessRunner:
    """Execute an argv directly. A shell is deliberately never involved."""

    def __init__(self, timeout: float = 8.0):
        self.timeout = timeout

    async def run(self, argv: Sequence[str]) -> str:
        process = await asyncio.create_subprocess_exec(
            *argv, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), self.timeout)
        except TimeoutError:
            process.kill()
            await process.wait()
            raise HerdrError("herdr command timed out") from None
        if process.returncode:
            # Do not echo CLI details: they may contain terminal content.
            raise HerdrError(f"herdr command failed ({process.returncode})")
        return stdout.decode("utf-8", errors="replace")


class HerdrAdapter:
    def __init__(self, runner: Runner):
        self.runner = runner

    async def list_panes(self) -> list[dict[str, str]]:
        raw = await self.runner.run(["herdr", "pane", "list"])
        try:
            source = json.loads(raw)["result"]["panes"]
        except (json.JSONDecodeError, KeyError, TypeError):
            raise HerdrError("invalid pane list response") from None
        panes = []
        for item in source:
            if not isinstance(item, dict):
                continue
            pane_id, pane_ref = item.get("pane_id"), item.get("terminal_id")
            agent = item.get("agent")
            if (
                not isinstance(pane_id, str)
                or not isinstance(pane_ref, str)
                or not isinstance(agent, str)
                or not agent.strip()
            ):
                continue
            status = item.get("agent_status", "unknown")
            title = agent.strip()
            display_agent = item.get("display_agent")
            if isinstance(display_agent, str) and display_agent.strip():
                display_title = display_agent.strip()
                prefix = f"{title} - "
                if display_title.startswith(prefix):
                    display_title = display_title[len(prefix):].strip()
                if display_title:
                    title = display_title
            panes.append({
                "pane_id": pane_id,
                "pane_ref": pane_ref,
                "title": title,
                "agent_status": status if status in VALID_STATUSES else "unknown",
                "cwd": item.get("cwd") if isinstance(item.get("cwd"), str) else "",
                "workspace_id": item.get("workspace_id") if isinstance(item.get("workspace_id"), str) else "",
            })
        return panes

    async def _validate(self, pane_id: str, pane_ref: str) -> None:
        panes = await self.list_panes()
        pane = next((item for item in panes if item["pane_id"] == pane_id), None)
        if pane is None:
            raise PaneNotFound("pane is no longer available")
        if pane["pane_ref"] != pane_ref:
            raise PaneRefMismatch("pane identity changed; refresh required")

    async def read(self, pane_id: str, pane_ref: str, lines: int) -> str:
        await self._validate(pane_id, pane_ref)
        output = await self.runner.run([
            "herdr", "pane", "read", pane_id, "--source", "recent-unwrapped", "--lines", str(lines)
        ])
        encoded = output.encode("utf-8")
        if len(encoded) > MAX_OUTPUT_BYTES:
            output = encoded[-MAX_OUTPUT_BYTES:].decode("utf-8", errors="replace")
        return output

    async def send_text(self, pane_id: str, pane_ref: str, text: str) -> None:
        await self._validate(pane_id, pane_ref)
        await self.runner.run(["herdr", "pane", "send-text", pane_id, text])

    async def send_keys(self, pane_id: str, pane_ref: str, keys: Sequence[str]) -> None:
        await self._validate(pane_id, pane_ref)
        await self.runner.run(["herdr", "pane", "send-keys", pane_id, *keys])

    async def action(self, pane_id: str, pane_ref: str, action: str) -> None:
        keys = ACTION_KEYS.get(action)
        if keys is None:
            raise HerdrError("invalid action")
        await self.send_keys(pane_id, pane_ref, keys)
