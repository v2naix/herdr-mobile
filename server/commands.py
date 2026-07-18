"""Process-epoch native command result deduplication."""

import asyncio
from collections import OrderedDict
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

from .herdr import HerdrError


@dataclass(frozen=True)
class CommandResult:
    acknowledged: bool
    error: str | None = None


class CommandResultCache:
    """Execute each known command ID once and retain a bounded result set."""

    def __init__(self, maximum: int = 256):
        self._maximum = maximum
        self._results: OrderedDict[str, tuple[str, CommandResult]] = OrderedDict()
        self._in_flight: dict[str, tuple[str, asyncio.Task[CommandResult]]] = {}
        self._lock = asyncio.Lock()

    async def execute(
        self,
        command_id: str,
        fingerprint: str,
        operation: Callable[[], Awaitable[None]],
    ) -> CommandResult:
        async with self._lock:
            known = self._results.get(command_id)
            if known is not None:
                known_fingerprint, result = known
                if known_fingerprint != fingerprint:
                    return CommandResult(False, "command_id reused with different command")
                self._results.move_to_end(command_id)
                return result

            pending = self._in_flight.get(command_id)
            if pending is not None:
                pending_fingerprint, task = pending
                if pending_fingerprint != fingerprint:
                    return CommandResult(False, "command_id reused with different command")
            else:
                task = asyncio.create_task(
                    self._execute_and_store(command_id, fingerprint, operation)
                )
                self._in_flight[command_id] = (fingerprint, task)

        # A closing socket must not cancel an operation that may already have reached herdr.
        return await asyncio.shield(task)

    async def _execute_and_store(
        self,
        command_id: str,
        fingerprint: str,
        operation: Callable[[], Awaitable[None]],
    ) -> CommandResult:
        try:
            try:
                await operation()
                result = CommandResult(True)
            except HerdrError as error:
                result = CommandResult(False, str(error))

            async with self._lock:
                self._results[command_id] = (fingerprint, result)
                while len(self._results) > self._maximum:
                    self._results.popitem(last=False)
            return result
        finally:
            async with self._lock:
                self._in_flight.pop(command_id, None)
