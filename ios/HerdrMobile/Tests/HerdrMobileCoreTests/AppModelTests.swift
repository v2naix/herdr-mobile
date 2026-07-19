import Foundation
import Network
import Security
@_spi(Testing) import HerdrMobileCore

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure(description: message) }
}

@main
@MainActor
struct AppModelTests {
    static func main() async throws {
        try await successfulSetupNormalizesAndPersistsAfterValidation()
        try await setupRejectsInvalidOrigins()
        try await rejectedCredentialsKeepOriginAndClearToken()
        try await passcodeStorageFailureDoesNotAcceptConfiguration()
        try await coldLaunchExchangesStoredBootstrapToken()
        try await backgroundLaunchDoesNotStartMonitoring()
        try await backgroundSuspendsWithoutDiscardingVisibleState()
        try await foregroundResubscribesOnlyAfterAuthoritativeIdentityMatch()
        try await foregroundRefreshesAnExpiredSessionBeforeConnecting()
        try await reusedPaneIDRemainsVisibleAndDisabled()
        try await transientFailuresUseCappedForegroundBackoff()
        try await authenticationRejectionGetsOnlyOneSilentRecovery()
        try await betterNetworkPathReplacesConnectionWithoutResendingCommand()
        try await replacementConnectionDoesNotChaseItsOwnBetterPath()
        try await nonRetryableAndBackendFailuresAreActionable()
        try await diagnosticsExcludeCredentialsAndTerminalContent()
        try await transientAppStateNeverCrossesPersistenceSeams()
        try await nativeHTTPClientUsesEphemeralBearerRequests()
        try keychainStoreUsesPasscodeBoundDeviceOnlyItemsAndDeletesLocally()
        try await nativeWebSocketPolicyCoversHandshakeCloseAndCancellation()
        try await logoutClearsLocalAccessWhenRevocationFails()
        try await confirmedLogoutSurvivesPresentationDismissal()
        try await serverReplacementRequiresConfirmation()
        try await livePaneSnapshotsDriveVisibleNavigationState()
        try await paneStatusGroupsAreOrderedAndKeepUnknownSeparate()
        try await paneGroupSelectionUsesExistingIdentitySafeOpenFlow()
        try await incompatibleProtocolStopsTheNativeConnection()
        try await outputFilteringUsesEpochSubscriptionIdentityAndRevision()
        try await scrollingAwayFreezesVisibleOutputDuringBursts()
        try await returningToBottomAppliesOnlyNewestPendingSnapshot()
        try await quickCommandsResumeFollowingOutput()
        try await widthModeIsIndependentAndResetsAfterLeavingPane()
        try await replyEditorPresentationPreservesReaderContext()
        try await acknowledgedReplyClearsDraftOnlyAfterServerResult()
        try await invalidReplyNeverLeavesTheDevice()
        try await failedReplyRetainsDraftEditorAndReaderPosition()
        try await onePendingCommandGatesCompetingQuickActions()
        try await boundedQuickActionsMapToFixedProtocolOperations()
        try await slashQuickActionSendsSlashText()
        try await disconnectMarksPendingCommandUnknownWithoutResend()
        try await explicitRetryAfterUnknownSendUsesNewCommandID()
        try await commandTimeoutMarksOutcomeUnknownWithoutClearingDraft()
        try nativeProtocolUsesStrictTypedJSON()
        print("HerdrMobileCoreTests: 43 passed")
    }

    static func successfulSetupNormalizesAndPersistsAfterValidation() async throws {
        let sessions = FakeSessions()
        let credentials = MemoryCredentials()
        let configuration = MemoryConfiguration()
        let model = AppModel(sessions: sessions, credentials: credentials, configuration: configuration)

        await model.submitSetup(origin: " HTTPS://Mac.Example.ts.net:443/ ", token: "bootstrap")

        try check(model.state.screen == .configured, "successful setup should configure the app")
        try check(model.state.origin == "https://mac.example.ts.net", "origin should be normalized")
        try check(configuration.origin == "https://mac.example.ts.net", "origin should be persisted")
        try check(try credentials.loadToken(for: "https://mac.example.ts.net") == "bootstrap", "bootstrap token should be secured")
        try check(sessions.exchanges == [.init(origin: "https://mac.example.ts.net", token: "bootstrap")], "server must validate before setup succeeds")
        try check(model.state.token.isEmpty, "configured state must not expose a credential")
    }

    static func setupRejectsInvalidOrigins() async throws {
        let sessions = FakeSessions()
        let model = AppModel(sessions: sessions, credentials: MemoryCredentials(), configuration: MemoryConfiguration())

        for origin in ["http://mac.example", "https://mac.example/path", "https://user@mac.example"] {
            await model.submitSetup(origin: origin, token: "bootstrap")
            try check(model.state.screen == .setup, "invalid origin must remain in setup")
            try check(model.state.error != nil, "invalid origin should be actionable")
        }
        try check(sessions.exchanges.isEmpty, "invalid origins must not receive credentials")
    }

    static func rejectedCredentialsKeepOriginAndClearToken() async throws {
        let model = AppModel(
            sessions: FakeSessions(exchangeError: .invalidCredentials),
            credentials: MemoryCredentials(),
            configuration: MemoryConfiguration()
        )

        await model.submitSetup(origin: "https://Mac.Example/", token: "wrong")

        try check(model.state.screen == .setup, "rejection should return to setup")
        try check(model.state.origin == "https://mac.example", "rejection should retain normalized origin")
        try check(model.state.token.isEmpty, "rejection should clear entered token")
        try check(model.state.error == "令牌无效，请重新输入。", "rejection should explain the next action")
    }

    static func passcodeStorageFailureDoesNotAcceptConfiguration() async throws {
        let sessions = FakeSessions()
        let configuration = MemoryConfiguration()
        let model = AppModel(
            sessions: sessions,
            credentials: MemoryCredentials(saveError: CredentialStoreError.passcodeRequired),
            configuration: configuration
        )

        await model.submitSetup(origin: "https://mac.example", token: "bootstrap")

        try check(model.state.screen == .setup, "storage failure must not configure the app")
        try check(configuration.origin == nil, "storage failure must not persist the origin")
        try check(model.state.error == "请先为此 iPhone 设置设备密码，然后重试。", "passcode failure should be actionable")
        try check(sessions.revocations.count == 1, "temporary session should be revoked after storage failure")
    }

    static func coldLaunchExchangesStoredBootstrapToken() async throws {
        let credentials = MemoryCredentials()
        try credentials.saveToken("stored-bootstrap", for: "https://mac.example")
        let sessions = FakeSessions()
        let model = AppModel(
            sessions: sessions,
            credentials: credentials,
            configuration: MemoryConfiguration(origin: "https://mac.example")
        )

        await model.start()

        try check(model.state.screen == .configured, "valid cold launch should configure the app")
        try check(sessions.exchanges == [.init(origin: "https://mac.example", token: "stored-bootstrap")], "cold launch should exchange the Keychain token")
    }

