# herdr-mobile

[简体中文](README.md) | English

A mobile-first control plane for herdr + pi agents, built from scratch. The service operates only on live panes discovered by the local `herdr pane` CLI and does not expose an arbitrary shell API. The recommended architecture is:

```text
iPhone Safari / PWA ── tailnet HTTPS ── Tailscale Serve
                                      └─ 127.0.0.1:8787 herdr-mobile
                                                              └─ argv-only herdr pane CLI
```

> **Do not expose this service directly to the public internet or bind it to `0.0.0.0`.** Tailscale ACLs and device identity are the first layer of access control. A local token plus a secure session cookie provide a second layer by default. This project does not integrate with Cloudflare Tunnel.

## Current MVP

- Runs `herdr pane list` every two seconds, exposes only panes explicitly recognized by herdr as agent panes, and pushes and groups them by `blocked / working / idle / done / unknown`. Ordinary shells are neither visible nor operable.
- Displays custom pane titles reported by `set-pane-title`, hiding the `pi - ` prefix and internal pane IDs, along with the cwd. It falls back to the agent name when no custom title is set. The detail view reads `recent-unwrapped` output, capped at 300 lines and 128 KiB.
- Sends up to 4,096 UTF-8 bytes and 20 lines of text while rejecting control characters other than newlines. The detail view provides `Enter/Tab/Escape`, Y/N shortcuts, a cross-shaped arrow-key pad, and a fixed `Ctrl+C / Ctrl+L / Ctrl+P / Ctrl+O` menu.
- Provides fixed `approve once / deny` actions verified against MacGuard's `ctx.ui.confirm`. The UI does not show `always allow`, and the server rejects that action.
- Automatically reconnects WebSockets after transient network failures. Authentication or Origin rejection (`1008`) stops reconnection and returns to the login screen, preventing invalid request loops. Includes a dark iPhone UI, manifest, and service worker for installation on the iPhone Home Screen. Logging out immediately revokes the current in-memory session.
- Provides `GET /healthz`, strict Origin and CSP enforcement, an 8 KiB WebSocket message limit, and connection and rate limits.
- `ios/HerdrMobile/` contains the production iOS 26 SwiftUI client: one HTTPS Mac configuration, separate native bearer-session validation, passcode-bound Keychain storage for the bootstrap token, and agent-pane browsing; detail supports bottom-following output, frozen history reading, horizontally scrollable original width, and fixed response operations that await acknowledgement, retain failed drafts, and never resend automatically. It connects only in the foreground and restores subscriptions only after authoritative identity synchronization. The PWA remains available as the fallback throughout native acceptance and later use.
- Structured event logs do not record terminal input or output content. Uvicorn access logging is disabled by default.
- The adapter accepts an injectable fake runner. Tests cover pane identity validation, input boundaries, authentication, and the XSS rendering boundary.

## Verified herdr CLI behavior (local version 0.7.4)

Observed behavior:

- `herdr pane list` returns JSON in the form `{"result":{"panes":[...]}}`. Each pane includes fields such as `pane_id`, `terminal_id`, `agent`, `display_agent`, `agent_status`, `cwd`, and `workspace_id`. `set-pane-title` reports labels such as `pi - task name` through `display_agent`.
- Public `agent_status` values are `idle/working/blocked/done/unknown`.
- `herdr pane read <id> --source recent-unwrapped --lines N` returns plain text.
- `herdr pane send-text <id> <text>` and `herdr pane send-keys <id> <key...>` produce no output on success.
- Pane IDs are not persistent. Values may look like `wF:p1`; clients must not infer them from an old format or reuse stale values.

Before every read, send, or action, the adapter reruns `pane list` and validates the `pane_id + terminal_id` pair obtained from the client's latest snapshot. The protocol calls the terminal identity `pane_ref`. If the ID has disappeared or has been reused by another terminal, the operation fails and the client must refresh.

## Technology choices

The backend uses Python 3.11+, FastAPI/Starlette, and Uvicorn. A small set of mature dependencies handles HTTP and WebSocket protocol details more reliably than a custom implementation, while the business layer uses only the standard library. All herdr calls are isolated in a narrow adapter.

Every subprocess is launched through `asyncio.create_subprocess_exec(*argv)`. The project never uses a shell, `shell=True`, or string-built commands. The frontend is framework-free HTML/CSS/JavaScript. All untrusted content is rendered only through `textContent`, `createTextNode`, and DOM APIs; it never uses `innerHTML`.

