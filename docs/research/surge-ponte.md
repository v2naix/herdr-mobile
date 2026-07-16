# Surge Ponte 能否替代 Tailscale：针对 herdr-mobile 的调研

调研日期：2026-07-16

本机环境：Surge Mac 6.4.3（build 10320）

## 结论

**可以有条件地替代。** 对“同一用户从装有 Surge 的 iPhone 访问家中 Mac 上的 `herdr-mobile`”这一单用户场景，Ponte 的能力与需求高度吻合：它在 Surge Mac 与 Surge iOS 之间建立端到端加密私网，并且官方明确说明，通过 `<设备名>.sgponte:<端口>` 可以访问 Mac 上的 HTTP 服务；该地址在远端被解析到 `127.0.0.1`，所以服务仍可只监听 loopback。[Surge Ponte Guide](https://kb.nssurge.com/surge-knowledge-base/guidelines/ponte)

但 Ponte **不等价于 Tailscale Serve**：官方资料只承诺 Ponte 私网与端口访问，没有说明它会为应用自动签发浏览器可信证书或提供 HTTPS 终止。因此，直接使用 Ponte 时最简单的地址是 `http://<设备名>.sgponte:8787`，而不是自动获得 `https://...`。这会让浏览器把页面视为非安全上下文，并与 herdr-mobile 默认的 `Secure` 会话 cookie 及完整 PWA/service worker 能力冲突。

建议：

- 如果目标是**少装一个 VPN、仅自己使用，并愿意接受“Ponte 隧道内 HTTP”**，可以不使用 Tailscale。
- 如果目标是**最省心的浏览器可信 HTTPS、严格 Secure cookie、稳定 PWA、安全 ACL 或未来多用户**，继续使用 Tailscale Serve 更合适。
- 折中方案是在 Ponte 内自行提供 HTTPS（真实域名 + DNS-01 证书，或在 iPhone 上信任自建 CA），但运维复杂度会明显上升。

## 安全性评估

**结论：对个人设备间的日常远程访问，Ponte 可以认为“合理安全”；但不应把它视为经过公开验证的高保障安全方案。**

支持这一判断的依据：

- 官方明确承诺链路“始终端到端加密”，设备信息和加密密钥通过用户自己的 iCloud 同步；即使使用 UDP 代理做 NAT 穿透，代理也只是传输通道。按该安全模型，代理运营方不能读取 Ponte 明文，但仍可观察连接时间、端点 IP 和流量大小等元数据。[Surge Ponte Guide](https://kb.nssurge.com/surge-knowledge-base/guidelines/ponte)
- Ponte 默认把访问资格绑定到同一 iCloud 下的 Surge 设备，也支持跨 iCloud 分享。因此，iCloud 账号、受信设备和分享凭据构成主要身份边界；Apple ID 或已登记设备失陷会显著削弱该边界。[Surge Ponte Guide](https://kb.nssurge.com/surge-knowledge-base/guidelines/ponte)、[Surge iOS Release Notes](https://kb.nssurge.com/surge-knowledge-base/release-notes/surge-ios)
- Ponte 可把远端的 `*.sgponte` 映射到服务端 `127.0.0.1`，也可把整段家庭内网经 `DEVICE:<name>` 暴露给客户端。因此，它绕过的是公网暴露，不会替代 SMB、Web 应用、NAS 等目标服务自身的账号认证和权限控制。[Surge Ponte Guide](https://kb.nssurge.com/surge-knowledge-base/guidelines/ponte)

公开资料的主要不足：

- 官方只公开了“端到端加密”和底层协议名 Vector，没有公开 Ponte/Vector 的密码套件、握手与设备认证细节、前向保密性质、密钥轮换/撤销机制或完整威胁模型。
- Surge/Ponte 是闭源实现；本次检索未找到针对 Ponte 的公开第三方密码学审计或可复核协议规范。也未找到明确的 Ponte 专属安全公告，但这不能证明不存在漏洞。
- “密钥通过 iCloud 同步”不等于文档已经证明密钥只以客户端加密后的形式存入 CloudKit；官方 Ponte 指南没有解释密钥的静态存储与 iCloud 侧保护方式。因此安全性还依赖 Surge 实现、Apple 账号安全和端点设备安全。
- 如果应用层使用 `http://*.sgponte`，链路虽有 Ponte 加密，浏览器仍把它视为非安全上下文：没有标准 HTTPS 身份校验，不能使用 `Secure` cookie，部分 PWA 能力不可用。敏感 Web 服务最好仍启用 HTTPS 和自己的登录认证。

### 建议的安全配置

1. Apple ID 开启双重认证，并定期检查受信设备；设备丢失后立即从账号移除，并检查/重建 Ponte 分享关系。
2. 只启用实际需要的 Ponte server 和内网路由，不要把整个家庭网段默认开放给所有 Ponte 客户端。
3. 目标服务继续启用强密码、token 或密钥认证；SMB 禁止访客访问，NAS/管理后台及时更新。
4. 通过代理穿透时，优先选择自建或可信代理；虽然内容应为端到端加密，代理仍能看到元数据，也可能阻断或降级可用性。
5. 高敏感场景（公司生产网、密钥管理、强合规要求）优先使用协议公开且经过广泛审计、具备明确 ACL 和设备撤销能力的方案，例如 WireGuard/Tailscale，并在应用层保留 HTTPS/SSH。
6. 保持 Surge Mac/iOS 为最新版本；不再使用 Ponte 时关闭 server，避免长期保留不必要的远程入口。

## 官方确认的能力

### 1. 设备角色与访问模型

官方说明 Ponte 是 Surge Mac 与 iOS 设备之间的私网：

- Surge Mac 可作为 Ponte server 或 client；
- Surge iOS 只能作为 client；
- 设备信息和加密密钥通过 iCloud 同步；
- 默认可由运行 Surge 且登录同一 iCloud 账号的设备访问；后续 iOS 版本也加入了跨 iCloud 账号分享能力；
- 数据始终端到端加密，除用户主动选择的穿透代理外，不经过第三方服务器。

来源：[Surge Ponte Guide](https://kb.nssurge.com/surge-knowledge-base/guidelines/ponte)、[Surge iOS Release Notes](https://kb.nssurge.com/surge-knowledge-base/release-notes/surge-ios)

这意味着 Ponte 可承担 herdr-mobile 设计中的“第一层私网访问控制”，但仍应保留 herdr-mobile 自己的 token/session 认证作为纵深防御。

### 2. loopback 服务可以直接访问

官方给出的访问方式是：

```text
http://mymacmini.sgponte:8080/
```

更关键的是，官方 Tips 明确说明：访问 `ponte-name.sgponte` 时，会动态使用 `DEVICE:ponte-name` 策略，并在远端将该名称解析为 `127.0.0.1`，**因此监听在 `127.0.0.1` 的服务也能访问**。[Surge Ponte Guide](https://kb.nssurge.com/surge-knowledge-base/guidelines/ponte)

所以 herdr-mobile 无需改为监听 `0.0.0.0`，现有 loopback 安全边界可保持不变。

### 3. NAT 与连接通道

Ponte server 有三类连接方式：

1. Direct NAT traversal：要求家庭网络是 Type A / Full Cone NAT；
2. NAT traversal via proxy：适用于任意 NAT，但代理必须支持 UDP 转发，官方列举 Snell、Shadowsocks、Trojan、SOCKS5、WireGuard；使用付费代理会消耗代理流量；
3. Static port forwarding：有公网 IP 且能配置路由器时使用。

如果客户端和 server 在同一局域网，Ponte 会自动走局域网直连。Surge Mac 6 的 Ponte 2.0 可同时启用多个穿透通道并自动选择最快通道，还增加了 IPv6 直连通道。[Surge Ponte Guide](https://kb.nssurge.com/surge-knowledge-base/guidelines/ponte)、[NAT Types](https://kb.nssurge.com/surge-knowledge-base/technotes/nat-type)、[Surge Mac 6.0 Release Note](https://kb.nssurge.com/surge-knowledge-base/release-notes/surge-mac-6-release-note)

因此“不使用 Tailscale”不等于“不依赖任何中继”：如果家庭网络不是 Full Cone NAT，也没有可用 IPv6/端口转发，仍需一个支持 UDP 的代理作为 Ponte 穿透通道。

### 4. TCP、HTTP 与 WebSocket

Ponte 明确支持访问任意指定端口上的 HTTP 服务，也可用于 SMB 文件共享和访问家庭子网，说明它不是只服务于 Surge Dashboard 的专用通道。[Surge Ponte Guide](https://kb.nssurge.com/surge-knowledge-base/guidelines/ponte)

herdr-mobile 的 HTTP 和 WebSocket 都建立在 TCP 上，原则上可通过该设备通道工作。Surge iOS 发布说明还记录过“修复新版 Safari 在代理模式下非 HTTPS WebSocket 的兼容问题”，说明 Surge 的代理路径确实处理 `ws://` 流量。[Surge iOS Release Notes](https://kb.nssurge.com/surge-knowledge-base/release-notes/surge-ios)

不过官方 Ponte 指南没有给出针对长连接、iOS 锁屏和蜂窝/Wi-Fi 切换的可用性保证；正式替换前仍应在目标 iPhone 上做 WebSocket 长连接、切网和重连实测。

## 与当前 herdr-mobile 的适配

### 最简 Ponte 部署

假设 Mac 的 Ponte 名称为 `home-mac`：

```bash
HERDR_MOBILE_ALLOWED_ORIGINS='http://home-mac.sgponte:8787' \
HERDR_MOBILE_COOKIE_SECURE=0 \
./scripts/start.sh
```

iPhone 在 Surge iOS 中启用 Ponte 后访问：

```text
http://home-mac.sgponte:8787/
```

保持不变的安全措施：

- 后端仍只监听 `127.0.0.1`；
- token 默认启用；
- session cookie 仍为 HttpOnly + SameSite=Strict，只是无法带 `Secure`；
- HTTP 会话交换和 WebSocket 仍严格校验 Origin；
- pane allowlist、实时身份校验、输入限制、CSP 和纯文本 DOM 渲染均不变。

### HTTP 的安全含义

Ponte 官方承诺底层端到端加密，所以 Ponte 内的明文 HTTP 不等同于在公网裸奔；外部链路仍处于加密通道中。但浏览器无法感知 Ponte 的底层加密，因此：

- 页面不是浏览器意义上的 secure context；
- `Secure` cookie 必须关闭；
- service worker 通常不能在该非 localhost HTTP origin 注册，PWA 离线壳能力会失效；
- 浏览器 UI 会显示非 HTTPS；
- 安全属性依赖 Surge/Ponte 正确运行，而不是标准 Web PKI。

官方资料没有说明 `.sgponte` 自动 HTTPS 或证书签发能力，因此不能假定存在类似 Tailscale Serve 的自动 HTTPS。

### 若必须保留 HTTPS

可选方案：

1. 在 Mac 的 loopback 上增加 Caddy/nginx 等 TLS 反向代理；
2. 使用自己控制的真实域名，并通过 DNS-01 获取公信证书；
3. 在 Surge iOS 上将该域名通过 `DEVICE:<PonteName>` 发往 Mac；
4. 反向代理把请求转发到 `127.0.0.1:8787`。

也可以使用自建 CA，但需要在 iPhone 上安装并显式信任根证书。两种方式都比 Tailscale Serve 自动 HTTPS 更复杂，且应另外验证 WebSocket upgrade。

## Ponte 与 Tailscale 对比

| 维度 | Surge Ponte | Tailscale + Serve |
|---|---|---|
| loopback 服务访问 | 官方明确支持 `.sgponte` 映射到远端 `127.0.0.1` | Serve 反代 loopback |
| 链路加密 | 官方称始终端到端加密 | WireGuard 加密 |
| 浏览器可信 HTTPS | 官方未说明自动提供 | Serve 自动提供 tailnet HTTPS |
| 身份体系 | iCloud 同步密钥、同账号设备；支持分享 | tailnet 身份、设备、用户和 ACL |
| NAT 失败回退 | 需 UDP 代理、IPv6 或静态端口 | 通常通过 DERP 中继 |
| iPhone 前提 | Surge iOS 必须启用，且只能作 client | Tailscale App 必须连接 |
| 当前项目改动 | Origin 改为 `.sgponte`；简单方案需关闭 Secure cookie | 当前 README 与脚本已经按此设计 |
| 多用户/细粒度授权 | 官方 Ponte 指南未描述 ACL 模型 | Tailscale ACL/Grants 更成熟 |

## 推荐决策

### 可以删除 Tailscale 的条件

以下条件全部满足时，Ponte 足够：

- Mac 已有 Surge 5/6，iPhone 已有支持 Ponte 的 Surge iOS；
- 两端能通过同一 iCloud 或 Ponte 分享互相发现；
- Ponte 诊断确认外网通道稳定；
- 只供本人或少数受信任 Ponte 设备使用；
- 接受 `http://*.sgponte` + Ponte 底层 E2E 加密；
- 接受 Secure cookie 与 service worker/PWA 离线能力降级；
- 保留 herdr-mobile token 认证。

### 应保留 Tailscale 的条件

出现任一情况时更建议 Tailscale：

- 必须使用 Safari 原生信任的 HTTPS；
- 必须保留 Secure cookie 和完整 PWA secure-context 能力；
- 需要成熟 ACL、设备撤销、多人访问或审计；
- Ponte 必须依赖不稳定或昂贵的 UDP 代理；
- 不希望手机持续使用 Surge VPN 配置；
- 希望部署模型更容易向其他人说明和复现。

## 建议的验证清单

在真正卸载 Tailscale 前，先做并行 A/B 验证：

1. Mac 开启 Ponte server，记录设备名称和选中的通道；
2. iPhone 关闭 Wi-Fi、仅用蜂窝网络打开 `http://<name>.sgponte:8787/healthz`；
3. 登录 herdr-mobile，确认 snapshot 和 pane output；
4. 测试发送文字、Enter、Ctrl+C 和审批动作；
5. 前后台切换 Safari、锁屏 5 分钟后恢复；
6. 在 Wi-Fi 与蜂窝之间切换，观察 WebSocket 自动重连；
7. 确认 Surge Ponte 诊断没有走意外或高费用的代理；
8. 再决定是否停止或卸载 Tailscale。

## 主要来源

- [Surge Ponte Guide](https://kb.nssurge.com/surge-knowledge-base/guidelines/ponte)
- [NAT Types](https://kb.nssurge.com/surge-knowledge-base/technotes/nat-type)
- [Surge Mac 6.0 Release Note](https://kb.nssurge.com/surge-knowledge-base/release-notes/surge-mac-6-release-note)
- [Surge iOS Release Notes](https://kb.nssurge.com/surge-knowledge-base/release-notes/surge-ios)
