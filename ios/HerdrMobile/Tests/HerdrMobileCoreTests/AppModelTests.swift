import Foundation
import HerdrMobileCore

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
        try await logoutClearsLocalAccessWhenRevocationFails()
        try await serverReplacementRequiresConfirmation()
        try await livePaneSnapshotsDriveVisibleNavigationState()
        try await incompatibleProtocolStopsTheNativeConnection()
        try await outputFilteringUsesEpochSubscriptionIdentityAndRevision()
        try nativeProtocolUsesStrictTypedJSON()
        print("HerdrMobileCoreTests: 11 passed")
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

    private static func configuredModel(
        live: FakeLiveConnection,
        identifiers: [String] = []
    ) -> AppModel {
        let credentials = MemoryCredentials()
        try! credentials.saveToken("bootstrap", for: "https://mac.example")
        return AppModel(
            sessions: FakeSessions(),
            credentials: credentials,
            configuration: MemoryConfiguration(origin: "https://mac.example"),
            liveConnection: live,
            identifier: IdentifierSequence(identifiers).next
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

@MainActor
private final class IdentifierSequence {
    private var values: [String]

    init(_ values: [String]) { self.values = values }
    func next() -> String { values.isEmpty ? UUID().uuidString : values.removeFirst() }
}

@MainActor
private final class FakeLiveConnection: NativeConnectionServing {
    private var continuation: AsyncThrowingStream<NativeServerMessage, Error>.Continuation?
    var sent: [NativeClientMessage] = []
    var cancelCount = 0

    func open(origin: String, sessionToken: String) -> AsyncThrowingStream<NativeServerMessage, Error> {
        AsyncThrowingStream { continuation = $0 }
    }

    func send(_ message: NativeClientMessage) async throws {
        sent.append(message)
    }

    func cancel() {
        cancelCount += 1
        continuation?.finish()
    }

    func emit(_ message: NativeServerMessage) {
        continuation?.yield(message)
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

    init(exchangeError: NativeSessionError? = nil, revokeError: NativeSessionError? = nil) {
        self.exchangeError = exchangeError
        self.revokeError = revokeError
    }

    func exchange(origin: String, bootstrapToken: String) async throws -> NativeSession {
        exchanges.append(.init(origin: origin, token: bootstrapToken))
        if let exchangeError { throw exchangeError }
        return NativeSession(token: "short-lived", expiresAt: Date().addingTimeInterval(43_200))
    }

    func revoke(origin: String, sessionToken: String) async throws {
        revocations.append((origin, sessionToken))
        if let revokeError { throw revokeError }
    }
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