## Installation and local startup

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[test]'
./scripts/generate-token.sh
```

The default token file is `.herdr-mobile-token` in the project root and is created with mode `0600`. You can instead point `HERDR_MOBILE_TOKEN_FILE` to another file or temporarily provide a secret of at least 32 characters through `HERDR_MOBILE_TOKEN`. Never commit or log the token.

Production/Tailscale startup, with secure cookies enabled by default:

```bash
HERDR_MOBILE_ALLOWED_ORIGINS='https://your-mac.your-tailnet.ts.net' ./scripts/start.sh
```

Secure cookies do not work over plain HTTP during local debugging, so this mode requires an explicit downgrade. Never use this setting for a Tailscale HTTPS deployment:

```bash
HERDR_MOBILE_COOKIE_SECURE=0 \
HERDR_MOBILE_ALLOWED_ORIGINS='http://127.0.0.1:8787' \
./scripts/start.sh
```

Open the page and paste the token printed by `generate-token.sh`. The frontend calls `POST /api/session` once with `Authorization: Bearer`. The server exchanges the token for a 12-hour, in-memory `HttpOnly; Secure; SameSite=Strict` cookie. The token never enters the URL, localStorage, or cookies.

The native client instead uses separate `POST /api/native/session` and `DELETE /api/native/session` endpoints. The bootstrap token is presented only in the `Authorization` header; the returned short-lived bearer sets no cookie and cannot be used as a browser session. See [`ios/HerdrMobile/README.md`](ios/HerdrMobile/README.md) for Xcode instructions.

## Surge Ponte + custom-domain HTTPS

The examples below use `https://herdr.example.com:8443`. Caddy, built with the Cloudflare DNS provider, listens only on `127.0.0.1:8443`. It handles DNS-01 certificate issuance and renewal, HTTPS/WSS, and reverse proxying to `127.0.0.1:8787`. Port 8443 avoids running the service as root and must therefore remain in the URL.

First, put the actual hostname in a Git-ignored local configuration file. The file must contain only a hostname, without a scheme or port:

```bash
cp .herdr-mobile-domain.example .herdr-mobile-domain
# Edit .herdr-mobile-domain and replace the example with the actual hostname.
chmod 600 .herdr-mobile-domain
```

Create a dedicated Cloudflare API Token limited to `Zone:Read` and `DNS:Edit` for the relevant zone. Do not create A/AAAA records pointing to a residential public address, and do not place the token in command-line arguments, chats, or tracked files. Store the credential interactively and build Caddy:

```bash
./scripts/store-cloudflare-token.sh
./scripts/build-caddy.sh
```

Start the hardened backend and TLS entry point separately:

```bash
./scripts/start-https-backend.sh
./scripts/start-caddy.sh
```

In Surge Mac, map `herdr.example.com` to `127.0.0.1` under DNS Mapping. In Surge iOS, add the following rule before any rule that may trigger DNS resolution:

```text
DOMAIN,herdr.example.com,DEVICE:<PONTE_DEVICE>
```

Select or replace `<PONTE_DEVICE>` through the Surge UI; never commit the device name. The deployment hostname, Caddy credential, certificate state, and local build are stored in the ignored `.herdr-mobile-domain`, `.cloudflare-api-token`, `.caddy/`, and `.tools/` paths. See `docs/research/caddy-cloudflare-dns.md` and `docs/research/surge-ponte.md` for the supporting research.

### Start automatically at login

The repository provides two user-level LaunchAgents that supervise herdr-mobile and Caddy. Stop any manually started instances before running:

```bash
./scripts/install-launch-agents.sh
./scripts/launch-agents-status.sh
```

Logs are stored under the ignored `.runtime/logs/` directory. To stop and remove the automatic startup configuration:

```bash
./scripts/uninstall-launch-agents.sh
```

The installer generates LaunchAgent configurations from templates using the repository's current path. Rerun the installer after moving the repository. The agents do not run as root, and both services continue to listen only on loopback. Caddy must remain running to renew certificates automatically.

## Tailscale Serve

The helper script and Serve syntax were checked against `tailscale serve --help` from Homebrew Tailscale 1.98.8. After installing and signing in to Tailscale:

```bash
# Terminal 1: set Origin exactly to the final HTTPS URL reported by Serve.
HERDR_MOBILE_ALLOWED_ORIGINS='https://your-mac.your-tailnet.ts.net' ./scripts/start.sh

# Terminal 2: configure the HTTPS reverse proxy inside the tailnet.
./scripts/tailscale-serve.sh
```

The helper script runs this core command:

```bash
tailscale serve --bg http://127.0.0.1:8787
```

