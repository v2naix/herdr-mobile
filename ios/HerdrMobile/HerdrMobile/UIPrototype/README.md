# Pane UI exploration (throwaway)

Three variants of the iPhone pane list, reader, and command controls, switchable from the floating bottom control in the `HerdrMobile` app.

Run it with Xcode 26 after selecting a simulator or iPhone:

```bash
open ios/HerdrMobile/HerdrMobile.xcodeproj
```

This branch replaces the app entry point with static, read-only sample data: it does not start a connection, read credentials, or send commands. It is intentionally not production code.

- **A · 控制台** — 深色终端优先；顶部一行显示 Blocked、Done、Working、Idle 四个图标和各自数量。轻点选择该状态的最新任务，长按呼出任务选择菜单；所选任务的名称和摘要显示在终端卡片标题处。底部第一行用回复、批准、拒绝表达高优先级操作，第二行将 Enter/Esc/y/n 按语义着色，其他键收进菜单。
- **B · 收件箱** — pane inbox first, then a calm document-like reader and reply composer.
- **C · 指挥台** — current decision is primary, activity is secondary, panes remain in a persistent dock.

Use the left/right floating arrows to cycle. The eventual decision belongs in the implementation discussion; preserve this branch as the source for the alternatives and do not merge it into `main`.
