import json
import unittest

from server.herdr import HerdrAdapter, HerdrError, PaneNotFound, PaneRefMismatch


PANE_LIST = {
    "id": "cli:pane:list",
    "result": {"panes": [{
        "pane_id": "w1:p1", "terminal_id": "term-safe", "agent": "pi",
        "display_agent": "pi - 修复移动端标题",
        "agent_status": "blocked", "cwd": "/tmp/project", "workspace_id": "w1"
    }]}
}


class FakeRunner:
    def __init__(self):
        self.calls = []
        self.list_output = json.dumps(PANE_LIST)

    async def run(self, argv):
        self.calls.append(argv)
        if argv == ["herdr", "pane", "list"]:
            return self.list_output
        if argv[:3] == ["herdr", "pane", "read"]:
            return "<script>alert(1)</script>\nready"
        return ""


class AdapterTests(unittest.IsolatedAsyncioTestCase):
    async def test_snapshot_exposes_only_needed_normalized_fields(self):
        adapter = HerdrAdapter(FakeRunner())
        panes = await adapter.list_panes()
        self.assertEqual(panes, [{
            "pane_id": "w1:p1", "pane_ref": "term-safe", "title": "修复移动端标题",
            "agent_status": "blocked", "cwd": "/tmp/project", "workspace_id": "w1"
        }])

    async def test_snapshot_falls_back_to_agent_when_custom_title_is_missing(self):
        runner = FakeRunner()
        pane_list = json.loads(runner.list_output)
        del pane_list["result"]["panes"][0]["display_agent"]
        runner.list_output = json.dumps(pane_list)

        panes = await HerdrAdapter(runner).list_panes()

        self.assertEqual(panes[0]["title"], "pi")

    async def test_only_detected_agent_panes_are_exposed_or_operable(self):
        runner = FakeRunner()
        pane_list = json.loads(runner.list_output)
        pane_list["result"]["panes"].append({
            "pane_id": "w1:p2", "terminal_id": "term-shell",
            "agent_status": "unknown", "cwd": "/tmp/project", "workspace_id": "w1",
        })
        runner.list_output = json.dumps(pane_list)
        adapter = HerdrAdapter(runner)

        self.assertEqual([pane["pane_id"] for pane in await adapter.list_panes()], ["w1:p1"])
        with self.assertRaises(PaneNotFound):
            await adapter.send_text("w1:p2", "term-shell", "echo unsafe")
        self.assertNotIn(
            ["herdr", "pane", "send-text", "w1:p2", "echo unsafe"], runner.calls
        )

    async def test_each_operation_revalidates_id_and_terminal_identity(self):
        runner = FakeRunner()
        adapter = HerdrAdapter(runner)
        await adapter.send_text("w1:p1", "term-safe", "hello")
        self.assertEqual(runner.calls, [
            ["herdr", "pane", "list"],
            ["herdr", "pane", "send-text", "w1:p1", "hello"],
        ])
        with self.assertRaises(PaneRefMismatch):
            await adapter.send_text("w1:p1", "old-terminal", "hello")
        with self.assertRaises(PaneNotFound):
            await adapter.send_keys("missing", "anything", ["Enter"])

    async def test_read_uses_fixed_source_and_validated_lines(self):
        runner = FakeRunner()
        output = await HerdrAdapter(runner).read("w1:p1", "term-safe", 300)
        self.assertIn("<script>", output)
        self.assertEqual(runner.calls[-1], [
            "herdr", "pane", "read", "w1:p1", "--source", "recent-unwrapped", "--lines", "300"
        ])

    async def test_actions_have_fixed_non_shell_key_sequences(self):
        runner = FakeRunner()
        adapter = HerdrAdapter(runner)
        await adapter.action("w1:p1", "term-safe", "approve_once")
        self.assertEqual(runner.calls[-1], ["herdr", "pane", "send-keys", "w1:p1", "Enter"])
        await adapter.action("w1:p1", "term-safe", "deny")
        self.assertEqual(runner.calls[-1], ["herdr", "pane", "send-keys", "w1:p1", "Escape"])
        with self.assertRaises(HerdrError):
            await adapter.action("w1:p1", "term-safe", "always_allow")


if __name__ == "__main__":
    unittest.main()