    static func backgroundLaunchDoesNotStartMonitoring() async throws {
        let live = FakeLiveConnection()
        let sessions = FakeSessions()
        let credentials = MemoryCredentials()
        try credentials.saveToken("bootstrap", for: "https://mac.example")
        let model = AppModel(
            sessions: sessions,
            credentials: credentials,
            configuration: MemoryConfiguration(origin: "https://mac.example"),
            liveConnection: live
        )
        model.setSceneActive(false)

        await model.start()

        try check(model.state.connection == .suspended, "a configured background launch should remain suspended")
        try check(sessions.exchanges.isEmpty, "a background launch should defer session acquisition")
        try check(live.openCount == 0, "a background launch must not start monitoring")
    }

    static func backgroundSuspendsWithoutDiscardingVisibleState() async throws {
        let (model, live, pane) = await modelWithOpenPane(identifiers: ["subscription-1"])
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: pane.paneID, paneRef: pane.paneRef, revision: 1, text: "retained output"
        ))
        await settle()

        model.setSceneActive(false)
        await settle()

        try check(model.state.connection == .suspended, "background should expose the canonical suspended state")
        try check(model.state.panes == [pane], "background should retain the last pane list as stale")
        try check(model.state.selectedPane == pane, "background must not pop the selected pane")
        try check(model.state.outputText == "retained output", "background must retain visible terminal output in memory")
        try check(model.state.selectedPaneIsStale, "background should disable operations against stale identity")
        try check(live.cancelCount == 1, "background should cancel foreground monitoring")
    }

    static func foregroundResubscribesOnlyAfterAuthoritativeIdentityMatch() async throws {
        let (model, live, pane) = await modelWithOpenPane(
            identifiers: ["subscription-1", "subscription-2"]
        )
        model.setSceneActive(false)
        model.setSceneActive(true)
        await settle()

        try check(live.sent.count == 1, "foreground must not subscribe before a fresh pane snapshot")
        live.emit(.hello(protocolVersion: 1, serverEpoch: "epoch-1"))
        await settle()
        try check(live.sent.count == 1, "hello alone is not authoritative pane identity")

        live.emit(.paneSnapshot(serverEpoch: "epoch-1", revision: 2, panes: [pane]))
        await settle()

        try check(live.sent.last == .subscribe(
            subscriptionID: "subscription-2", paneID: pane.paneID,
            paneRef: pane.paneRef, lines: 120
        ), "a matching authoritative identity should restore the desired subscription")
        try check(!model.state.selectedPaneIsStale, "identity-safe restoration should re-enable operations")
    }

    static func foregroundRefreshesAnExpiredSessionBeforeConnecting() async throws {
        let clock = DateBox(Date(timeIntervalSince1970: 1_000))
        let sessions = FakeSessions(sessionExpiry: Date(timeIntervalSince1970: 1_100))
        let credentials = MemoryCredentials()
        try credentials.saveToken("bootstrap", for: "https://mac.example")
        let live = FakeLiveConnection()
        let model = AppModel(
            sessions: sessions,
            credentials: credentials,
            configuration: MemoryConfiguration(origin: "https://mac.example"),
            liveConnection: live,
            now: clock.now
        )
        await model.start()
        model.setSceneActive(false)
        clock.value = Date(timeIntervalSince1970: 1_200)

        model.setSceneActive(true)
        await settle()

        try check(sessions.exchanges.count == 2, "foreground should refresh an expired in-memory session")
        try check(live.openCount == 2, "foreground should connect only after obtaining the replacement session")
    }

    static func reusedPaneIDRemainsVisibleAndDisabled() async throws {
        let (model, live, original) = await modelWithOpenPane(
            identifiers: ["subscription-1", "unused-command"]
        )
        model.setSceneActive(false)
        model.setSceneActive(true)
        live.emit(.hello(protocolVersion: 1, serverEpoch: "epoch-2"))
        let reused = AgentPane(
            paneID: original.paneID, paneRef: "different-terminal", title: "Other",
            status: "working", cwd: "/other", workspaceID: "w2"
        )
        live.emit(.paneSnapshot(serverEpoch: "epoch-2", revision: 1, panes: [reused]))
        await settle()

        try check(model.state.selectedPane == original, "a reused pane ID must not replace the visible stale pane")
        try check(model.state.selectedPaneIsStale, "changed pane_ref should disable detail operations")
        try check(live.sent.count == 1, "identity mismatch must never resubscribe")
        await model.sendQuickCommand(.enter)
        try check(live.sent.count == 1, "identity mismatch must never receive a command")
    }

    static func transientFailuresUseCappedForegroundBackoff() async throws {
        let live = FakeLiveConnection()
        let retryClock = RetryRecorder()
        let model = configuredModel(
            live: live,
            jitter: { 0 },
            retrySleep: retryClock.sleep
        )
        await model.start()

        for _ in 0..<7 {
            live.finish(throwing: NativeConnectionError.transport)
            await settle()
        }

        try check(
            retryClock.delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)],
            "foreground retries should use capped exponential backoff"
        )
        try check(model.state.connection == .reconnecting, "transient failure should remain in reconnecting state until synchronization")
        try check(model.state.retryCount == 7, "diagnostics should expose the bounded retry attempt count")
    }

    static func authenticationRejectionGetsOnlyOneSilentRecovery() async throws {
        let live = FakeLiveConnection()
        let sessions = FakeSessions()
        let credentials = MemoryCredentials()
        try credentials.saveToken("bootstrap", for: "https://mac.example")
        let model = AppModel(
            sessions: sessions,
            credentials: credentials,
            configuration: MemoryConfiguration(origin: "https://mac.example"),
            liveConnection: live
        )
        await model.start()

        live.finish(throwing: NativeConnectionError.authentication)
        await settle()
        try check(sessions.exchanges.count == 2, "explicit rejection should perform one silent bootstrap exchange")
        try check(live.openCount == 2, "successful silent exchange should reconnect with the replacement session")

        live.finish(throwing: NativeConnectionError.authentication)
        await settle()
        try check(model.state.connection == .authenticationRequired, "a repeated rejection should require owner action")
        try check(sessions.exchanges.count == 2, "authentication recovery must never loop")
    }

    static func betterNetworkPathReplacesConnectionWithoutResendingCommand() async throws {
        let (model, live, _) = await modelWithOpenPane(
            identifiers: ["subscription-1", "command-1", "subscription-2"]
        )
        model.presentReplyEditor()
        model.updateReplyDraft("可能已发送")
        await model.sendReply()
        let sentBeforePathChange = live.sent.count

        live.emitPath(.betterPathAvailable)
        await settle()

        try check(model.state.connection == .reconnecting, "a better path should safely replace the foreground connection")
        try check(model.state.command?.status == .outcomeUnknown, "path replacement should preserve an in-flight command as unknown")
        try check(live.sent.count == sentBeforePathChange, "path replacement must never resend a command")
        try check(live.openCount == 2, "a better path should establish one fresh connection")
    }

    static func replacementConnectionDoesNotChaseItsOwnBetterPath() async throws {
        let live = FakeLiveConnection()
        let model = configuredModel(live: live)
        await model.start()
        live.emit(.hello(protocolVersion: 1, serverEpoch: "epoch-1"))
        live.emit(.paneSnapshot(serverEpoch: "epoch-1", revision: 1, panes: []))
        await settle()

        live.emitPath(.betterPathAvailable)
        await settle()
        try check(live.openCount == 2, "a better path should replace the original connection once")

        live.emit(.hello(protocolVersion: 1, serverEpoch: "epoch-1"))
        live.emit(.paneSnapshot(serverEpoch: "epoch-1", revision: 1, panes: []))
        await settle()
        live.emitPath(.betterPathAvailable)
        await settle()

        try check(live.openCount == 2, "the replacement connection must not chase the same better path forever")
        try check(model.state.connection == .online, "ignoring the replacement echo should keep synchronized state online")
    }

    static func nonRetryableAndBackendFailuresAreActionable() async throws {
        let tlsLive = FakeLiveConnection()
        let tlsModel = configuredModel(live: tlsLive)
        await tlsModel.start()
        tlsLive.finish(throwing: NativeConnectionError.tls)
        await settle()

        try check(tlsModel.state.connection == .tlsFailure, "TLS failure should be a canonical non-retryable state")
        let tlsOpenCount = tlsLive.openCount
        tlsModel.retryNow()
        try check(tlsLive.openCount == tlsOpenCount, "TLS failure must offer no automatic or unsafe bypass")

        let backendLive = FakeLiveConnection()
        let backendModel = configuredModel(live: backendLive)
        await backendModel.start()
        backendLive.finish(throwing: NativeConnectionError.backendUnavailable)
        await settle()
        try check(backendModel.state.connection == .backendUnavailable, "backend failure should be distinct from transport loss")
        backendModel.retryNow()
        try check(backendLive.openCount == 2, "backend failure should offer a safe explicit refresh")
    }

    static func diagnosticsExcludeCredentialsAndTerminalContent() async throws {
        let (model, live, pane) = await modelWithOpenPane(identifiers: ["subscription-1"])
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: pane.paneID, paneRef: pane.paneRef, revision: 1,
            text: "terminal-secret-marker"
        ))
        live.emit(.error("server-secret-marker"))
        await settle()

        let rendered = String(reflecting: model.diagnostics)
        try check(!rendered.contains("terminal-secret-marker"), "diagnostics must exclude terminal content")
        try check(!rendered.contains("server-secret-marker"), "diagnostics must sanitize server-provided errors")
        try check(!rendered.contains("bootstrap"), "diagnostics must exclude bootstrap credentials")
        try check(!rendered.contains("short-lived"), "diagnostics must exclude native session credentials")
        try check(model.diagnostics.origin == "https://mac.example", "diagnostics may include the normalized origin")
        try check(model.diagnostics.serverEpoch == "epoch-1", "diagnostics may include protocol identity")
    }

    static func transientAppStateNeverCrossesPersistenceSeams() async throws {
        let sessions = FakeSessions()
        let credentials = MemoryCredentials()
        let configuration = MemoryConfiguration()
        let live = FakeLiveConnection()
        let model = AppModel(
            sessions: sessions,
            credentials: credentials,
            configuration: configuration,
            liveConnection: live,
            identifier: IdentifierSequence(["subscription-1"]).next
        )
        await model.submitSetup(origin: "https://mac.example", token: "bootstrap-secret")
        let pane = AgentPane(
            paneID: "w1:p1", paneRef: "term-1", title: "Agent",
            status: "working", cwd: "/repo", workspaceID: "w1"
        )
        live.emit(.hello(protocolVersion: 1, serverEpoch: "epoch-1"))
        live.emit(.paneSnapshot(serverEpoch: "epoch-1", revision: 1, panes: [pane]))
        await settle()
        await model.openPane(pane)
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: pane.paneID, paneRef: pane.paneRef, revision: 1,
            text: "terminal-persistence-marker"
        ))
        model.updateReplyDraft("draft-persistence-marker")
        await settle()

        try check(configuration.origin == "https://mac.example", "preferences should persist only the normalized origin")
        let persistedCredentials = credentials.values
        try check(persistedCredentials == ["https://mac.example": "bootstrap-secret"], "Keychain should persist only the bootstrap token keyed by origin")
        let persistedDescription = String(reflecting: (configuration.origin, persistedCredentials))
        try check(!persistedDescription.contains("short-lived"), "short-lived sessions must remain memory-only")
        try check(!persistedDescription.contains("terminal-persistence-marker"), "terminal content must remain memory-only")
        try check(!persistedDescription.contains("draft-persistence-marker"), "reply drafts must remain memory-only")
        try check(!persistedDescription.contains("epoch-1"), "diagnostic and protocol identity must remain memory-only")
    }

    static func nativeHTTPClientUsesEphemeralBearerRequests() async throws {
        var requests: [URLRequest] = []
        StubURLProtocol.handler = { request in
            requests.append(request)
            let status = request.httpMethod == "DELETE" ? 204 : 200
            let body = status == 200
                ? Data("{\"token\":\"native-session\",\"expires_in\":60}".utf8)
                : Data()
            return (status, ["Content-Type": "application/json"], body)
        }
        defer { StubURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let client = NativeSessionHTTPClient(
            session: URLSession(configuration: configuration),
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let session = try await client.exchange(
            origin: "https://mac.example",
            bootstrapToken: "bootstrap-secret"
        )
        try await client.revoke(
            origin: "https://mac.example",
            sessionToken: session.token
        )

        try check(requests.count == 2, "exchange and revocation should each perform one request")
        try check(requests[0].url?.absoluteString == "https://mac.example/api/native/session", "exchange should use the fixed native endpoint")
        try check(requests[0].httpMethod == "POST", "exchange should use POST")
        try check(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer bootstrap-secret", "bootstrap token should use only the bearer header")
        try check(requests[0].value(forHTTPHeaderField: "Cookie") == nil, "native exchange must not present browser cookies")
        try check(requests[0].cachePolicy == .reloadIgnoringLocalAndRemoteCacheData, "credential exchange must bypass caches")
        try check(requests[1].httpMethod == "DELETE", "revocation should use DELETE")
        try check(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer native-session", "revocation should use only the short-lived bearer")
        try check(session.expiresAt == Date(timeIntervalSince1970: 1_060), "expiry should derive from the validated response lifetime")
    }

    static func keychainStoreUsesPasscodeBoundDeviceOnlyItemsAndDeletesLocally() throws {
        let items = FakeKeychainItems()
        let store = KeychainCredentialStore(items: items)
        let origin = "https://mac.example:8443"

        try store.saveToken("bootstrap-secret", for: origin)

        let added = try items.addedItem.unwrap("a new token should add one Keychain item")
        try check(
            (added[kSecAttrAccessible as String] as? String)
                == (kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String),
            "Keychain item must require a passcode and remain device-only"
        )
        try check((added[kSecAttrSynchronizable as String] as? Bool) == false, "Keychain item must never synchronize")
        try check((added[kSecAttrServer as String] as? String) == "mac.example", "Keychain item should be scoped to the normalized host")
        try check((added[kSecAttrPort as String] as? Int) == 8443, "Keychain item should preserve a non-default HTTPS port")

        items.copyResult = (errSecSuccess, Data("bootstrap-secret".utf8))
        try check(try store.loadToken(for: origin) == "bootstrap-secret", "saved credentials should be readable through the store")
        try store.deleteToken(for: origin)
        try check(items.deletedQueries.count == 1, "local logout should issue one Keychain deletion")
        try check(items.deletedQueries[0][kSecValueData as String] == nil, "deletion query must not carry or expose credential bytes")
    }

    static func nativeWebSocketPolicyCoversHandshakeCloseAndCancellation() async throws {
        guard #available(macOS 26.0, *) else { return }
        let handshake = try NetworkWebSocketConnection.handshake(
            origin: "https://mac.example:8443",
            sessionToken: "native-session-secret"
        )

        try check(handshake.url.absoluteString == "wss://mac.example:8443/ws", "WebSocket should use the fixed WSS endpoint")
        try check(!handshake.url.absoluteString.contains("native-session-secret"), "session credentials must never enter the URL")
        try check(handshake.authorizationHeader == "Bearer native-session-secret", "native WebSocket authentication should use the handshake header")
        try check(handshake.autoReplyPing, "Network WebSocket should automatically answer ping frames")
        try check(
            NetworkWebSocketConnection.maximumOutgoingMessageSize == 8 * 1024,
            "client-to-server WebSocket messages should retain the 8 KiB limit"
        )
        let maximumTerminalOutput = String(repeating: "x", count: 128 * 1024)
        let outputSnapshot = try JSONSerialization.data(withJSONObject: [
            "type": "output_snapshot",
            "server_epoch": "epoch-1",
            "subscription_id": "subscription-1",
            "pane_id": "w1:p1",
            "pane_ref": "term-1",
            "revision": 1,
            "text": maximumTerminalOutput,
        ])
        try check(outputSnapshot.count > 8 * 1024, "the regression snapshot must exceed the old receive limit")
        try check(
            outputSnapshot.count <= handshake.maximumMessageSize,
            "the native receive limit must fit the server's bounded terminal snapshot"
        )
        try check(
            handshake.maximumMessageSize == NetworkWebSocketConnection.maximumIncomingMessageSize,
            "the handshake should apply the separate bounded server-message limit"
        )
        try check(NetworkWebSocketConnection.normalized(.protocolCode(.policyViolation)) == .authentication, "policy close should request authentication recovery")
        try check(NetworkWebSocketConnection.normalized(.protocolCode(.internalServerError)) == .backendUnavailable, "backend close should remain actionable")
        try check(NetworkWebSocketConnection.normalized(.protocolCode(.tlsHandshake)) == .tls, "TLS close must offer no bypass")
        try check(NetworkWebSocketConnection.normalized(.protocolCode(.protocolError)) == .invalidMessage, "protocol close should stop compatibility retries")
        try check(NetworkWebSocketConnection.normalized(.protocolCode(.messageTooBig)) == .messageTooLarge, "oversized close should preserve the size failure")
        try check(NetworkWebSocketConnection.normalized(.protocolCode(.normalClosure)) == nil, "normal close should not invent a terminal failure")

        let connection = NetworkWebSocketConnection()
        let messages = connection.open(
            origin: "https://127.0.0.1:1",
            sessionToken: "synthetic-test-session"
        )
        connection.cancel()
        var iterator = messages.makeAsyncIterator()
        let messageAfterCancellation = try await iterator.next()
        try check(messageAfterCancellation == nil, "cancellation should terminate the public message stream")
    }

    static func logoutClearsLocalAccessWhenRevocationFails() async throws {
        let credentials = MemoryCredentials()
        try credentials.saveToken("bootstrap", for: "https://mac.example")
        let configuration = MemoryConfiguration(origin: "https://mac.example")
        let live = FakeLiveConnection()
        let model = AppModel(
            sessions: FakeSessions(revokeError: .transport),
            credentials: credentials,
            configuration: configuration,
            liveConnection: live
        )
        await model.start()

        model.requestLogout()
        await model.confirmDestructiveAction()

        try check(model.state.screen == .setup, "logout should return to setup")
        try check(model.state.origin.isEmpty, "logout should clear visible origin")
        try check(configuration.origin == nil, "logout should clear persisted origin")
        try check(try credentials.loadToken(for: "https://mac.example") == nil, "logout should delete Keychain token")
        try check(live.cancelCount == 1, "logout should cancel the live connection")
    }

    static func confirmedLogoutSurvivesPresentationDismissal() async throws {
        let credentials = MemoryCredentials()
        try credentials.saveToken("bootstrap", for: "https://mac.example")
        let configuration = MemoryConfiguration(origin: "https://mac.example")
        let model = AppModel(
            sessions: FakeSessions(),
            credentials: credentials,
            configuration: configuration
        )
        await model.start()

        model.requestLogout()
        let presentedAction = try model.pendingConfirmation
            .unwrap("logout should present confirmation")
        model.cancelDestructiveAction()
        await model.confirmDestructiveAction(presentedAction)

        try check(model.state.screen == .setup, "a confirmed logout should survive SwiftUI dismissing its presentation binding first")
        try check(configuration.origin == nil, "confirmed logout should still clear persisted access")
    }

    static func nativeProtocolUsesStrictTypedJSON() throws {
        let message = try JSONDecoder().decode(NativeServerMessage.self, from: Data("""
        {"type":"hello","protocol_version":1,"server_epoch":"epoch-1"}
        """.utf8))
        try check(message == .hello(protocolVersion: 1, serverEpoch: "epoch-1"), "hello should decode through the typed protocol")

        let data = try JSONEncoder().encode(NativeClientMessage.subscribe(
            subscriptionID: "subscription-1", paneID: "w1:p1",
            paneRef: "term-1", lines: 120
        ))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: AnyHashable]
        try check(object == [
            "type": "subscribe", "subscription_id": "subscription-1",
            "pane_id": "w1:p1", "pane_ref": "term-1", "lines": 120,
        ], "subscribe should encode every required identity field")

        let result = try JSONDecoder().decode(NativeServerMessage.self, from: Data("""
        {"type":"command_error","server_epoch":"epoch-1","command_id":"command-1","error":"stale pane"}
        """.utf8))
        try check(result == .commandError(
            serverEpoch: "epoch-1", commandID: "command-1", error: "stale pane"
        ), "command errors should decode with epoch and correlation identity")

        let commandData = try JSONEncoder().encode(NativeClientMessage.action(
            commandID: "command-2", paneID: "w1:p1",
            paneRef: "term-1", action: "approve_once"
        ))
        let commandObject = try JSONSerialization.jsonObject(with: commandData) as? [String: AnyHashable]
        try check(commandObject == [
            "type": "action", "command_id": "command-2",
            "pane_id": "w1:p1", "pane_ref": "term-1", "action": "approve_once",
        ], "native actions should encode only the fixed correlated shape")
    }

    static func livePaneSnapshotsDriveVisibleNavigationState() async throws {
        let live = FakeLiveConnection()
        let model = configuredModel(live: live)

        await model.start()
        live.emit(.hello(protocolVersion: 1, serverEpoch: "epoch-1"))
        live.emit(.paneSnapshot(
            serverEpoch: "epoch-1",
            revision: 1,
            panes: [AgentPane(
                paneID: "w1:p1", paneRef: "term-1", title: "修复登录",
                status: "blocked", cwd: "/repo", workspaceID: "w1"
            )]
        ))
        await settle()
        live.emit(.paneSnapshot(
            serverEpoch: "epoch-1",
            revision: 3,
            panes: [AgentPane(
                paneID: "w1:p1", paneRef: "term-1", title: "最新标题",
                status: "working", cwd: "/repo", workspaceID: "w1"
            )]
        ))
        live.emit(.paneSnapshot(serverEpoch: "epoch-1", revision: 2, panes: []))
        await settle()

        try check(model.state.connection == .online, "authoritative snapshot should make the app online")
        try check(model.state.panes.map(\.title) == ["最新标题"], "newest complete pane snapshot should replace older revisions")
        try check(model.state.selectedPane == nil, "connection state must not drive navigation")
    }

    static func paneStatusGroupsAreOrderedAndKeepUnknownSeparate() async throws {
        let live = FakeLiveConnection()
        let model = configuredModel(live: live)
        let panes = [
            AgentPane(paneID: "w1:p1", paneRef: "term-1", title: "Unknown", status: "unknown", cwd: "/repo", workspaceID: "w1"),
            AgentPane(paneID: "w1:p2", paneRef: "term-2", title: "Idle", status: "idle", cwd: "/repo", workspaceID: "w1"),
            AgentPane(paneID: "w1:p3", paneRef: "term-3", title: "Working", status: "working", cwd: "/repo", workspaceID: "w1"),
            AgentPane(paneID: "w1:p4", paneRef: "term-4", title: "Done", status: "done", cwd: "/repo", workspaceID: "w1"),
            AgentPane(paneID: "w1:p5", paneRef: "term-5", title: "Blocked", status: "blocked", cwd: "/repo", workspaceID: "w1"),
        ]

        await model.start()
        live.emit(.hello(protocolVersion: 1, serverEpoch: "epoch-1"))
        live.emit(.paneSnapshot(serverEpoch: "epoch-1", revision: 1, panes: panes))
        await settle()

        try check(PaneStatus.primaryOrder == [.blocked, .done, .working, .idle], "console status boxes must have a stable priority order")
        try check(model.state.panes(in: .blocked).map(\.title) == ["Blocked"], "blocked panes should stay in their own group")
        try check(model.state.panes(in: .idle).map(\.title) == ["Idle"], "idle must not absorb unknown panes")
        try check(model.state.panes(in: .unknown).map(\.title) == ["Unknown"], "unknown panes must remain discoverable")
    }

    static func paneGroupSelectionUsesExistingIdentitySafeOpenFlow() async throws {
        let live = FakeLiveConnection()
        let model = configuredModel(live: live, identifiers: ["subscription-1", "subscription-2"])
        let blocked = AgentPane(paneID: "w1:p1", paneRef: "term-1", title: "First blocked", status: "blocked", cwd: "/repo", workspaceID: "w1")
        let secondBlocked = AgentPane(paneID: "w1:p2", paneRef: "term-2", title: "Second blocked", status: "blocked", cwd: "/repo", workspaceID: "w1")

        await model.start()
        live.emit(.hello(protocolVersion: 1, serverEpoch: "epoch-1"))
        live.emit(.paneSnapshot(serverEpoch: "epoch-1", revision: 1, panes: [blocked, secondBlocked]))
        await settle()

        await model.openFirstPane(in: .blocked)
        try check(model.state.selectedPane == blocked, "tapping a status box should open its snapshot-first pane")
        try check(live.sent.last == .subscribe(subscriptionID: "subscription-1", paneID: blocked.paneID, paneRef: blocked.paneRef, lines: 120), "status-box selection must retain the existing identity-safe subscription")

        await model.openPane(secondBlocked)
        try check(model.state.selectedPane == secondBlocked, "the status-box menu should open its chosen pane")
        try check(live.sent.last == .subscribe(subscriptionID: "subscription-2", paneID: secondBlocked.paneID, paneRef: secondBlocked.paneRef, lines: 120), "menu selection must retain the existing identity-safe subscription")

        model.closePane()
        await model.openFirstPane(in: .done)
        try check(model.state.selectedPane == nil, "an empty status box must not fabricate a selection")
        try check(live.sent.count == 2, "an empty status box must not subscribe")
    }

    static func incompatibleProtocolStopsTheNativeConnection() async throws {
        let live = FakeLiveConnection()
        let model = configuredModel(live: live)

        await model.start()
        live.emit(.hello(protocolVersion: 99, serverEpoch: "epoch-1"))
        await settle()

        try check(model.state.connection == .incompatibleProtocol, "unsupported protocol should be actionable")
        try check(live.cancelCount == 1, "unsupported protocol should stop the connection")
    }

    static func outputFilteringUsesEpochSubscriptionIdentityAndRevision() async throws {
        let live = FakeLiveConnection()
        let model = configuredModel(live: live, identifiers: ["subscription-1"])
        let pane = AgentPane(
            paneID: "w1:p1", paneRef: "term-1", title: "Agent",
            status: "working", cwd: "/repo", workspaceID: "w1"
        )
        await model.start()
        live.emit(.hello(protocolVersion: 1, serverEpoch: "epoch-1"))
        live.emit(.paneSnapshot(serverEpoch: "epoch-1", revision: 1, panes: [pane]))
        await settle()

        await model.openPane(pane, lines: 120)
        try check(live.sent == [.subscribe(
            subscriptionID: "subscription-1", paneID: "w1:p1",
            paneRef: "term-1", lines: 120
        )], "opening a pane should send complete identity")

        live.emit(.outputSnapshot(
            serverEpoch: "old-epoch", subscriptionID: "subscription-1",
            paneID: "w1:p1", paneRef: "term-1", revision: 1, text: "old"
        ))
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "other-subscription",
            paneID: "w1:p1", paneRef: "term-1", revision: 2, text: "other"
        ))
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: "w1:p1", paneRef: "term-1", revision: 4, text: "latest full snapshot"
        ))
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: "w1:p1", paneRef: "term-1", revision: 3, text: "out of order"
        ))
        await settle()

        try check(model.state.outputText == "latest full snapshot", "newest current full snapshot should win across a revision gap")
        try check(model.state.selectedPane == pane, "accepted output must not alter navigation")
    }

    static func scrollingAwayFreezesVisibleOutputDuringBursts() async throws {
        let live = FakeLiveConnection()
        let model = configuredModel(live: live, identifiers: ["subscription-1"])
        let pane = AgentPane(
            paneID: "w1:p1", paneRef: "term-1", title: "Agent",
            status: "working", cwd: "/repo", workspaceID: "w1"
        )
        await model.start()
        live.emit(.hello(protocolVersion: 1, serverEpoch: "epoch-1"))
        live.emit(.paneSnapshot(serverEpoch: "epoch-1", revision: 1, panes: [pane]))
        await settle()
        await model.openPane(pane)
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: "w1:p1", paneRef: "term-1", revision: 1, text: "visible"
        ))
        await settle()

        model.userScrolledAwayFromBottom()
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: "w1:p1", paneRef: "term-1", revision: 2, text: "pending one"
        ))
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: "w1:p1", paneRef: "term-1", revision: 3, text: "pending newest"
        ))
        await settle()

        try check(model.state.readerMode == .readingHistory, "scrolling away should enter history reading")
        try check(model.state.outputText == "visible", "history reading should freeze the visible snapshot")
        try check(model.state.hasPendingOutput, "new output should expose a return-to-bottom control")
    }

    static func returningToBottomAppliesOnlyNewestPendingSnapshot() async throws {
        let (model, live, pane) = await modelWithOpenPane(identifiers: ["subscription-1"])
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: pane.paneID, paneRef: pane.paneRef, revision: 1, text: "visible"
        ))
        await settle()
        model.userScrolledAwayFromBottom()
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: pane.paneID, paneRef: pane.paneRef, revision: 2, text: "discarded pending"
        ))
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: pane.paneID, paneRef: pane.paneRef, revision: 5, text: "newest pending"
        ))
        await settle()

        model.returnToBottom()

        try check(model.state.readerMode == .following, "bottom return should restore following")
        try check(model.state.outputText == "newest pending", "bottom return should apply the newest full snapshot once")
        try check(!model.state.hasPendingOutput, "bottom return should clear the new-output indicator")
        model.returnToBottom()
        try check(model.state.outputText == "newest pending", "repeated bottom return must not reapply discarded snapshots")
    }

    static func quickCommandsResumeFollowingOutput() async throws {
        let (model, live, pane) = await modelWithOpenPane(
            identifiers: ["subscription-1", "command-1"]
        )
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: pane.paneID, paneRef: pane.paneRef, revision: 1, text: "visible"
        ))
        await settle()
        model.userScrolledAwayFromBottom()
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: pane.paneID, paneRef: pane.paneRef, revision: 2, text: "command menu"
        ))
        await settle()

        await model.sendQuickCommand(.slash)

        try check(model.state.readerMode == .following, "a quick command should resume live output")
        try check(model.state.outputText == "command menu", "resuming should reveal pending output immediately")
        try check(!model.state.hasPendingOutput, "resuming should clear the new-output indicator")
    }

    static func widthModeIsIndependentAndResetsAfterLeavingPane() async throws {
        let (model, live, pane) = await modelWithOpenPane(identifiers: ["subscription-1"])
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: pane.paneID, paneRef: pane.paneRef, revision: 1, text: "visible"
        ))
        await settle()
        model.userScrolledAwayFromBottom()
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: pane.paneID, paneRef: pane.paneRef, revision: 2, text: "pending"
        ))
        await settle()

        model.setReaderWidth(.original)

        try check(model.state.readerWidth == .original, "original-width mode should be visible")
        try check(model.state.readerMode == .readingHistory, "width changes must not alter follow state")
        try check(model.state.outputText == "visible", "width changes must not replace the frozen snapshot")
        try check(model.state.hasPendingOutput, "width changes must retain pending output")
        try check(live.sent.count == 1, "width changes must not resubscribe")

        model.closePane()
        try check(model.state.readerWidth == .wrapped, "leaving a pane should restore wrapped lines")
    }

    static func replyEditorPresentationPreservesReaderContext() async throws {
        let (model, live, pane) = await modelWithOpenPane(identifiers: ["subscription-1"])
        live.emit(.outputSnapshot(
            serverEpoch: "epoch-1", subscriptionID: "subscription-1",
            paneID: pane.paneID, paneRef: pane.paneRef, revision: 1, text: "reader context"
        ))
        await settle()
        model.userScrolledAwayFromBottom()

        model.presentReplyEditor()
        model.updateReplyDraft("请继续")

        try check(model.state.isReplyEditorPresented, "Reply should present the dedicated editor")
        try check(model.state.replyDraft == "请继续", "unsent reply text should remain in memory")
        model.dismissReplyEditor()
        try check(!model.state.isReplyEditorPresented, "closing should dismiss the reply editor")
        try check(model.state.outputText == "reader context", "closing the editor should preserve the visible snapshot")
        try check(model.state.readerMode == .readingHistory, "closing the editor should preserve the reading position mode")
        try check(model.state.replyDraft == "请继续", "closing the editor should not discard an unsent reply")
        try check(live.sent.count == 1, "editor presentation must not alter the subscription")
    }

    static func acknowledgedReplyClearsDraftOnlyAfterServerResult() async throws {
        let (model, live, pane) = await modelWithOpenPane(
            identifiers: ["subscription-1", "command-1"]
        )
        model.presentReplyEditor()
        model.updateReplyDraft("请继续")

        await model.sendReply()

        try check(model.state.command?.status == .pending, "reply should remain pending until acknowledgement")
        try check(model.state.replyDraft == "请继续", "pending reply must retain its draft")
        try check(model.state.isReplyEditorPresented, "pending reply must retain its editor")
        try check(live.sent.last == .sendText(
            commandID: "command-1", paneID: pane.paneID,
            paneRef: pane.paneRef, text: "请继续"
        ), "reply should send a correlated bounded text command")

        live.emit(.commandAck(serverEpoch: "epoch-1", commandID: "command-1"))
        await settle()

        try check(model.state.command?.status == .acknowledged, "ack should be visible as success")
        try check(model.state.replyDraft.isEmpty, "only acknowledged success should clear the draft")
        try check(!model.state.isReplyEditorPresented, "only acknowledged success should dismiss the editor")
        try check(model.state.successFeedbackCount == 1, "acknowledged success should request one success haptic")
    }

    static func invalidReplyNeverLeavesTheDevice() async throws {
        let (model, live, _) = await modelWithOpenPane(identifiers: ["subscription-1"])
        let invalidDrafts = [
            "",
            String(repeating: "é", count: 2_049),
            Array(repeating: "line", count: 21).joined(separator: "\n"),
            "hidden\u{1b}[2J",
        ]

        for draft in invalidDrafts {
            model.updateReplyDraft(draft)
            await model.sendReply()
            try check(model.state.replyDraft == draft, "invalid reply should retain its draft")
            try check(model.state.replyError != nil, "invalid reply should explain the existing limits")
        }
        try check(live.sent.count == 1, "invalid replies must never be sent")
    }

    static func failedReplyRetainsDraftEditorAndReaderPosition() async throws {
        let (model, live, _) = await modelWithOpenPane(
            identifiers: ["subscription-1", "command-1"]
        )
        model.userScrolledAwayFromBottom()
        model.presentReplyEditor()
        model.updateReplyDraft("请继续")
        await model.sendReply()

        live.emit(.commandError(
            serverEpoch: "epoch-1", commandID: "command-1",
            error: "pane identity changed; refresh required"
        ))
        await settle()

        try check(model.state.command?.status == .failed, "server rejection should be a local command failure")
        try check(model.state.command?.message?.contains("identity") == true, "failure should explain the command problem")
        try check(model.state.replyDraft == "请继续", "failed reply must retain its draft")
        try check(model.state.isReplyEditorPresented, "failed reply must retain its editor")
        try check(model.state.readerMode == .readingHistory, "failed reply must preserve reader position mode")
        try check(model.state.warningFeedbackCount == 1, "explicit failure should request warning feedback")
        try check(model.state.connection == .online, "command failure must not redefine connection state")
    }

    static func onePendingCommandGatesCompetingQuickActions() async throws {
        let (model, live, pane) = await modelWithOpenPane(
            identifiers: ["subscription-1", "command-1", "command-2"]
        )

        await model.sendQuickCommand(.enter)
        await model.sendQuickCommand(.deny)

        try check(live.sent.count == 2, "a pending mutation should gate a competing command")
        try check(live.sent.last == .sendKeys(
            commandID: "command-1", paneID: pane.paneID,
            paneRef: pane.paneRef, keys: ["Enter"]
        ), "Enter must use its fixed key operation")

        live.emit(.commandAck(serverEpoch: "epoch-1", commandID: "command-1"))
        await settle()
        await model.sendQuickCommand(.deny)
        try check(live.sent.last == .action(
            commandID: "command-2", paneID: pane.paneID,
            paneRef: pane.paneRef, action: "deny"
        ), "Deny must use its fixed server action")
    }

    static func boundedQuickActionsMapToFixedProtocolOperations() async throws {
        let commands: [QuickCommand] = [
            .enter, .escape, .yes, .no, .allowOnce, .deny, .tab,
            .up, .down, .left, .right, .controlC, .controlL, .controlP, .controlO,
        ]
        let commandIDs = commands.indices.map { "command-\($0 + 1)" }
        let (model, live, pane) = await modelWithOpenPane(
            identifiers: ["subscription-1"] + commandIDs
        )

        for (command, commandID) in zip(commands, commandIDs) {
            await model.sendQuickCommand(command)
            live.emit(.commandAck(serverEpoch: "epoch-1", commandID: commandID))
            await settle()
        }

        let expected: [NativeClientMessage] = [
            .sendKeys(commandID: "command-1", paneID: pane.paneID, paneRef: pane.paneRef, keys: ["Enter"]),
            .sendKeys(commandID: "command-2", paneID: pane.paneID, paneRef: pane.paneRef, keys: ["Escape"]),
            .sendText(commandID: "command-3", paneID: pane.paneID, paneRef: pane.paneRef, text: "y"),
            .sendText(commandID: "command-4", paneID: pane.paneID, paneRef: pane.paneRef, text: "n"),
            .action(commandID: "command-5", paneID: pane.paneID, paneRef: pane.paneRef, action: "approve_once"),
            .action(commandID: "command-6", paneID: pane.paneID, paneRef: pane.paneRef, action: "deny"),
            .sendKeys(commandID: "command-7", paneID: pane.paneID, paneRef: pane.paneRef, keys: ["Tab"]),
            .sendKeys(commandID: "command-8", paneID: pane.paneID, paneRef: pane.paneRef, keys: ["Up"]),
            .sendKeys(commandID: "command-9", paneID: pane.paneID, paneRef: pane.paneRef, keys: ["Down"]),
            .sendKeys(commandID: "command-10", paneID: pane.paneID, paneRef: pane.paneRef, keys: ["Left"]),
            .sendKeys(commandID: "command-11", paneID: pane.paneID, paneRef: pane.paneRef, keys: ["Right"]),
            .sendKeys(commandID: "command-12", paneID: pane.paneID, paneRef: pane.paneRef, keys: ["Ctrl+c"]),
            .sendKeys(commandID: "command-13", paneID: pane.paneID, paneRef: pane.paneRef, keys: ["Ctrl+l"]),
            .sendKeys(commandID: "command-14", paneID: pane.paneID, paneRef: pane.paneRef, keys: ["Ctrl+p"]),
            .sendKeys(commandID: "command-15", paneID: pane.paneID, paneRef: pane.paneRef, keys: ["Ctrl+o"]),
        ]
        try check(Array(live.sent.dropFirst()) == expected, "only fixed allowlisted quick operations should be expressible")
    }

    static func slashQuickActionSendsSlashText() async throws {
        let (model, live, pane) = await modelWithOpenPane(
            identifiers: ["subscription-1", "command-1"]
        )

        await model.sendQuickCommand(.slash)

        try check(live.sent.last == .sendText(
            commandID: "command-1", paneID: pane.paneID,
            paneRef: pane.paneRef, text: "/"
        ), "slash must be sent as text, not as a terminal key")
    }

    static func disconnectMarksPendingCommandUnknownWithoutResend() async throws {
        let (model, live, _) = await modelWithOpenPane(
            identifiers: ["subscription-1", "command-1"]
        )
        model.presentReplyEditor()
        model.updateReplyDraft("继续处理")
        await model.sendReply()

        live.finish()
        await settle()

        try check(model.state.command?.status == .outcomeUnknown, "disconnect before ack should mark the result unknown")
        try check(model.state.command?.canRetry == true, "unknown outcome should offer an explicit retry")
        try check(model.state.command?.message?.contains("可能已经执行") == true, "unknown outcome must warn against exactly-once assumptions")
        try check(model.state.replyDraft == "继续处理", "unknown reply outcome must retain its draft")
        try check(live.sent.count == 2, "disconnect must never resend automatically")
    }

    static func explicitRetryAfterUnknownSendUsesNewCommandID() async throws {
        let (model, live, pane) = await modelWithOpenPane(
            identifiers: ["subscription-1", "command-1", "command-2"]
        )
        model.presentReplyEditor()
        model.updateReplyDraft("继续处理")
        live.sendError = TestFailure(description: "send failed")
        await model.sendReply()
        live.sendError = nil
        await model.sendQuickCommand(.enter)
        try check(live.sent.count == 2, "unknown outcome should require the explicit retry path")

        await model.retryCommand()

        try check(model.state.command?.status == .pending, "explicit retry should become a new pending command")
        try check(model.state.command?.commandID == "command-2", "retry must use a new command ID")
        try check(model.state.command?.message?.contains("上一命令可能已经执行") == true, "retry should retain the original outcome warning")
        try check(live.sent.last == .sendText(
            commandID: "command-2", paneID: pane.paneID,
            paneRef: pane.paneRef, text: "继续处理"
        ), "explicit retry should preserve the original bounded operation")
    }

    static func commandTimeoutMarksOutcomeUnknownWithoutClearingDraft() async throws {
        let live = FakeLiveConnection()
        let model = configuredModel(
            live: live,
            identifiers: ["subscription-1", "command-1"],
            commandTimeout: .milliseconds(1)
        )
        let pane = AgentPane(
            paneID: "w1:p1", paneRef: "term-1", title: "Agent",
            status: "working", cwd: "/repo", workspaceID: "w1"
        )
        await model.start()
        live.emit(.hello(protocolVersion: 1, serverEpoch: "epoch-1"))
        live.emit(.paneSnapshot(serverEpoch: "epoch-1", revision: 1, panes: [pane]))
        await settle()
        await model.openPane(pane)
        model.presentReplyEditor()
        model.updateReplyDraft("保留草稿")
        await model.sendReply()

        try await Task.sleep(for: .milliseconds(10))

        try check(model.state.command?.status == .outcomeUnknown, "timeout before ack should mark the result unknown")
        try check(model.state.replyDraft == "保留草稿", "timeout must retain the reply draft")
        try check(model.state.isReplyEditorPresented, "timeout must retain the reply editor")
        try check(live.sent.count == 2, "timeout must not resend automatically")
    }

    private static func modelWithOpenPane(
        identifiers: [String]
    ) async -> (AppModel, FakeLiveConnection, AgentPane) {
        let live = FakeLiveConnection()
        let model = configuredModel(live: live, identifiers: identifiers)
        let pane = AgentPane(
            paneID: "w1:p1", paneRef: "term-1", title: "Agent",
            status: "working", cwd: "/repo", workspaceID: "w1"
        )
        await model.start()
        live.emit(.hello(protocolVersion: 1, serverEpoch: "epoch-1"))
        live.emit(.paneSnapshot(serverEpoch: "epoch-1", revision: 1, panes: [pane]))
        await settle()
        await model.openPane(pane)
        return (model, live, pane)
    }

    private static func configuredModel(
        live: FakeLiveConnection,
        identifiers: [String] = [],
        commandTimeout: Duration = .seconds(10),
        jitter: @escaping @MainActor () -> Double = { 0.5 },
        retrySleep: @escaping @MainActor (Duration) async throws -> Void = { delay in
            try await Task.sleep(for: delay)
        }
    ) -> AppModel {
        let credentials = MemoryCredentials()
        try! credentials.saveToken("bootstrap", for: "https://mac.example")
        return AppModel(
            sessions: FakeSessions(),
            credentials: credentials,
            configuration: MemoryConfiguration(origin: "https://mac.example"),
            liveConnection: live,
            identifier: IdentifierSequence(identifiers).next,
            commandTimeout: commandTimeout,
            jitter: jitter,
            retrySleep: retrySleep
        )
    }

    static func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    static func serverReplacementRequiresConfirmation() async throws {
        let credentials = MemoryCredentials()
        try credentials.saveToken("bootstrap", for: "https://mac.example")
        let configuration = MemoryConfiguration(origin: "https://mac.example")
        let model = AppModel(sessions: FakeSessions(), credentials: credentials, configuration: configuration)
        await model.start()

        model.requestServerReplacement()
        try check(model.state.screen == .configured, "replacement request alone must not clear state")
        try check(model.pendingConfirmation == .replaceServer, "replacement should require confirmation")

        await model.confirmDestructiveAction()
        try check(model.state.screen == .setup, "confirmed replacement should return to setup")
        try check(configuration.origin == nil, "confirmed replacement should clear prior server")
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let self else { throw TestFailure(description: message) }
        return self
    }
}

