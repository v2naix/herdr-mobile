import json
import unittest

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from server.app import create_app
from server.auth import SessionStore
from tests.test_adapter import FakeRunner
from server.herdr import HerdrAdapter


class AppTests(unittest.TestCase):
    def setUp(self):
        self.app = create_app(
            adapter=HerdrAdapter(FakeRunner()),
            sessions=SessionStore("test-token"),
            allowed_origins={"https://mac.example.ts.net"},
            secure_cookie=True,
        )
        self.client = TestClient(self.app)

    def test_health_is_public_and_security_headers_are_set(self):
        response = self.client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"status": "ok"})
        self.assertIn("default-src 'self'", response.headers["content-security-policy"])
        self.assertEqual(response.headers["x-content-type-options"], "nosniff")

    def test_session_exchange_requires_bearer_and_sets_hardened_cookie(self):
        origin = {"origin": "https://mac.example.ts.net"}
        self.assertEqual(self.client.post("/api/session", headers=origin).status_code, 401)
        self.assertEqual(self.client.post(
            "/api/session", headers={"Authorization": "Bearer test-token", "origin": "https://evil.example"}
        ).status_code, 403)
        response = self.client.post(
            "/api/session", headers={"Authorization": "Bearer test-token", **origin}
        )
        self.assertEqual(response.status_code, 204)
        cookie = response.headers["set-cookie"]
        self.assertIn("HttpOnly", cookie)
        self.assertIn("Secure", cookie)
        self.assertIn("SameSite=strict", cookie)
        self.assertNotIn("test-token", cookie)

    def test_native_session_exchange_uses_bearer_without_origin_or_cookie(self):
        response = self.client.post(
            "/api/native/session",
            headers={"Authorization": "Bearer test-token"},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(set(response.json()), {"token", "expires_in"})
        self.assertGreaterEqual(response.json()["expires_in"], 1)
        self.assertNotIn("set-cookie", response.headers)
        self.assertNotEqual(response.json()["token"], "test-token")

    def test_native_session_rejects_missing_or_invalid_bootstrap_token(self):
        self.assertEqual(self.client.post("/api/native/session").status_code, 401)
        self.assertEqual(
            self.client.post(
                "/api/native/session",
                headers={"Authorization": "Bearer wrong-token"},
            ).status_code,
            401,
        )

    def test_expired_native_session_is_rejected_at_the_http_boundary(self):
        now = [100.0]
        app = create_app(
            adapter=HerdrAdapter(FakeRunner()),
            sessions=SessionStore("test-token", ttl_seconds=10, clock=lambda: now[0]),
            allowed_origins={"https://mac.example.ts.net"},
        )
        client = TestClient(app)
        token = client.post(
            "/api/native/session",
            headers={"Authorization": "Bearer test-token"},
        ).json()["token"]

        now[0] = 111.0
        response = client.delete(
            "/api/native/session",
            headers={"Authorization": f"Bearer {token}"},
        )
        self.assertEqual(response.status_code, 401)

    def test_native_session_can_be_revoked_only_with_its_bearer(self):
        native = self.client.post(
            "/api/native/session",
            headers={"Authorization": "Bearer test-token"},
        ).json()["token"]
        browser_response = self.client.post(
            "/api/session",
            headers={
                "Authorization": "Bearer test-token",
                "origin": "https://mac.example.ts.net",
            },
        )
        browser = browser_response.cookies["herdr_mobile_session"]

        self.assertEqual(
            self.client.delete(
                "/api/native/session",
                headers={"Authorization": f"Bearer {browser}"},
            ).status_code,
            401,
        )
        self.assertEqual(
            self.client.delete(
                "/api/native/session",
                headers={"Authorization": f"Bearer {native}"},
            ).status_code,
            204,
        )
        self.assertEqual(
            self.client.delete(
                "/api/native/session",
                headers={"Authorization": f"Bearer {native}"},
            ).status_code,
            401,
        )

    def test_native_exchange_shares_the_existing_authentication_rate_limit(self):
        for _ in range(10):
            response = self.client.post(
                "/api/native/session",
                headers={"Authorization": "Bearer wrong-token"},
            )
            self.assertEqual(response.status_code, 401)

        response = self.client.post(
            "/api/session",
            headers={
                "Authorization": "Bearer test-token",
                "origin": "https://mac.example.ts.net",
            },
        )
        self.assertEqual(response.status_code, 429)

    def test_native_and_browser_sessions_are_not_interchangeable(self):
        origin = "https://mac.example.ts.net"
        native = self.client.post(
            "/api/native/session",
            headers={"Authorization": "Bearer test-token"},
        ).json()["token"]
        browser = self.client.post(
            "/api/session",
            headers={"Authorization": "Bearer test-token", "origin": origin},
        ).cookies["herdr_mobile_session"]

        with self.client.websocket_connect(
            "/ws",
            cookies={"herdr_mobile_session": native},
            headers={"origin": origin},
        ) as socket:
            with self.assertRaises(WebSocketDisconnect) as rejected_browser:
                socket.receive_text()
        self.assertEqual(rejected_browser.exception.code, 1008)

        with self.client.websocket_connect(
            "/ws",
            headers={"Authorization": f"Bearer {browser}"},
        ) as socket:
            with self.assertRaises(WebSocketDisconnect) as rejected_native:
                socket.receive_text()
        self.assertEqual(rejected_native.exception.code, 1008)

    def test_logout_requires_allowed_origin_clears_cookie_and_revokes_session(self):
        origin = "https://mac.example.ts.net"
        response = self.client.post(
            "/api/session", headers={"Authorization": "Bearer test-token", "origin": origin}
        )
        session = response.cookies["herdr_mobile_session"]

        rejected = self.client.post(
            "/api/logout",
            cookies={"herdr_mobile_session": session},
            headers={"origin": "https://evil.example"},
        )
        self.assertEqual(rejected.status_code, 403)

        response = self.client.post(
            "/api/logout",
            cookies={"herdr_mobile_session": session},
            headers={"origin": origin},
        )
        self.assertEqual(response.status_code, 204)
        cookie = response.headers["set-cookie"]
        self.assertIn("herdr_mobile_session=", cookie)
        self.assertIn("Max-Age=0", cookie)
        self.assertIn("HttpOnly", cookie)
        self.assertIn("Secure", cookie)
        self.assertIn("SameSite=strict", cookie)

        with self.client.websocket_connect(
            "/ws",
            cookies={"herdr_mobile_session": session},
            headers={"origin": origin},
        ) as socket:
            with self.assertRaises(WebSocketDisconnect) as rejected_socket:
                socket.receive_text()
        self.assertEqual(rejected_socket.exception.code, 1008)

    def test_websocket_auth_rejection_uses_policy_close_frame(self):
        with self.client.websocket_connect(
            "/ws", headers={"origin": "https://mac.example.ts.net"}
        ) as socket:
            with self.assertRaises(WebSocketDisconnect) as rejected:
                socket.receive_text()

        self.assertEqual(rejected.exception.code, 1008)
        self.assertEqual(rejected.exception.reason, "authentication required")

    def test_websocket_rejects_bad_origin_even_with_session(self):
        response = self.client.post(
            "/api/session", headers={"Authorization": "Bearer test-token", "origin": "https://mac.example.ts.net"}
        )
        session = response.cookies.get("herdr_mobile_session")
        with self.assertRaises(Exception):
            with self.client.websocket_connect(
                "/ws", cookies={"herdr_mobile_session": session}, headers={"origin": "https://evil.example"}
            ):
                pass

    def test_static_html_does_not_embed_terminal_output(self):
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertNotIn("<script>alert(1)</script>", response.text)
        javascript = self.client.get("/static/app.js").text
        self.assertNotIn("innerHTML", javascript)
        self.assertIn("textContent", javascript)

    def test_static_client_exposes_logout_and_calls_the_revoke_endpoint(self):
        html = self.client.get("/").text
        javascript = self.client.get("/static/app.js").text

        self.assertIn('id="logout"', html)
        self.assertIn("fetch('/api/logout'", javascript)
        self.assertNotIn('data-action="always_allow"', html)

    def test_static_client_renders_friendly_titles_without_pane_ids(self):
        javascript = self.client.get("/static/app.js").text

        self.assertIn("pane.title", javascript)
        self.assertNotIn("${pane.agent} ·", javascript)
        self.assertNotIn("${pane.pane_id}", javascript)

    def test_static_client_has_a_versioned_compact_terminal_toolbar(self):
        html = self.client.get("/").text

        self.assertIn('/static/app.css?v=6', html)
        self.assertIn('/static/reconnect-policy.js?v=7', html)
        self.assertIn('/static/app.js?v=7', html)
        self.assertLess(html.index('reconnect-policy.js?v=7'), html.index('app.js?v=7'))
        self.assertIn('class="term-keys"', html)
        self.assertIn('data-text="y"', html)
        self.assertIn('data-text="n"', html)
        self.assertIn('id="ctrl-menu-toggle"', html)
        self.assertIn('id="ctrl-popup"', html)
        self.assertGreaterEqual(html.count('data-key="Ctrl+c"'), 2)  # one-tap shortcut plus menu item
        for key in ("Ctrl+c", "Ctrl+l", "Ctrl+p", "Ctrl+o"):
            self.assertIn(f'data-key="{key}"', html)
        self.assertIn('id="arrow-toggle"', html)
        self.assertIn('id="arrow-popup"', html)
        for key in ("Up", "Left", "Enter", "Right", "Down"):
            self.assertIn(f'data-key="{key}"', html)

    def test_native_websocket_uses_bearer_and_announces_protocol_epoch(self):
        token = self.client.post(
            "/api/native/session",
            headers={"Authorization": "Bearer test-token"},
        ).json()["token"]

        with self.client.websocket_connect(
            "/ws",
            headers={"Authorization": f"Bearer {token}"},
        ) as socket:
            hello = socket.receive_json()

        self.assertEqual(hello["type"], "hello")
        self.assertEqual(hello["protocol_version"], 1)
        self.assertGreaterEqual(len(hello["server_epoch"]), 16)

    def test_native_websocket_sends_versioned_full_snapshots_for_strict_subscription(self):
        token = self.client.post(
            "/api/native/session",
            headers={"Authorization": "Bearer test-token"},
        ).json()["token"]

        with self.client.websocket_connect(
            "/ws",
            headers={"Authorization": f"Bearer {token}"},
        ) as socket:
            hello = socket.receive_json()
            socket.send_json({
                "type": "subscribe",
                "subscription_id": "subscription-1",
                "pane_id": "w1:p1",
                "pane_ref": "term-safe",
                "lines": 30,
            })
            messages = [socket.receive_json(), socket.receive_json()]

        snapshot = next(message for message in messages if message["type"] == "pane_snapshot")
        output = next(message for message in messages if message["type"] == "output_snapshot")
        self.assertEqual(snapshot["server_epoch"], hello["server_epoch"])
        self.assertEqual(snapshot["revision"], 1)
        self.assertEqual(snapshot["panes"][0]["pane_ref"], "term-safe")
        self.assertEqual(output, {
            "type": "output_snapshot",
            "server_epoch": hello["server_epoch"],
            "subscription_id": "subscription-1",
            "pane_id": "w1:p1",
            "pane_ref": "term-safe",
            "revision": 1,
            "text": "<script>alert(1)</script>\nready",
        })

    def test_pane_revision_remains_monotonic_across_native_connections_in_one_epoch(self):
        runner = FakeRunner()
        app = create_app(
            adapter=HerdrAdapter(runner),
            sessions=SessionStore("test-token"),
            allowed_origins={"http://testserver"},
            secure_cookie=False,
        )
        client = TestClient(app)
        token = client.post(
            "/api/native/session",
            headers={"Authorization": "Bearer test-token"},
        ).json()["token"]

        def subscribe(socket, subscription_id):
            socket.send_json({
                "type": "subscribe", "subscription_id": subscription_id,
                "pane_id": "w1:p1", "pane_ref": "term-safe", "lines": 30,
            })
            messages = [socket.receive_json(), socket.receive_json()]
            return next(message for message in messages if message["type"] == "pane_snapshot")

        with client.websocket_connect(
            "/ws", headers={"Authorization": f"Bearer {token}"}
        ) as socket:
            epoch = socket.receive_json()["server_epoch"]
            first = subscribe(socket, "subscription-1")
            changed = json.loads(runner.list_output)
            changed["result"]["panes"][0]["display_agent"] = "pi - 新标题"
            runner.list_output = json.dumps(changed)
            updated = subscribe(socket, "subscription-2")

        second_token = client.post(
            "/api/native/session",
            headers={"Authorization": "Bearer test-token"},
        ).json()["token"]
        with client.websocket_connect(
            "/ws", headers={"Authorization": f"Bearer {second_token}"}
        ) as socket:
            second_hello = socket.receive_json()
            restored = subscribe(socket, "subscription-3")

        self.assertEqual(first["revision"], 1)
        self.assertEqual(updated["revision"], 2)
        self.assertEqual(second_hello["server_epoch"], epoch)
        self.assertEqual(restored["revision"], 2)

    def test_native_subscription_rejects_browser_shape_and_stale_identity(self):
        token = self.client.post(
            "/api/native/session",
            headers={"Authorization": "Bearer test-token"},
        ).json()["token"]

        with self.client.websocket_connect(
            "/ws",
            headers={"Authorization": f"Bearer {token}"},
        ) as socket:
            socket.receive_json()
            socket.send_json({
                "type": "subscribe", "pane_id": "w1:p1",
                "pane_ref": "term-safe", "lines": 30,
            })
            malformed = socket.receive_json()
            socket.send_json({
                "type": "subscribe", "subscription_id": "subscription-2",
                "pane_id": "w1:p1", "pane_ref": "stale", "lines": 30,
            })
            stale = socket.receive_json()

        self.assertEqual(malformed["type"], "error")
        self.assertIn("subscribe", malformed["error"])
        self.assertEqual(stale["type"], "error")
        self.assertIn("identity", stale["error"])

    def test_authenticated_websocket_pushes_snapshot_and_plain_output(self):
        app = create_app(
            adapter=HerdrAdapter(FakeRunner()), sessions=SessionStore("test-token"),
            allowed_origins={"http://testserver"}, secure_cookie=False,
        )
        client = TestClient(app)
        response = client.post(
            "/api/session", headers={"Authorization": "Bearer test-token", "origin": "http://testserver"}
        )
        client.cookies.set("herdr_mobile_session", response.cookies["herdr_mobile_session"])
        with client.websocket_connect("/ws", headers={"origin": "http://testserver"}) as socket:
            socket.send_json({"type": "subscribe", "pane_id": "w1:p1", "pane_ref": "term-safe", "lines": 30})
            messages = [socket.receive_json(), socket.receive_json()]
        self.assertEqual({message["type"] for message in messages}, {"snapshot", "output"})
        output = next(message for message in messages if message["type"] == "output")
        self.assertEqual(output["text"], "<script>alert(1)</script>\nready")


if __name__ == "__main__":
    unittest.main()
