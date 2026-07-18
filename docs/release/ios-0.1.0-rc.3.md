# Herdr Mobile iOS 0.1.0 RC.3 验收记录

## 候选版本身份

- 候选引用：`ios-0.1.0-rc.3`
- iOS 版本：`MARKETING_VERSION = 0.1.0`，`CURRENT_PROJECT_VERSION = 3`
- 实现基线：`ios-0.1.0-rc.2`，附加真机退出确认修复
- 目标：iOS 26 真机，通过 Xcode 26 直接安装
- PWA：验收期间继续部署，始终作为回退方案

`ios-0.1.0-rc.3` 必须指向准备安装到目标 iPhone 的 `main` 提交。执行任何检查前记录：

```text
提交（git rev-parse 'ios-0.1.0-rc.3^{commit}'）：`7fc89f6ca7b94e5d4157406104cf1d98a208da49`
Xcode 版本（xcodebuild -version）：Xcode 26.6（Build 17F113），iPhoneOS 26.5 SDK
iPhone 型号：____________________________________________________
iOS 版本：_______________________________________________________
服务端 epoch：___________________________________________________
验收人：________________________ 日期：__________________________
```

不得在此记录服务器域名、token、会话值、终端正文、pane ID/ref 或设备名。

## 自动化检查

从候选引用的干净工作树执行：

```bash
git switch --detach ios-0.1.0-rc.3
.venv/bin/python -m unittest discover -s tests -v
node --test tests/test_reconnect_policy.js
cd ios/HerdrMobile
swift run HerdrMobileCoreTests
swift build
xcrun swiftc -typecheck -parse-as-library \
  -target arm64-apple-macosx26.0 \
  HerdrMobile/Core/*.swift HerdrMobile/HerdrMobileApp.swift HerdrMobile/RootView.swift
cd ../..
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios/HerdrMobile/HerdrMobile.xcodeproj -scheme HerdrMobile \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/herdr-mobile-rc3-debug CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ios/HerdrMobile/HerdrMobile.xcodeproj -scheme HerdrMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/herdr-mobile-rc3-release CODE_SIGNING_ALLOWED=NO build
plutil -lint ios/HerdrMobile/HerdrMobile.xcodeproj/project.pbxproj
git diff --check
```

| 检查 | RC.3 基线 | 候选结果 | 日期/备注 |
|---|---:|---|---|
| Python ASGI/协议/安全回归 | 46 项 | ☑ 通过 ☐ 失败 | 2026-07-18；46 项通过 |
| PWA reconnect-policy | 2 项 | ☑ 通过 ☐ 失败 | 2026-07-18；2 项通过 |
| Swift 顶层及集成检查 | 38 项 | ☑ 通过 ☐ 失败 | 2026-07-18；38 项通过 |
| Swift package build | 通过 | ☑ 通过 ☐ 失败 | 2026-07-18；通过 |
| SwiftUI/Core 直接类型检查 | 通过 | ☑ 通过 ☐ 失败 | 2026-07-18；通过 |
| Xcode generic iOS Debug build | 通过 | ☑ 通过 ☐ 失败 | 2026-07-18；unsigned iPhoneOS 构建通过 |
| Xcode generic iOS Release build | 通过 | ☑ 通过 ☐ 失败 | 2026-07-18；unsigned iPhoneOS 构建通过 |
| Xcode 工程 plist lint | 通过 | ☑ 通过 ☐ 失败 | 2026-07-18；`project.pbxproj: OK` |
| 工作树差异检查 | 通过 | ☑ 通过 ☐ 失败 | 2026-07-18；候选工作树干净，`git diff --check` 通过 |

自动化覆盖包括浏览器/原生认证隔离、会话过期与撤销、epoch/version、完整 pane/output 快照、身份校验、命令确认与去重、PWA 兼容；原生顶层覆盖设置、导航、reader、命令、生命周期、重连、单次重新认证、陈旧身份、诊断、更换服务器及退出登录。聚焦检查覆盖 Keychain 查询策略、原生 HTTP bearer 请求、WebSocket 握手策略、ping、close、取消和消息上限。

