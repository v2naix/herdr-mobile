import Combine
import Foundation

public enum AppScreen: Equatable, Sendable {
    case setup
    case configured
}

public enum NativeConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case online
    case offline
    case incompatibleProtocol
    case failed
}

public enum ReaderMode: Equatable, Sendable {
    case following
    case readingHistory
}

public enum ReaderWidthMode: Equatable, Sendable {
    case wrapped
    case original
}

public struct AppViewState: Equatable, Sendable {
    public var screen: AppScreen
    public var origin: String
    public var token: String
    public var error: String?
    public var isWorking: Bool
    public var connection: NativeConnectionState
    public var panes: [AgentPane]
    public var selectedPane: AgentPane?
    public var outputText: String
    public var readerMode: ReaderMode
    public var hasPendingOutput: Bool
    public var readerWidth: ReaderWidthMode
    public var isReplyEditorPresented: Bool
    public var replyDraft: String

    public init(
        screen: AppScreen = .setup,
        origin: String = "",
        token: String = "",
        error: String? = nil,
        isWorking: Bool = false,
        connection: NativeConnectionState = .disconnected,
        panes: [AgentPane] = [],
        selectedPane: AgentPane? = nil,
        outputText: String = "",
        readerMode: ReaderMode = .following,
        hasPendingOutput: Bool = false,
        readerWidth: ReaderWidthMode = .wrapped,
        isReplyEditorPresented: Bool = false,
        replyDraft: String = ""
    ) {
        self.screen = screen
        self.origin = origin
        self.token = token
        self.error = error
        self.isWorking = isWorking
        self.connection = connection
        self.panes = panes
        self.selectedPane = selectedPane
        self.outputText = outputText
        self.readerMode = readerMode
        self.hasPendingOutput = hasPendingOutput
        self.readerWidth = readerWidth
        self.isReplyEditorPresented = isReplyEditorPresented
        self.replyDraft = replyDraft
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
    private let liveConnection: NativeConnectionServing?
    private let identifier: @MainActor () -> String
    private var nativeSession: NativeSession?
    private var connectionTask: Task<Void, Never>?
    private var serverEpoch: String?
    private var paneRevision = 0
    private var subscriptionID: String?
    private var outputRevision = 0
    private var pendingOutputText: String?

    @_spi(Testing) public init(
        sessions: NativeSessionServing,
        credentials: CredentialStoring,
        configuration: OriginPersisting,
        liveConnection: NativeConnectionServing? = nil,
        identifier: @escaping @MainActor () -> String = { UUID().uuidString }
    ) {
        self.sessions = sessions
        self.credentials = credentials
        self.configuration = configuration
        self.liveConnection = liveConnection
        self.identifier = identifier
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
            let session = try await sessions.exchange(origin: origin, bootstrapToken: token)
            nativeSession = session
            state = AppViewState(
                screen: .configured,
                origin: origin,
                connection: liveConnection == nil ? .disconnected : .connecting
            )
            beginLiveConnection(origin: origin, sessionToken: session.token)
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
            state = AppViewState(
                screen: .configured,
                origin: origin,
                connection: liveConnection == nil ? .disconnected : .connecting
            )
            beginLiveConnection(origin: origin, sessionToken: session.token)
        } catch {
            let rejected = error as? NativeSessionError == .invalidCredentials
            state = AppViewState(
                origin: origin,
                token: rejected ? "" : token,
                error: message(for: error)
            )
        }
    }

    public func openPane(_ pane: AgentPane, lines: Int = 120) async {
        guard state.panes.contains(pane), let liveConnection else { return }
        let boundedLines = max(1, min(lines, 300))
        let newSubscriptionID = identifier()
        resetReader()
        state.selectedPane = pane
        subscriptionID = newSubscriptionID
        outputRevision = 0
        do {
            try await liveConnection.send(.subscribe(
                subscriptionID: newSubscriptionID,
                paneID: pane.paneID,
                paneRef: pane.paneRef,
                lines: boundedLines
            ))
        } catch {
            state.connection = .failed
            state.error = "无法订阅 pane 输出。"
        }
    }

    public func closePane() {
        state.selectedPane = nil
        resetReader()
        subscriptionID = nil
        outputRevision = 0
    }

    public func userScrolledAwayFromBottom() {
        guard state.selectedPane != nil, state.readerMode == .following else { return }
        state.readerMode = .readingHistory
    }

    public func returnToBottom() {
        guard state.selectedPane != nil else { return }
        if let pendingOutputText {
            state.outputText = pendingOutputText
        }
        pendingOutputText = nil
        state.hasPendingOutput = false
        state.readerMode = .following
    }

    public func setReaderWidth(_ width: ReaderWidthMode) {
        guard state.selectedPane != nil else { return }
        state.readerWidth = width
    }

    public func presentReplyEditor() {
        guard state.selectedPane != nil else { return }
        state.isReplyEditorPresented = true
    }

    public func dismissReplyEditor() {
        state.isReplyEditorPresented = false
    }

    public func updateReplyDraft(_ draft: String) {
        guard state.selectedPane != nil else { return }
        state.replyDraft = draft
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

        connectionTask?.cancel()
        connectionTask = nil
        liveConnection?.cancel()
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

    private func beginLiveConnection(origin: String, sessionToken: String) {
        guard let liveConnection else { return }
        connectionTask?.cancel()
        let messages = liveConnection.open(origin: origin, sessionToken: sessionToken)
        connectionTask = Task { [weak self] in
            do {
                for try await message in messages {
                    guard !Task.isCancelled else { return }
                    self?.accept(message)
                }
                if self?.state.connection != .incompatibleProtocol {
                    self?.state.connection = .offline
                }
            } catch {
                if self?.state.connection != .incompatibleProtocol {
                    self?.state.connection = .failed
                    self?.state.error = "实时连接已断开。"
                }
            }
        }
    }

    private func accept(_ message: NativeServerMessage) {
        switch message {
        case let .hello(protocolVersion, newEpoch):
            guard protocolVersion == nativeProtocolVersion else {
                state.connection = .incompatibleProtocol
                state.error = "服务器协议不兼容，请升级客户端或服务器。"
                liveConnection?.cancel()
                return
            }
            if serverEpoch != newEpoch {
                serverEpoch = newEpoch
                paneRevision = 0
                outputRevision = 0
                pendingOutputText = nil
                state.hasPendingOutput = false
                state.panes = []
            }
        case let .paneSnapshot(messageEpoch, revision, panes):
            guard messageEpoch == serverEpoch, revision > paneRevision else { return }
            paneRevision = revision
            state.panes = panes
            state.connection = .online
            state.error = nil
        case let .outputSnapshot(
            messageEpoch,
            messageSubscriptionID,
            paneID,
            paneRef,
            revision,
            text
        ):
            guard messageEpoch == serverEpoch,
                  messageSubscriptionID == subscriptionID,
                  let selectedPane = state.selectedPane,
                  selectedPane.paneID == paneID,
                  selectedPane.paneRef == paneRef,
                  revision > outputRevision
            else { return }
            outputRevision = revision
            if state.readerMode == .following {
                pendingOutputText = nil
                state.hasPendingOutput = false
                state.outputText = text
            } else {
                pendingOutputText = text
                state.hasPendingOutput = true
            }
        case let .error(error):
            state.error = error
        }
    }

    private func resetReader() {
        state.outputText = ""
        state.readerMode = .following
        state.hasPendingOutput = false
        state.readerWidth = .wrapped
        state.isReplyEditorPresented = false
        state.replyDraft = ""
        pendingOutputText = nil
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
