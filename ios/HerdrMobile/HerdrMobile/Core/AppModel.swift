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

public enum QuickCommand: Equatable, Sendable {
    case enter
    case escape
    case yes
    case no
    case allowOnce
    case deny
    case tab
    case up
    case down
    case left
    case right
    case controlC
    case controlL
    case controlP
    case controlO
}

public enum CommandStatus: Equatable, Sendable {
    case pending
    case acknowledged
    case failed
    case outcomeUnknown
}

public struct CommandViewState: Equatable, Sendable {
    public let commandID: String
    public var status: CommandStatus
    public var message: String?
    public var canRetry: Bool

    public init(
        commandID: String,
        status: CommandStatus,
        message: String? = nil,
        canRetry: Bool = false
    ) {
        self.commandID = commandID
        self.status = status
        self.message = message
        self.canRetry = canRetry
    }
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
    public var replyError: String?
    public var command: CommandViewState?
    public var successFeedbackCount: Int
    public var warningFeedbackCount: Int

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
        replyDraft: String = "",
        replyError: String? = nil,
        command: CommandViewState? = nil,
        successFeedbackCount: Int = 0,
        warningFeedbackCount: Int = 0
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
        self.replyError = replyError
        self.command = command
        self.successFeedbackCount = successFeedbackCount
        self.warningFeedbackCount = warningFeedbackCount
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

private enum CommandIntent {
    case reply(String)
    case quick(QuickCommand)
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
    private let commandTimeout: Duration
    private var nativeSession: NativeSession?
    private var connectionTask: Task<Void, Never>?
    private var serverEpoch: String?
    private var paneRevision = 0
    private var subscriptionID: String?
    private var outputRevision = 0
    private var pendingOutputText: String?
    private var pendingCommandIntent: CommandIntent?
    private var commandTimeoutTask: Task<Void, Never>?
    private var commandNoticeTask: Task<Void, Never>?

    @_spi(Testing) public init(
        sessions: NativeSessionServing,
        credentials: CredentialStoring,
        configuration: OriginPersisting,
        liveConnection: NativeConnectionServing? = nil,
        identifier: @escaping @MainActor () -> String = { UUID().uuidString },
        commandTimeout: Duration = .seconds(10)
    ) {
        self.sessions = sessions
        self.credentials = credentials
        self.configuration = configuration
        self.liveConnection = liveConnection
        self.identifier = identifier
        self.commandTimeout = commandTimeout
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
        state.replyError = nil
    }

    public func sendReply() async {
        guard state.selectedPane != nil,
              state.connection == .online,
              canStartNewCommand
        else { return }
        guard validateReply(state.replyDraft) else {
            state.replyError = "回复必须为 1–20 行、最多 4096 个 UTF-8 字节，且不能包含控制字符。"
            state.warningFeedbackCount += 1
            return
        }
        state.replyError = nil
        await beginCommand(.reply(state.replyDraft), isRetry: false)
    }

    public func sendQuickCommand(_ command: QuickCommand) async {
        guard canStartNewCommand else { return }
        await beginCommand(.quick(command), isRetry: false)
    }