系统活动开发者目录仍指向 CommandLineTools，但 `/Applications/Xcode.app` 提供 Xcode 26.6 和 iPhoneOS 26.5 SDK。上述 generic iOS 构建仅通过命令级 `DEVELOPER_DIR` 使用完整 Xcode，不修改系统开发者设置。不得运行 first-launch/repair、请求提权或弱化系统安全；签名、安装和目标设备执行仍必须在下方目标设备步骤完成。

## Safari PWA 回归步骤

共享认证或 WebSocket 代码变化后，在目标 iPhone 的 Safari（不是只在桌面浏览器）执行：

1. 确认部署仍绑定 loopback 并位于既有 HTTPS/tailnet 边界内；不要更改为公网监听。
2. 打开已部署 PWA，确认登录页无缓存的终端内容，URL 不含 token。
3. 输入 bootstrap token，确认登录成功；检查响应使用安全、HttpOnly、SameSite=Strict Cookie，页面和 URL 不出现 token。
4. 确认仅显示 herdr 识别的 agent pane；普通 shell 不可见。
5. 打开一个可安全操作的 pane，确认纯文本输出、更新和返回列表正常。
6. 执行一个事先选定的无破坏性按键或文本探针，确认只执行一次并收到反馈。
7. 临时切换网络或短暂停止后端，确认瞬时故障会重连；认证拒绝会停止循环并要求重新登录。
8. 退出登录，确认即使随后刷新或重开 PWA，也必须重新认证。
9. 从主屏幕启动已安装 PWA，重复列表和详情读取，确认 service worker/manifest 回退仍可用。

```text
Safari PWA：☐ 通过 ☐ 失败
日期：________________  Safari/iOS：________________
非敏感备注：____________________________________________________
```

## 目标 iPhone 验收清单

每项必须针对上方记录的同一候选引用。使用“通过/失败/受阻”，不得用“看起来正常”。

### 安装、设置与凭据

- [x] Xcode Release 构建、签名、安装和冷启动成功，无崩溃或挂起。
- [x] HTTPS origin 会规范化并显示确认；HTTP、路径、嵌入凭据和错误主机被拒绝。
- [ ] 正常系统 TLS 成功；证书、有效期或主机名错误进入 TLS failure，界面不提供绕过。
- [x] 正确 bootstrap token 验证后才保存；错误 token 明确要求替换。
- [ ] 无设备密码时 Keychain 保存失败且不降级；设置设备密码后可成功。
- [ ] 重装/备份迁移测试确认 token 使用 `WhenPasscodeSetThisDeviceOnly`，不会同步到其他设备。
- [x] 冷启动只恢复 origin 和 bootstrap token；短期会话、pane、输出、草稿和导航均不从磁盘恢复。
- [x] 更换服务器必须确认，并清除旧服务器凭据、pane、输出、草稿和导航。
- [x] 在线与离线退出登录都立即清除本地访问；在线时尽力撤销短期会话。

### 列表、详情与 reader

- [x] 列表仅包含 herdr agent pane，并正确显示标题、状态、cwd 和 workspace。
- [x] 详情打开正确 pane；输出是有界纯文本完整快照，不执行 ANSI/HTML。
- [x] following 模式持续跟随底部。
- [x] 用户离开底部后冻结可见内容和精确阅读位置，只保留最新待处理快照。
- [x] “有新输出/返回底部”只应用最新快照并恢复 following。
- [x] 自动换行与原始宽度横向滚动正常；离开详情后恢复自动换行。
- [x] 打开、取消和完成 Reply 后阅读位置不变；未确认草稿不丢失。

### 命令安全

- [x] Reply、Enter、Esc、y、n、Allow once、Deny 均逐项验证。
- [x] Tab、四个方向键、Ctrl+C/L/P/O 均逐项验证；不存在任意按键或 always-allow。
- [x] 每个 pane 最多一个命令 pending，确认前没有成功提示或成功触感。
- [x] acknowledgement 后才显示成功并清除已发送草稿。
- [ ] 显式失败附着于命令，保留草稿和 reader 位置，不伪装成全局断线。
- [ ] 超时和发送后断线显示 outcome unknown，保留草稿并明确警告可能已执行。
- [ ] 重连、前后台恢复和网络切换绝不自动重发 unknown 命令。
- [ ] “明确重试”使用新 command ID，且仍显示原命令可能已执行的警告。

### 生命周期、网络与身份恢复

