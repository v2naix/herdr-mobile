# iOS 26 native client primitives

Research for [Identify the iOS 26 primitives and constraints for the native client](https://github.com/v2naix/herdr-mobile/issues/2). Sources are limited to Apple primary documentation and WWDC sessions.

## Decision-relevant findings

### Terminal reader: SwiftUI is sufficient for the prototype

Use a native `ScrollView` rather than embedding the PWA or starting with a UIKit text view.

- `ScrollPosition` gives programmatic control over a scroll view, including scrolling to an edge. This directly supports “return to bottom.”
- `onScrollGeometryChange` can reduce `ScrollGeometry` to a small equatable value, such as “near the bottom,” and update follow state only when that value changes. Apple describes this as a performant way to react to content offset, content size, and related geometry.
- `onScrollPhaseChange` exposes whether scrolling is interacting, decelerating, animating, or idle. The prototype can therefore distinguish a user leaving the bottom from a programmatic bottom scroll instead of inferring intent from every content update.
- SwiftUI’s iOS 26 implementation includes improved scheduling for scrolling and fewer dropped frames at high refresh rates. This does not remove the need for real-device testing with rapidly changing text.

Prototype implication: model follow behavior explicitly as `following` versus `readingHistory`. Append simulated output only when testing the rendering path; when `following`, use `ScrollPosition` to move to the bottom marker. Enter `readingHistory` when user-driven scrolling leaves a bottom tolerance, and expose a bottom button that restores `following`. Keep line wrapping as a separate display mode so it can be tested without changing connection state.

Sources:

- Apple, [`ScrollPosition`](https://developer.apple.com/documentation/swiftui/scrollposition)
- Apple, [`onScrollGeometryChange(for:of:action:)`](https://developer.apple.com/documentation/swiftui/view/onscrollgeometrychange(for:of:action:))
- Apple, [`onScrollPhaseChange(_:)`](https://developer.apple.com/documentation/swiftui/view/onscrollphasechange(_:))
- Apple, [What’s new in SwiftUI, WWDC24 — scrolling enhancements at 16:18](https://developer.apple.com/videos/play/wwdc2024/10144/?time=978)
- Apple, [What’s new in SwiftUI, WWDC25 — scrolling performance](https://developer.apple.com/videos/play/wwdc2025/256/)

### Networking: separate the HTTP and WebSocket decisions

- Apple recommends `URLSession` for HTTP/HTTPS.
- For new WebSocket code Apple offers `URLSessionWebSocketTask` and Network framework, and recommends Network framework unless there is a specific reason to use `URLSession`.
- iOS 26 provides the new Swift `NetworkConnection` API introduced in 2025. Apple describes it as tightly integrated with Swift’s type system and structured concurrency. This is the leading WebSocket candidate for an iOS 26-only app.
- Both URLSession and Network framework use Apple’s modern built-in TLS stack and trust evaluation. The configured server should remain HTTPS/WSS with a publicly trusted certificate; the app should not add an ATS exception or custom certificate bypass.
- Apple’s public documentation retrieved here does not establish that a cookie created by an HTTP `URLSession` exchange is automatically attached to a Network-framework WebSocket handshake. It also does not unambiguously document cookie behavior for `URLSessionWebSocketTask`. Authentication must therefore be an explicit protocol decision and should not assume browser cookie behavior.

Design implication: use `URLSession` for setup/session HTTP. Evaluate `NetworkConnection` first for WebSocket transport, but make the authentication ticket choose an explicit handshake credential mechanism that works for native clients while preserving the browser client’s cookie and Origin defenses.

Sources:

- Apple, [TN3151: Choosing the right networking API](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)
- Apple, [`URLSessionWebSocketTask`](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask)
- Apple, [`HTTPCookie.requestHeaderFields(with:)`](https://developer.apple.com/documentation/foundation/httpcookie/requestheaderfields(with:))
- Apple, [Handling an authentication challenge](https://developer.apple.com/documentation/foundation/handling-an-authentication-challenge)

### Credential storage: use a foreground-only, device-bound Keychain item

Apple says to use the most restrictive Keychain accessibility compatible with the app. A bootstrap token for this foreground-only personal control surface should be stored as an internet-password item keyed by server and account, with `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` as the preferred accessibility:

- it is available only while the device is unlocked;
- it requires a device passcode;
- removing the passcode deletes the item;
- `ThisDeviceOnly` prevents migration to a different device through backup restoration.

If requiring a passcode is rejected later, the less restrictive fallback is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Face ID/user-presence protection can be added with `SecAccessControl`, but it is not needed for the agreed first release.

Sources:

- Apple, [Restricting keychain item accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility)
- Apple, [Adding a password to the keychain](https://developer.apple.com/documentation/security/adding-a-password-to-the-keychain)
- Apple, [`kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`](https://developer.apple.com/documentation/security/ksecattraccessiblewhenpasscodesetthisdeviceonly)

### Lifecycle: treat the first release as foreground-connected

Use SwiftUI’s `scenePhase` as an input to the connection state machine:

- connect or reconnect when the scene becomes active;
- stop retries and close/cancel the live connection when it becomes inactive or backgrounded;
- refresh the pane snapshot after returning active before accepting operations against a previously selected pane.

Apple notes that iOS suspends apps shortly after they move to the background. Background URLSession is specifically for HTTP transfers, not an indefinite monitoring socket. iOS 26 continuous background tasks begin from a user action and represent finite, progress-reporting work that the user can cancel; they are not a fit for passive agent monitoring. Reliable blocked-agent alerts should therefore remain a later server-to-APNs design, as already scoped by the map.

Sources:

- Apple, [`scenePhase`](https://developer.apple.com/documentation/swiftui/scenephase)
- Apple, [TN3151: HTTP background sessions and iOS suspension](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api#HTTP)
- Apple, [Performing long-running tasks on iOS and iPadOS](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)

## Recommended constraints for following tickets

1. Build the terminal reader prototype entirely in SwiftUI using `ScrollPosition`, `onScrollGeometryChange`, and `onScrollPhaseChange`; validate on a real iOS 26 iPhone.
2. Use `URLSession` for HTTPS setup/session calls and evaluate iOS 26 `NetworkConnection` first for WebSocket transport.
3. Do not make native authentication depend implicitly on browser Cookie/Origin behavior; specify the native handshake explicitly.
4. Store the long-lived bootstrap token as a device-bound, passcode-protected Keychain item; keep short-lived session material in memory where possible.
5. Make scene activity part of the connection state machine and promise live monitoring only while active in the first release.
6. Keep valid HTTPS/WSS and system trust evaluation; add no ATS exception or certificate bypass.
