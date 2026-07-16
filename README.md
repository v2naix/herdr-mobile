# herdr-mobile

简体中文 | [English](README.en.md)

一个从零实现的、移动优先的 herdr + pi agent 控制面。服务只操作本机 `herdr pane` CLI 已发现的实时 pane，不提供任意 shell API。推荐架构是：

```text
iPhone Safari / PWA ── tailnet HTTPS ── Tailscale Serve
                                      └─ 127.0.0.1:8787 herdr-mobile
                                                              └─ argv-only herdr pane CLI
```

> **不要把本服务直接暴露到公网，也不要监听 `0.0.0.0`。** Tailscale ACL/设备身份是第一层访问控制，本地 token + 安全会话 cookie 是默认启用的第二层防御。本项目不集成 Cloudflare Tunnel。

## 当前 MVP

- 每 2 秒运行 `herdr pane list`，只暴露 herdr 明确认出的 agent pane，并按 `blocked / working / idle / done / unknown` 推送和分组展示；普通 shell 不可见、不可操作。
- 显示 `set-pane-title` 上报的自定义 pane 标题（隐藏 `pi - ` 前缀和内部 pane ID），并显示 cwd；未设置自定义标题时回退到 agent 名称。详情读取 `recent-unwrapped` 输出，最多 300 行、128 KiB。
- 发送最多 4096 UTF-8 字节、20 行文字，并拒绝除换行外的控制字符；详情页提供 `Enter/Tab/Escape`、Y/N 快捷键、十字布局方向键，以及固定的 `Ctrl+C / Ctrl+L / Ctrl+P / Ctrl+O` 菜单。
- 提供针对 MacGuard `ctx.ui.confirm` 实测过的固定 `approve once / deny` 动作；界面不显示 `always allow`，服务端也拒绝该动作。
- WebSocket 在临时断网后自动重连；认证或 Origin 被拒绝（1008）时停止重连并返回登录页，避免无效请求循环。提供深色 iPhone UI、manifest 和 service worker，可添加到 iPhone 主屏幕；支持注销并立即撤销当前内存会话。
- 健康检查 `GET /healthz`、严格 Origin/CSP、8 KiB WS 消息上限、连接/速率限制。
- 结构化事件日志不记录终端输入或输出正文；Uvicorn access log 默认关闭。
- adapter 可注入 fake runner，测试覆盖 pane 身份校验、输入边界、认证和 XSS 展示边界。

## 已核对的 herdr CLI（本机 0.7.4）

实际检查结果：

- `herdr pane list` 输出 JSON：`{"result":{"panes":[...]}}`；pane 含 `pane_id`、`terminal_id`、`agent`、`display_agent`、`agent_status`、`cwd`、`workspace_id` 等字段。`set-pane-title` 通过 `display_agent` 上报形如 `pi - 任务名` 的标签。
- `agent_status` 公共值为 `idle/working/blocked/done/unknown`。
- `herdr pane read <id> --source recent-unwrapped --lines N` 输出纯文本。
- `herdr pane send-text <id> <text>` 和 `herdr pane send-keys <id> <key...>` 成功时无输出。
- pane ID 不是持久 ID；本机当前值类似 `wF:p1`，不能按旧格式或旧值猜测。

每次 read/send/action 前，adapter 都重新执行 `pane list`，同时校验客户端从最新快照拿到的 `pane_id + terminal_id`（协议中称 `pane_ref`）。若 ID 已消失或被另一个 terminal 复用，操作失败并要求刷新。

## 技术选择

后端使用 Python 3.11+、FastAPI/Starlette 和 Uvicorn。相比自己实现 WebSocket/HTTP，少量成熟依赖更容易正确处理协议细节；业务层仍只使用标准库，herdr 调用集中在一个很窄的 adapter 中。所有子进程均通过 `asyncio.create_subprocess_exec(*argv)` 运行，完全不使用 shell、`shell=True` 或字符串命令拼接。前端是无框架 HTML/CSS/JS，所有不可信内容只通过 `textContent`、`createTextNode` 和 DOM API 展示，不使用 `innerHTML`。