- [x] inactive/background 立即取消连接和重试，保留旧列表/详情/reader，禁用全部变更操作，无后台监控。
- [x] 回到前台后先同步权威 pane 列表，再恢复期望订阅。
- [x] 短暂断网按带抖动的有上限退避重连；“立即重试”可用；稳定同步后计数重置。
- [x] Wi‑Fi → 蜂窝网络和蜂窝网络 → Wi‑Fi 均安全替换连接，不重复命令。
- [x] 可用路径丢失与恢复、better-path 变化均不会让客户端滞留或附着错误 pane。
- [ ] 短期会话过期或后端重启后只静默交换一次；再次拒绝进入 authentication required，不循环。
- [ ] 普通网络失败不消耗单次认证恢复机会。
- [ ] TLS 和 incompatible protocol 停止自动重试且无绕过；backend/herdr unavailable 保留旧状态并允许安全刷新。
- [ ] 同一 `pane_id + pane_ref` 在权威快照后恢复订阅。
- [ ] pane 缺失时旧详情保持可见、标记陈旧、操作禁用，不自动返回或替换。
- [ ] pane ID 被不同 `pane_ref` 复用时绝不订阅或执行操作。
- [ ] epoch 变化后旧消息、旧订阅和乱序 revision 被忽略。

### 隐私、诊断与稳定性

- [ ] 诊断仅显示规范化 origin、连接状态、同步时间、重试次数、epoch/version 和净化错误。
- [ ] 诊断、系统日志、控制台、URL、Cookie、UserDefaults、缓存和崩溃记录均不含 bootstrap/session token。
- [ ] 诊断、系统日志、UserDefaults、缓存、状态恢复和测试截图均不含终端内容或草稿。
- [ ] 设置、键盘、Reply sheet、纵横滚动、前后台和网络切换过程中无监督受阻的崩溃、挂起或界面锁死。
- [ ] Safari PWA 回归通过，且在整个验收期间可以立即作为回退使用。

### 分阶段真机证据

2026-07-18，目标设备确认退出确认框正常出现，“退出并清除”成功返回设置页，重开后仍要求认证，错误 token 被拒绝，正确 token 可重新登录。随后确认更换服务器的取消与确认清除均正常，离线退出立即清除本地访问，离线重开仍要求认证，恢复网络后可重新登录。设置阶段确认 HTTP、路径、嵌入凭据和错误主机均被拒绝，合法 origin 被规范化；强制结束并冷启动后仅恢复 origin 与 bootstrap token，不恢复 pane、输出、草稿、导航或命令状态。pane 列表过滤与字段、正确详情与纯文本输出、底部跟随、历史冻结、最新输出返回底部、换行与横向滚动重置，以及 Reply 前后的阅读位置和草稿保留均通过。主操作和次级按键均逐项通过，界面无任意按键或 always-allow；每个 pane 最多一个 pending，且仅在 acknowledgement 后显示成功并清除已发送草稿。后台保留状态并禁用操作，前台同步后恢复 pane；短暂断网、立即重试、双向 Wi‑Fi/蜂窝网络切换和路径恢复均通过，无自动重复命令，稳定后重试计数重置。未记录 origin、token、终端内容、pane 身份或设备名。

```text
目标 iPhone 总结：☐ 通过 ☐ 失败 ☐ 受阻
开始：2026-07-18______________ 结束：________________________
失败项编号及非敏感说明：其余目标设备场景及 Safari PWA 尚未完成。
```

## 发布阻断规则

以下任一情况必须将候选标记为 **失败**，不能降级为普通缺陷：

- bootstrap token、短期会话或终端正文泄漏到日志、诊断、URL、偏好设置、缓存、持久状态或测试产物；
- 对错误、缺失或复用身份的 pane 执行操作；
- 未确认命令在重连、恢复或重试期间被自动重复发送；
- 未确认的回复草稿丢失；
- 认证、重连、前后台或网络路径变化后无法恢复且无可操作说明；
- 阻碍日常监督的崩溃、挂起、键盘/滚动故障；
- PWA 被共享协议改动破坏，或验收期间无法作为回退。

安全、身份、重复命令或恢复类修复会使先前候选证据失效；必须创建新候选引用并重新执行受影响检查。完成目标设备清单不等于正式推广，仍需按父规范完成连续七天真实使用试验。
