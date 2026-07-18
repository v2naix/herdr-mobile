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
        print("HerdrMobileCoreTests: 7 passed")
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
        let model = AppModel(
            sessions: FakeSessions(revokeError: .transport),
            credentials: credentials,
            configuration: configuration
        )
        await model.start()

        model.requestLogout()
        await model.confirmDestructiveAction()

        try check(model.state.screen == .setup, "logout should return to setup")
        try check(model.state.origin.isEmpty, "logout should clear visible origin")
        try check(configuration.origin == nil, "logout should clear persisted origin")
        try check(try credentials.loadToken(for: "https://mac.example") == nil, "logout should delete Keychain token")
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
