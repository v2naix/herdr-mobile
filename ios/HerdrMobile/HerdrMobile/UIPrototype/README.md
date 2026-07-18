# Pane UI exploration (throwaway)

Three variants of the iPhone pane list, reader, and command controls, switchable from the floating bottom control in the `HerdrMobile` app.

Run it with Xcode 26 after selecting a simulator or iPhone:

```bash
open ios/HerdrMobile/HerdrMobile.xcodeproj
```

This branch replaces the app entry point with static, read-only sample data: it does not start a connection, read credentials, or send commands. It is intentionally not production code.

- **A · 控制台** — 终端优先；顶部同时显示 Blocked、Done、Working、Idle 四个状态暂存箱。轻点选择该箱的最新任务，长按呼出任务选择菜单；中间显示所选任务，底部保留回复、批准等操作栏。
- **B · 收件箱** — pane inbox first, then a calm document-like reader and reply composer.
- **C · 指挥台** — current decision is primary, activity is secondary, panes remain in a persistent dock.

Use the left/right floating arrows to cycle. The eventual decision belongs in the implementation discussion; preserve this branch as the source for the alternatives and do not merge it into `main`.
