# Herdr Mobile for iOS 26

这是正式的 iOS 客户端工程，与 `ios/prototypes/` 下的实验代码无关。

## 当前功能

- 配置并规范化一个 HTTPS Mac 地址；非 HTTPS、带凭据或带路径的地址会被拒绝。
- 通过 `Authorization` 请求 `/api/native/session`，用 bootstrap token 换取仅存于内存的短期会话。
- 使用 `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` 将 bootstrap token 保存为按 HTTPS origin 区分的 internet-password Keychain 项；不提供弱化回退。
- 支持冷启动恢复、经确认更换服务器，以及服务器不可达时仍会清除本地数据的退出登录。
- 使用 iOS 26 `NetworkConnection<WebSocket>` 和系统 TLS 建立显式 bearer 握手，限制消息为 8 KiB 并自动响应 ping。
- 显示完整的 agent pane 快照，使用 `pane_id + pane_ref + subscription_id` 打开详情，并跟随最新的有界完整输出快照。
- 阅读历史时冻结可见快照和滚动位置，只保留最新待处理输出；可明确返回底部并恢复跟随。
- 默认自动换行，可临时切换到支持横向滚动的原始宽度；离开 pane 后恢复默认模式。
- 提供 reader-first 命令面板和独立的大尺寸回复编辑器；所有文本、固定按键和审批动作均等待服务端按 `command_id` 确认。
- 每个 pane 最多一个命令等待确认；失败或结果未知时保留回复草稿，断线和超时不会自动重发，明确重试会使用新的命令 ID。
- 仅在前台保持连接；进入后台会暂停连接和重试并保留旧快照，回到前台后使用带抖动的有上限指数退避恢复。
- pane 选择是与连接无关的期望订阅；新连接必须先收到权威 pane 快照并重新校验 `pane_id + pane_ref`，身份缺失或变化时保留旧详情且禁用操作。
- 显式认证拒绝最多触发一次静默会话交换；TLS、协议、后端和普通网络故障使用不同的可操作状态，不提供 TLS 绕过。
- 按 `server_epoch`、订阅身份和 revision 丢弃过期、重复及乱序消息；完整快照的 revision 间隔可安全直接应用。诊断页只显示服务器地址、状态、同步时间、重试次数及 epoch/version 等净化信息。

## 打开与验证

需要完整的 Xcode 26 和 iOS 26 SDK：

```bash
open ios/HerdrMobile/HerdrMobile.xcodeproj
```

在 Xcode 中选择自己的开发团队和 iOS 26 iPhone 后运行 `HerdrMobile` target。项目不包含 ATS 例外、自定义证书信任或证书绕过。

顶层状态及聚焦集成检查可以在只有 Swift 6.2+ 命令行工具的环境运行：

```bash
cd ios/HerdrMobile
swift run HerdrMobileCoreTests
```

候选版本的完整自动化命令、Safari PWA smoke 步骤、目标 iPhone 验收清单及发布阻断规则见 [`../../docs/release/ios-0.1.0-rc.2.md`](../../docs/release/ios-0.1.0-rc.2.md)。命令行检查不能替代完整 Xcode 26 和目标 iPhone 验收。