    public func retryCommand() async {
        guard state.command?.status == .outcomeUnknown,
              let pendingCommandIntent
        else { return }
        await beginCommand(pendingCommandIntent, isRetry: true)
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
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        commandNoticeTask?.cancel()
        commandNoticeTask = nil
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
        markPendingCommandOutcomeUnknown()
        connectionTask?.cancel()
        let messages = liveConnection.open(origin: origin, sessionToken: sessionToken)
        connectionTask = Task { [weak self] in
            do {
                for try await message in messages {
                    guard !Task.isCancelled else { return }
                    self?.accept(message)
                }
                if self?.state.connection != .incompatibleProtocol {
                    self?.markPendingCommandOutcomeUnknown()
                    self?.state.connection = .offline
                }
            } catch {
                if self?.state.connection != .incompatibleProtocol {
                    self?.markPendingCommandOutcomeUnknown()
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
                markPendingCommandOutcomeUnknown()
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
        case let .commandAck(messageEpoch, commandID):
            guard messageEpoch == serverEpoch,
                  state.command?.commandID == commandID,
                  state.command?.status == .pending
            else { return }
            commandTimeoutTask?.cancel()
            commandTimeoutTask = nil
            state.command = CommandViewState(
                commandID: commandID,
                status: .acknowledged,
                message: "已确认"
            )
            state.successFeedbackCount += 1
            if case .reply = pendingCommandIntent {
                state.replyDraft = ""
                state.replyError = nil
                state.isReplyEditorPresented = false
            }
            pendingCommandIntent = nil
            scheduleAcknowledgementClear(commandID: commandID)
        case let .commandError(messageEpoch, commandID, error):
            guard messageEpoch == serverEpoch,
                  state.command?.commandID == commandID,
                  state.command?.status == .pending
            else { return }
            commandTimeoutTask?.cancel()
            commandTimeoutTask = nil
            state.command = CommandViewState(
                commandID: commandID,
                status: .failed,
                message: error
            )
            state.warningFeedbackCount += 1
            pendingCommandIntent = nil
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
        state.replyError = nil
        state.command = nil
        pendingOutputText = nil
        pendingCommandIntent = nil
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        commandNoticeTask?.cancel()
        commandNoticeTask = nil
    }

    private func beginCommand(_ intent: CommandIntent, isRetry: Bool) async {
        guard let pane = state.selectedPane,
              let liveConnection,
              state.connection == .online,
              isRetry ? state.command?.status == .outcomeUnknown : canStartNewCommand
        else { return }
        commandNoticeTask?.cancel()
        commandNoticeTask = nil
        let commandID = identifier()
        let message = clientMessage(for: intent, commandID: commandID, pane: pane)
        state.command = CommandViewState(
            commandID: commandID,
            status: .pending,
            message: isRetry ? "正在重试；上一命令可能已经执行。" : nil
        )
        pendingCommandIntent = intent
        do {
            try await liveConnection.send(message)
            if state.command?.commandID == commandID,
               state.command?.status == .pending {
                scheduleCommandTimeout(commandID: commandID)
            }
        } catch {
            markCommandOutcomeUnknown(commandID: commandID)
        }
    }

    private func clientMessage(
        for intent: CommandIntent,
        commandID: String,
        pane: AgentPane
    ) -> NativeClientMessage {
        switch intent {
        case let .reply(text):
            return .sendText(
                commandID: commandID, paneID: pane.paneID,
                paneRef: pane.paneRef, text: text
            )
        case let .quick(command):
            switch command {
            case .yes:
                return .sendText(
                    commandID: commandID, paneID: pane.paneID,
                    paneRef: pane.paneRef, text: "y"
                )
            case .no:
                return .sendText(
                    commandID: commandID, paneID: pane.paneID,
                    paneRef: pane.paneRef, text: "n"
                )
            case .allowOnce:
                return .action(
                    commandID: commandID, paneID: pane.paneID,
                    paneRef: pane.paneRef, action: "approve_once"
                )
            case .deny:
                return .action(
                    commandID: commandID, paneID: pane.paneID,
                    paneRef: pane.paneRef, action: "deny"
                )
            default:
                return .sendKeys(
                    commandID: commandID, paneID: pane.paneID,
                    paneRef: pane.paneRef, keys: [key(for: command)]
                )
            }
        }
    }

    private var canStartNewCommand: Bool {
        state.command?.status != .pending && state.command?.status != .outcomeUnknown
    }

    private func key(for command: QuickCommand) -> String {
        switch command {
        case .enter: "Enter"
        case .escape: "Escape"
        case .tab: "Tab"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .controlC: "Ctrl+c"
        case .controlL: "Ctrl+l"
        case .controlP: "Ctrl+p"
        case .controlO: "Ctrl+o"
        case .yes, .no, .allowOnce, .deny:
            preconditionFailure("text and fixed actions do not map to keys")
        }
    }

    private func validateReply(_ text: String) -> Bool {
        guard !text.isEmpty,
              text.utf8.count <= 4096,
              text.split(separator: "\n", omittingEmptySubsequences: false).count <= 20
        else { return false }
        return !text.unicodeScalars.contains { scalar in
            (scalar.value < 32 && scalar != "\n") || scalar.value == 127
        }
    }

    private func scheduleAcknowledgementClear(commandID: String) {
        commandNoticeTask?.cancel()
        commandNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled,
                  self?.state.command?.commandID == commandID,
                  self?.state.command?.status == .acknowledged
            else { return }
            self?.state.command = nil
        }
    }

    private func scheduleCommandTimeout(commandID: String) {
        commandTimeoutTask?.cancel()
        let timeout = commandTimeout
        commandTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.markCommandOutcomeUnknown(commandID: commandID)
        }
    }

    private func markCommandOutcomeUnknown(commandID: String) {
        guard state.command?.commandID == commandID,
              state.command?.status == .pending
        else { return }
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
        state.command = CommandViewState(
            commandID: commandID,
            status: .outcomeUnknown,
            message: "结果未知：命令可能已经执行。",
            canRetry: true
        )
        state.warningFeedbackCount += 1
    }

    private func markPendingCommandOutcomeUnknown() {
        guard let command = state.command, command.status == .pending else { return }
        markCommandOutcomeUnknown(commandID: command.commandID)
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