Tailscale CLI syntax may vary by version, so check the local `tailscale serve --help`. This syntax was verified with CLI 1.98.8, but an end-to-end Serve test still requires a daemon that has macOS authorization and is signed in to a tailnet. Use `tailscale serve status` to confirm the final HTTPS URL and ensure it exactly matches `HERDR_MOBILE_ALLOWED_ORIGINS`. Then use tailnet ACLs to restrict which users and devices can access the Mac. Open the HTTPS URL in iPhone Safari and use “Add to Home Screen” if desired.

## Fixed approval actions

The MVP does not let clients submit arbitrary approval key sequences. Instead, the server owns a fixed mapping:

| Action | herdr input |
|---|---|
| approve once | `send-keys <pane> Enter` |
| deny | `send-keys <pane> Escape` |

The current mapping targets the enabled MacGuard extension. MacGuard calls Pi's `ctx.ui.confirm`, which Pi currently renders as a `Yes / No` selector with `Yes` selected by default. A non-destructive recursive-delete probe verified on 2026-07-16 that Enter approves and Escape denies. If Pi or MacGuard changes this interaction, update the adapter constants and tests first; never let the client define the mapping. MacGuard does not provide `always allow`, the UI does not display it, and the server protocol rejects forged requests for it.

## Protocol and limits

The WebSocket accepts only the following strict objects; unknown fields are rejected:

- `subscribe`: `pane_id, pane_ref, lines`
- `send_text`: `pane_id, pane_ref, text`
- `send_keys`: `pane_id, pane_ref, keys[]`
- `action`: `pane_id, pane_ref, action, confirmed?`

Browser connections continue using those objects with cookie plus exact-Origin authentication. Native connections use a short-lived bearer handshake and first receive `hello` with `protocol_version + server_epoch`; native `subscribe` also requires `subscription_id`. `pane_snapshot` and `output_snapshot` are complete replacement snapshots carrying epoch, identity, and monotonic revisions. Native text, key, and fixed-action requests also require `command_id`; the server returns a correlated acknowledgement or error after execution and uses a bounded in-memory cache within the current epoch to return known results without re-execution.

Clients cannot send `agent_event`, and no corresponding API exists. State comes only from server polling. Limits are eight WebSocket connections, 30 messages per connection per 10 seconds, and 8 KiB per message. Uvicorn's total concurrency limit is 32. Commands time out after eight seconds.

## Threat model

**Protected against:** unauthorized tailnet devices, cross-site pages opened by a user, malicious or stale clients, changing pane IDs, oversized input, shell injection, and XSS from terminal output.

**Primary controls:** Tailscale ACLs; a local token enabled by default; short-lived browser HttpOnly sessions with exact-Origin validation; separate native bearer sessions that cannot be used as browser sessions; CSP; strict schemas and allowlists; length, line-count, control-character, rate, connection, and output limits; argv-only subprocesses; pane rediscovery and terminal identity validation before every operation; plain-text rendering; and exclusion of sensitive content from logs.

**Outside the current scope:** direct public-internet exposure, multi-user access or RBAC, auditing terminal content, arbitrary shell access, file browsing, creating or closing panes, and attackers who already fully control the Mac or a client session. The health endpoint is public but returns only the fixed `{"status":"ok"}` response; it should still remain behind the loopback/Serve boundary.

The second authentication layer can be disabled with `HERDR_MOBILE_AUTH=0`, but this is not recommended. Even in that mode, keep Tailscale Serve, ACLs, and Origin validation enabled.

## Tests

```bash
.venv/bin/python -m unittest discover -s tests -v
node --test tests/test_reconnect_policy.js
(cd ios/HerdrMobile && swift run HerdrMobileCoreTests)
```

The test seams are the adapter's public interface, protocol validation functions, HTTP/WebSocket authentication boundaries, and the native client's top-level state/action interface. The `<script>` example in test output proves that terminal text enters neither logs nor server-rendered HTML. At runtime, the frontend uses `textContent`. Automated RC evidence, the Safari PWA smoke procedure, target-iPhone checklist, and blocker rules are recorded in [`docs/release/ios-0.1.0-rc.3.md`](docs/release/ios-0.1.0-rc.3.md).

## Project layout

```text
server/   FastAPI, authentication, protocol validation, and the herdr adapter
web/      Responsive UI, manifest, and service worker
scripts/  Loopback startup, token, and Tailscale Serve helpers
tests/    Unit and ASGI integration tests
ios/      Production iOS 26 client and isolated prototypes
```