## 安装与本地启动

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[test]'
./scripts/generate-token.sh
```

默认 token 文件是项目根目录 `.herdr-mobile-token`，创建权限为 `0600`。也可用 `HERDR_MOBILE_TOKEN_FILE` 指向其他文件，或临时通过 `HERDR_MOBILE_TOKEN` 提供至少 32 字符的密钥。不要提交或记录 token。

生产/Tailscale 启动（安全 cookie 默认启用）：

```bash
HERDR_MOBILE_ALLOWED_ORIGINS='https://your-mac.your-tailnet.ts.net' ./scripts/start.sh
```

本机纯 HTTP 调试时，Secure cookie 不会通过普通 HTTP 工作，必须显式降级；不要把这一设置用于 Tailscale HTTPS 部署：

```bash
HERDR_MOBILE_COOKIE_SECURE=0 \
HERDR_MOBILE_ALLOWED_ORIGINS='http://127.0.0.1:8787' \
./scripts/start.sh
```

打开页面，粘贴 `generate-token.sh` 显示的 token。前端通过 `Authorization: Bearer` 调用一次 `POST /api/session`，服务端换发 12 小时、内存态的 `HttpOnly; Secure; SameSite=Strict` cookie；token 不进入 URL、localStorage 或 cookie。

## Surge Ponte + 自有域名 HTTPS

以下以 `https://herdr.example.com:8443` 为示例。带 Cloudflare DNS provider 的 Caddy 只监听 `127.0.0.1:8443`，负责 DNS-01 证书签发、续期、HTTPS/WSS 和到 `127.0.0.1:8787` 的反向代理。8443 避免让服务以 root 身份运行；端口因此必须保留在 URL 中。

先将实际域名写入被 Git 忽略的本地配置；文件只能包含主机名，不含协议和端口：

```bash
cp .herdr-mobile-domain.example .herdr-mobile-domain
# 编辑 .herdr-mobile-domain，将示例值替换为实际主机名
chmod 600 .herdr-mobile-domain
```

Cloudflare 中创建专用 API Token，只授予对应 zone 的 `Zone:Read` 和 `DNS:Edit`。不要创建指向家庭公网地址的 A/AAAA 记录，也不要在命令行参数、聊天或已跟踪文件中填写 token。然后在本机交互式保存凭据并构建 Caddy：

```bash
./scripts/store-cloudflare-token.sh
./scripts/build-caddy.sh
```

分别启动安全配置的后端和 TLS 入口：

```bash
./scripts/start-https-backend.sh
./scripts/start-caddy.sh
```

Surge Mac 在 DNS Mapping 中将 `herdr.example.com` 映射到 `127.0.0.1`。Surge iOS 在可能触发 DNS 解析的规则之前添加：

```text
DOMAIN,herdr.example.com,DEVICE:<PONTE_DEVICE>
```

`<PONTE_DEVICE>` 通过 Surge UI 选择或替换，不要把设备名提交到仓库。部署域名、Caddy 凭据、证书状态和本地构建分别保存在已忽略的 `.herdr-mobile-domain`、`.cloudflare-api-token`、`.caddy/` 和 `.tools/`。详细依据见 `docs/research/caddy-cloudflare-dns.md` 与 `docs/research/surge-ponte.md`。

### 登录时自动启动

仓库提供两个当前用户级 LaunchAgent，分别监督 herdr-mobile 与 Caddy。安装前应先停止手工启动的实例，然后运行：

```bash
./scripts/install-launch-agents.sh
./scripts/launch-agents-status.sh
```

日志保存在已忽略的 `.runtime/logs/`。停止并删除自动启动配置：

```bash
./scripts/uninstall-launch-agents.sh
```

安装脚本会根据模板和当前仓库路径生成 LaunchAgent 配置；移动仓库后必须重新运行安装脚本。它们不以 root 身份运行，服务仍只监听 loopback。Caddy 必须持续运行才能按计划自动续期证书。

## Tailscale Serve

辅助脚本及 Serve 语法已使用本机 Homebrew `tailscale 1.98.8` 的 `tailscale serve --help` 核对。安装并登录 Tailscale 后：

