# Herdr Mobile for iOS 26

这是正式的 iOS 客户端工程，与 `ios/prototypes/` 下的实验代码无关。

## 当前功能

- 配置并规范化一个 HTTPS Mac 地址；非 HTTPS、带凭据或带路径的地址会被拒绝。
- 通过 `Authorization` 请求 `/api/native/session`，用 bootstrap token 换取仅存于内存的短期会话。
- 使用 `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` 将 bootstrap token 保存为按 HTTPS origin 区分的 internet-password Keychain 项；不提供弱化回退。
- 支持冷启动恢复、经确认更换服务器，以及服务器不可达时仍会清除本地数据的退出登录。

实时 pane 浏览属于后续票据 #11。

## 打开与验证

需要完整的 Xcode 26 和 iOS 26 SDK：

```bash
open ios/HerdrMobile/HerdrMobile.xcodeproj
```

在 Xcode 中选择自己的开发团队和 iOS 26 iPhone 后运行 `HerdrMobile` target。项目不包含 ATS 例外、自定义证书信任或证书绕过。

顶层状态测试可以在只有 Swift 6.2+ 命令行工具的环境运行：

```bash
cd ios/HerdrMobile
swift run HerdrMobileCoreTests
```
