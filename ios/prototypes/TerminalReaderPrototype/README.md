# Terminal Reader Prototype

> **PROTOTYPE — not production code.** This app exists only to resolve [Find the terminal-reading interaction that feels native on iPhone](https://github.com/v2naix/herdr-mobile/issues/3). It uses simulated output and has no backend connection.

Open it with one command from the repository root:

```bash
./scripts/open-ios-terminal-reader-prototype.sh
```

In Xcode, choose the owner’s iPhone running iOS 26, set a Personal Team if Xcode requests signing, and press Run.

## Variants

Use the floating bottom arrows to switch between three deliberately different structures:

- **A — Immersive reader:** terminal owns the screen; compact input remains at the bottom.
- **B — Console deck:** terminal and persistent command/input controls share the screen.
- **C — Focus mode:** uninterrupted terminal; reply controls open as a sheet.

Each variant shares the same interaction experiment:

1. Leave the reader at the bottom and confirm new simulated lines stay visible.
2. Scroll upward and confirm new output does not pull the reader back down.
3. Confirm “回到底部” appears and restores following.
4. Use “+12 行” while both following and reading history.
5. Toggle wrapping and verify long lines can be read at original width.
6. Focus the reply field and verify the software keyboard does not make scrolling erratic.

Record which variant is best, which pieces should be combined, and any gesture failures. The entire prototype belongs on its throwaway branch and should not be merged into `main`.
