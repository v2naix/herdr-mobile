import os
import stat
import tempfile
import unittest
from pathlib import Path

from server.auth import SessionStore, load_or_create_token


class AuthTests(unittest.TestCase):
    def test_token_file_is_created_with_owner_only_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token"
            token = load_or_create_token(path)
            self.assertGreaterEqual(len(token), 32)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(load_or_create_token(path), token)

    def test_bearer_comparison_and_expiring_session(self):
        now = [100.0]
        store = SessionStore("correct-token", ttl_seconds=10, clock=lambda: now[0])
        self.assertIsNone(store.exchange("wrong-token"))
        session = store.exchange("correct-token")
        self.assertTrue(store.valid(session))
        now[0] = 111.0
        self.assertFalse(store.valid(session))
        self.assertFalse(store.valid("made-up"))

    def test_revoke_invalidates_only_the_selected_session(self):
        store = SessionStore("correct-token")
        revoked = store.exchange("correct-token")
        retained = store.exchange("correct-token")

        self.assertTrue(store.revoke(revoked))
        self.assertFalse(store.valid(revoked))
        self.assertTrue(store.valid(retained))
        self.assertFalse(store.revoke("made-up"))

    def test_insecure_existing_token_permissions_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token"
            path.write_text("secret")
            os.chmod(path, 0o644)
            with self.assertRaises(PermissionError):
                load_or_create_token(path)


if __name__ == "__main__":
    unittest.main()
