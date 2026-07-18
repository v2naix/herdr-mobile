import unittest

from server.commands import CommandResultCache


class CommandResultCacheTests(unittest.IsolatedAsyncioTestCase):
    async def test_results_are_bounded_and_eviction_does_not_claim_exactly_once(self):
        cache = CommandResultCache(maximum=2)
        executions: list[str] = []

        async def execute(value: str) -> None:
            executions.append(value)

        await cache.execute("command-1", "one", lambda: execute("one"))
        await cache.execute("command-2", "two", lambda: execute("two"))
        await cache.execute("command-3", "three", lambda: execute("three"))
        await cache.execute("command-3", "three", lambda: execute("three"))
        await cache.execute("command-1", "one", lambda: execute("one"))

        self.assertEqual(executions, ["one", "two", "three", "one"])


if __name__ == "__main__":
    unittest.main()
