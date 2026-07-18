import Combine
import Foundation

public enum AppScreen: Equatable, Sendable {
    case setup
    case configured
}

public struct AppViewState: Equatable, Sendable {
    public var screen: AppScreen
    public var origin: String
    public var token: String
    public var error: String?
    public var isWorking: Bool

    public init(
        screen: AppScreen = .setup,
        origin: String = "",
        token: String = "",
        error: String? = nil,
        isWorking: Bool = false
    ) {
        self.screen = screen
        self.origin = origin
        self.token = token
        self.error = error
        self.isWorking = isWorking
    }
}

public enum DestructiveAction: Equatable, Sendable {
    case replaceServer
    case logout
}

public struct NativeSession: Equatable, Sendable {
    public let token: String
    public let expiresAt: Date

    public init(token: String, expiresAt: Date) {
        self.token = token
        self.expiresAt = expiresAt
    }
}

public enum NativeSessionError: Error, Equatable, Sendable {
    case invalidCredentials
    case tls
    case transport
    case invalidResponse
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case passcodeRequired
    case unavailable
}

@MainActor
public protocol NativeSessionServing: AnyObject {
    func exchange(origin: String, bootstrapToken: String) async throws -> NativeSession
    func revoke(origin: String, sessionToken: String) async throws
}

@MainActor
public protocol CredentialStoring: AnyObject {
    func loadToken(for origin: String) throws -> String?
    func saveToken(_ token: String, for origin: String) throws
    func deleteToken(for origin: String) throws
}

@MainActor
public protocol OriginPersisting: AnyObject {
    func loadOrigin() -> String?
    func saveOrigin(_ origin: String)
    func clearOrigin()
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var state = AppViewState()
    @Published public private(set) var pendingConfirmation: DestructiveAction?

    private let sessions: NativeSessionServing
    private let credentials: CredentialStoring
    private let configuration: OriginPersisting
    private var nativeSession: NativeSession?

    public init(
        sessions: NativeSessionServing,
        credentials: CredentialStoring,
        configuration: OriginPersisting
    ) {
        self.sessions = sessions
        self.credentials = credentials
        self.configuration = configuration
    }

    public func start() async {
        guard let origin = configuration.loadOrigin() else { return }
        state = AppViewState(origin: origin, isWorking: true)
        do {
            guard let token = try credentials.loadToken(for: origin) else {
                state.error = "未找到已保存的令牌，请重新输入。"
                state.isWorking = false
                return
            }
            nativeSession = try await sessions.exchange(origin: origin, bootstrapToken: token)
            state = AppViewState(screen: .configured, origin: origin)
        } catch {
            if error as? NativeSessionError == .invalidCredentials {
                try? credentials.deleteToken(for: origin)
            }
            state = AppViewState(origin: origin, error: message(for: error))
        }
    }

    public func updateOrigin(_ origin: String) {
        state.origin = origin
        state.error = nil
    }

    public func updateToken(_ token: String) {
        state.token = token
        state.error = nil
    }

    public func submitSetup(origin rawOrigin: String, token: String) async {
        let origin: String
        do {
            origin = try OriginNormalizer.normalize(rawOrigin)
        } catch {
            state.error = "请输入不含路径的有效 HTTPS 地址。"
            state.isWorking = false
            return
        }
        guard !token.isEmpty else {
            state.origin = origin
            state.error = "请输入令牌。"
            return
        }

        state.origin = origin
        state.isWorking = true
        state.error = nil
        do {
            let session = try await sessions.exchange(origin: origin, bootstrapToken: token)
            do {
                try credentials.saveToken(token, for: origin)
            } catch {
                try? await sessions.revoke(origin: origin, sessionToken: session.token)
                throw error
            }
            configuration.saveOrigin(origin)
            nativeSession = session
            state = AppViewState(screen: .configured, origin: origin)
        } catch {
            let rejected = error as? NativeSessionError == .invalidCredentials
            state = AppViewState(
                origin: origin,
                token: rejected ? "" : token,
                error: message(for: error)
            )
        }
    }

    public func requestServerReplacement() {
        pendingConfirmation = .replaceServer
    }

    public func requestLogout() {
        pendingConfirmation = .logout
    }

    public func cancelDestructiveAction() {
        pendingConfirmation = nil
    }

    public func confirmDestructiveAction() async {
        guard pendingConfirmation != nil else { return }
        pendingConfirmation = nil
        let oldOrigin = configuration.loadOrigin() ?? state.origin
        let oldSession = nativeSession

        nativeSession = nil
        configuration.clearOrigin()
        var deletionError: Error?
        do {
            if !oldOrigin.isEmpty {
                try credentials.deleteToken(for: oldOrigin)
            }
        } catch {
            deletionError = error
        }
        state = AppViewState(error: deletionError.map { message(for: $0) })

        if let oldSession, !oldOrigin.isEmpty {
            try? await sessions.revoke(origin: oldOrigin, sessionToken: oldSession.token)
        }
    }

    private func message(for error: Error) -> String {
        switch error {
        case NativeSessionError.invalidCredentials:
            return "令牌无效，请重新输入。"
        case NativeSessionError.tls:
            return "无法验证服务器证书或主机名。请检查 HTTPS 配置。"
        case NativeSessionError.transport:
            return "无法连接服务器，请检查地址和网络后重试。"
        case NativeSessionError.invalidResponse:
            return "服务器返回了不兼容的响应。"
        case CredentialStoreError.passcodeRequired:
            return "请先为此 iPhone 设置设备密码，然后重试。"
        default:
            return "无法安全保存或删除令牌。"
        }
    }
}
