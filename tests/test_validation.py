import unittest

from server.protocol import ProtocolError, parse_command, parse_native_command, validate_lines


class ValidationTests(unittest.TestCase):
    def test_lines_are_clamped_to_safe_range(self):
        self.assertEqual(validate_lines(None), 120)
        self.assertEqual(validate_lines(1), 1)
        self.assertEqual(validate_lines(500), 300)
        with self.assertRaises(ProtocolError):
            validate_lines("50")

    def test_send_text_has_a_utf8_byte_and_line_limit(self):
        command = parse_command({"type": "send_text", "pane_id": "w1:p1", "pane_ref": "term-1", "text": "hello\nworld"})
        self.assertEqual(command.text, "hello\nworld")
        with self.assertRaises(ProtocolError):
            parse_command({"type": "send_text", "pane_id": "w1:p1", "pane_ref": "term-1", "text": "x" * 4097})
        with self.assertRaises(ProtocolError):
            parse_command({"type": "send_text", "pane_id": "w1:p1", "pane_ref": "term-1", "text": "x\n" * 21})
        with self.assertRaises(ProtocolError):
            parse_command({"type": "send_text", "pane_id": "w1:p1", "pane_ref": "term-1", "text": "hidden\x1b[2J"})
        with self.assertRaises(ProtocolError):
            parse_command({"type": "send_text", "pane_id": "w1:p1", "pane_ref": "term-1", "text": "yes\r"})

    def test_keys_are_allowlisted_and_unknown_fields_rejected(self):
        command = parse_command({"type": "send_keys", "pane_id": "w1:p1", "pane_ref": "term-1", "keys": ["Enter", "Ctrl+c"]})
        self.assertEqual(command.keys, ("Enter", "Ctrl+c"))
        with self.assertRaises(ProtocolError):
            parse_command({"type": "send_keys", "pane_id": "w1:p1", "pane_ref": "term-1", "keys": ["F12"]})
        with self.assertRaises(ProtocolError):
            parse_command({"type": "send_keys", "pane_id": "w1:p1", "pane_ref": "term-1", "keys": ["Enter"], "agent_event": {}})

    def test_control_key_menu_has_a_fixed_allowlist(self):
        for key in ("Ctrl+c", "Ctrl+l", "Ctrl+p", "Ctrl+o"):
            command = parse_command({
                "type": "send_keys", "pane_id": "w1:p1", "pane_ref": "term-1", "keys": [key]
            })
            self.assertEqual(command.keys, (key,))

        for key in ("Ctrl+C", "Ctrl+L", "Ctrl+a", "Ctrl+r", "Ctrl+1", "ctrl+c"):
            with self.subTest(key=key), self.assertRaises(ProtocolError):
                parse_command({
                    "type": "send_keys", "pane_id": "w1:p1", "pane_ref": "term-1", "keys": [key]
                })

    def test_native_commands_require_a_bounded_correlation_id(self):
        native = parse_native_command({
            "type": "send_keys", "command_id": "command-1",
            "pane_id": "w1:p1", "pane_ref": "term-1", "keys": ["Enter"],
        })
        self.assertEqual(native.command_id, "command-1")
        self.assertEqual(native.command.keys, ("Enter",))

        for command_id in (None, "", "x" * 129):
            with self.subTest(command_id=command_id), self.assertRaises(ProtocolError):
                parse_native_command({
                    "type": "send_keys", "command_id": command_id,
                    "pane_id": "w1:p1", "pane_ref": "term-1", "keys": ["Enter"],
                })
        with self.assertRaises(ProtocolError):
            parse_command({
                "type": "send_keys", "command_id": "native-only",
                "pane_id": "w1:p1", "pane_ref": "term-1", "keys": ["Enter"],
            })

    def test_unverified_always_allow_is_rejected_even_when_confirmed(self):
        command = parse_command({
            "type": "action", "pane_id": "w1:p1", "pane_ref": "term-1", "action": "approve_once"
        })
        self.assertEqual(command.action, "approve_once")
        with self.assertRaises(ProtocolError):
            parse_command({
                "type": "action", "pane_id": "w1:p1", "pane_ref": "term-1",
                "action": "always_allow", "confirmed": True,
            })


if __name__ == "__main__":
    unittest.main()