@MainActor
private final class FakeKeychainItems: KeychainItemAccessing {
    var copyResult: (OSStatus, Data?) = (errSecItemNotFound, nil)
    var updateStatus: OSStatus = errSecItemNotFound
    var addStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var addedItem: [String: Any]?
    var deletedQueries: [[String: Any]] = []

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) { copyResult }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { updateStatus }
    func add(_ item: [String: Any]) -> OSStatus {
        addedItem = item
        return addStatus
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        deletedQueries.append(query)
        return deleteStatus
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw TestFailure(description: "missing URLProtocol handler")
            }
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
private final class IdentifierSequence {
    private var values: [String]

    init(_ values: [String]) { self.values = values }
    func next() -> String { values.isEmpty ? UUID().uuidString : values.removeFirst() }
}

@MainActor
private final class FakeLiveConnection: NativeConnectionServing {
    var pathEventHandler: (@MainActor (NativePathEvent) -> Void)?
    private var continuation: AsyncThrowingStream<NativeServerMessage, Error>.Continuation?
    var sent: [NativeClientMessage] = []
    var cancelCount = 0
    var openCount = 0
    var sendError: Error?

    func open(origin: String, sessionToken: String) -> AsyncThrowingStream<NativeServerMessage, Error> {
        openCount += 1
        return AsyncThrowingStream { continuation = $0 }
    }