```bash
# 终端 1：将 Origin 精确设置成 Serve 最终显示的 HTTPS 地址
HERDR_MOBILE_ALLOWED_ORIGINS='https://your-mac.your-tailnet.ts.net' ./scripts/start.sh

# 终端 2：配置 tailnet 内 HTTPS 反向代理
./scripts/tailscale-serve.sh
```

辅助脚本执行的核心命令是：

```bash
tailscale serve --bg http://127.0.0.1:8787
```

不同 Tailscale 版本的 CLI 语法可能变化，请以本机 `tailscale serve --help` 为准。该语法已在 CLI 1.98.8 验证，但实际 Serve 测试仍要求已获 macOS 系统授权且已登录 tailnet 的 daemon。用 `tailscale serve status` 核对最终 HTTPS URL，并确保它与 `HERDR_MOBILE_ALLOWED_ORIGINS` 完全一致。再通过 tailnet ACL 限制哪些用户/设备可以访问该 Mac。iPhone Safari 打开 HTTPS URL 后可使用“添加到主屏幕”。

## 固定审批动作

MVP 不允许客户端提交任意审批按键序列，而是在服务端固定映射：

| 动作 | herdr 输入 |
|---|---|
| approve once | `send-keys <pane> Enter` |
| deny | `send-keys <pane> Escape` |

当前映射针对已启用的 MacGuard 扩展：它调用 Pi `ctx.ui.confirm`，当前 Pi 将其渲染为默认选中 `Yes` 的 `Yes / No` 选择框。2026-07-16 已通过无破坏性的递归删除探针实测 Enter 放行、Escape 拒绝。Pi 或 MacGuard 若改变确认行为，应先更新 adapter 常量及测试，不能让客户端自定义映射。MacGuard 不提供 `always allow`，界面不显示该动作，服务端协议也会拒绝伪造请求。

## 协议与限制

WebSocket 只接受以下严格对象（未知字段会被拒绝）：

- `subscribe`：`pane_id, pane_ref, lines`
- `send_text`：`pane_id, pane_ref, text`
- `send_keys`：`pane_id, pane_ref, keys[]`
- `action`：`pane_id, pane_ref, action, confirmed?`

客户端不能发送 `agent_event`，也没有相应 API。状态只来自服务端轮询。最多 8 个 WS 连接，每连接 10 秒 30 条消息，单消息最多 8 KiB；Uvicorn 总并发上限为 32。命令超时 8 秒。

## 威胁模型

**防护目标：** 未经授权的 tailnet 设备、被诱导打开的跨站网页、恶意/过期客户端、pane ID 变化、超大输入、shell 注入和终端输出 XSS。

**主要措施：** Tailscale ACL；默认本地 token；短期 HttpOnly 会话；HTTP 会话交换与 WebSocket 均校验精确 Origin；CSP；严格 schema/allowlist；长度、行数、控制字符、速率、连接和输出限制；argv-only 子进程；操作前重新发现 pane 并校验 terminal 身份；纯文本 DOM 渲染；敏感正文不入日志。

**不在 MVP 范围：** 公网直接暴露、多用户/RBAC、审计终端正文、任意 shell、文件浏览、pane 创建/关闭、原生 iOS App、抵御已完全控制 Mac 或浏览器会话的攻击者。健康检查公开但只返回固定 `{"status":"ok"}`；它仍应只在 loopback/Serve 边界内使用。

可通过 `HERDR_MOBILE_AUTH=0` 关闭第二层认证，但不推荐；即使关闭，也必须保留 Tailscale Serve、ACL 和 Origin 校验。

## 测试

```bash
.venv/bin/python -m unittest discover -s tests -v
node --test tests/test_reconnect_policy.js
```

测试缝是 adapter 公共接口、协议校验函数以及 HTTP/WS 认证边界。测试输出中的 `<script>` 示例用于证明终端文本不会被服务端嵌入 HTML；运行时前端使用 `textContent`。

## 项目结构

```text
server/   FastAPI、认证、协议校验、herdr adapter
web/      响应式 UI、manifest、service worker
scripts/  loopback 启动、token、Tailscale Serve 辅助脚本
tests/    单元和 ASGI 集成测试
```