    func send(_ message: NativeClientMessage) async throws {
        sent.append(message)
        if let sendError { throw sendError }
    }

    func cancel() {
        cancelCount += 1
        continuation?.finish()
    }

    func emit(_ message: NativeServerMessage) {
        continuation?.yield(message)
    }

    func emitPath(_ event: NativePathEvent) {
        pathEventHandler?(event)
    }

    func finish(throwing error: Error? = nil) {
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}

@MainActor
private final class RetryRecorder {
    var delays: [Duration] = []

    func sleep(for delay: Duration) async throws {
        delays.append(delay)
    }
}

@MainActor
private final class FakeSessions: NativeSessionServing {
    struct Exchange: Equatable {
        let origin: String
        let token: String
    }

    var exchanges: [Exchange] = []
    var revocations: [(origin: String, token: String)] = []
    var exchangeError: NativeSessionError?
    var revokeError: NativeSessionError?
    var sessionExpiry: Date?

    init(
        exchangeError: NativeSessionError? = nil,
        revokeError: NativeSessionError? = nil,
        sessionExpiry: Date? = nil
    ) {
        self.exchangeError = exchangeError
        self.revokeError = revokeError
        self.sessionExpiry = sessionExpiry
    }

    func exchange(origin: String, bootstrapToken: String) async throws -> NativeSession {
        exchanges.append(.init(origin: origin, token: bootstrapToken))
        if let exchangeError { throw exchangeError }
        return NativeSession(
            token: "short-lived",
            expiresAt: sessionExpiry ?? Date().addingTimeInterval(43_200)
        )
    }

    func revoke(origin: String, sessionToken: String) async throws {
        revocations.append((origin, sessionToken))
        if let revokeError { throw revokeError }
    }
}

@MainActor
private final class DateBox {
    var value: Date

    init(_ value: Date) { self.value = value }
    func now() -> Date { value }
}

@MainActor
private final class MemoryCredentials: CredentialStoring {
    var values: [String: String] = [:]
    let saveError: Error?

    init(saveError: Error? = nil) { self.saveError = saveError }
    func loadToken(for origin: String) throws -> String? { values[origin] }
    func saveToken(_ token: String, for origin: String) throws {
        if let saveError { throw saveError }
        values[origin] = token
    }
    func deleteToken(for origin: String) throws { values.removeValue(forKey: origin) }
}

@MainActor
private final class MemoryConfiguration: OriginPersisting {
    var origin: String?

    init(origin: String? = nil) { self.origin = origin }
    func loadOrigin() -> String? { origin }
    func saveOrigin(_ origin: String) { self.origin = origin }
    func clearOrigin() { origin = nil }
}
