import Foundation

let nativeProtocolVersion = 1

@_spi(Testing) public enum NativeConnectionError: Error, Equatable, Sendable {
    case invalidEndpoint
    case authentication
    case tls
    case transport
    case backendUnavailable
    case messageTooLarge
    case invalidMessage
}

public struct AgentPane: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let paneID: String
    public let paneRef: String
    public let title: String
    public let status: String
    public let cwd: String
    public let workspaceID: String

    public var id: String { "\(paneID)\u{1f}\(paneRef)" }

    public init(
        paneID: String,
        paneRef: String,
        title: String,
        status: String,
        cwd: String,
        workspaceID: String
    ) {
        self.paneID = paneID
        self.paneRef = paneRef
        self.title = title
        self.status = status
        self.cwd = cwd
        self.workspaceID = workspaceID
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case paneRef = "pane_ref"
        case title
        case status = "agent_status"
        case cwd
        case workspaceID = "workspace_id"
    }
}

@_spi(Testing) public enum NativeServerMessage: Equatable, Sendable, Decodable {
    case hello(protocolVersion: Int, serverEpoch: String)
    case paneSnapshot(serverEpoch: String, revision: Int, panes: [AgentPane])
    case outputSnapshot(
        serverEpoch: String,
        subscriptionID: String,
        paneID: String,
        paneRef: String,
        revision: Int,
        text: String
    )
    case commandAck(serverEpoch: String, commandID: String)
    case commandError(serverEpoch: String, commandID: String, error: String)
    case error(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol_version"
        case serverEpoch = "server_epoch"
        case revision
        case panes
        case subscriptionID = "subscription_id"
        case paneID = "pane_id"
        case paneRef = "pane_ref"
        case commandID = "command_id"
        case text
        case error
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case "hello":
            self = .hello(
                protocolVersion: try values.decode(Int.self, forKey: .protocolVersion),
                serverEpoch: try values.decode(String.self, forKey: .serverEpoch)
            )
        case "pane_snapshot":
            self = .paneSnapshot(
                serverEpoch: try values.decode(String.self, forKey: .serverEpoch),
                revision: try values.decode(Int.self, forKey: .revision),
                panes: try values.decode([AgentPane].self, forKey: .panes)
            )
        case "output_snapshot":
            self = .outputSnapshot(
                serverEpoch: try values.decode(String.self, forKey: .serverEpoch),
                subscriptionID: try values.decode(String.self, forKey: .subscriptionID),
                paneID: try values.decode(String.self, forKey: .paneID),
                paneRef: try values.decode(String.self, forKey: .paneRef),
                revision: try values.decode(Int.self, forKey: .revision),
                text: try values.decode(String.self, forKey: .text)
            )
        case "command_ack":
            self = .commandAck(
                serverEpoch: try values.decode(String.self, forKey: .serverEpoch),
                commandID: try values.decode(String.self, forKey: .commandID)
            )
        case "command_error":
            self = .commandError(
                serverEpoch: try values.decode(String.self, forKey: .serverEpoch),
                commandID: try values.decode(String.self, forKey: .commandID),
                error: try values.decode(String.self, forKey: .error)
            )
        case "error":
            self = .error(try values.decode(String.self, forKey: .error))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: values,
                debugDescription: "Unsupported native server message"
            )
        }
    }
}

@_spi(Testing) public enum NativeClientMessage: Equatable, Sendable, Encodable {
    case subscribe(
        subscriptionID: String,
        paneID: String,
        paneRef: String,
        lines: Int
    )
    case sendText(commandID: String, paneID: String, paneRef: String, text: String)
    case sendKeys(commandID: String, paneID: String, paneRef: String, keys: [String])
    case action(commandID: String, paneID: String, paneRef: String, action: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case subscriptionID = "subscription_id"
        case paneID = "pane_id"
        case paneRef = "pane_ref"
        case commandID = "command_id"
        case lines
        case text
        case keys
        case action
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .subscribe(subscriptionID, paneID, paneRef, lines):
            try values.encode("subscribe", forKey: .type)
            try values.encode(subscriptionID, forKey: .subscriptionID)
            try values.encode(paneID, forKey: .paneID)
            try values.encode(paneRef, forKey: .paneRef)
            try values.encode(lines, forKey: .lines)
        case let .sendText(commandID, paneID, paneRef, text):
            try values.encode("send_text", forKey: .type)
            try values.encode(commandID, forKey: .commandID)
            try values.encode(paneID, forKey: .paneID)
            try values.encode(paneRef, forKey: .paneRef)
            try values.encode(text, forKey: .text)
        case let .sendKeys(commandID, paneID, paneRef, keys):
            try values.encode("send_keys", forKey: .type)
            try values.encode(commandID, forKey: .commandID)
            try values.encode(paneID, forKey: .paneID)
            try values.encode(paneRef, forKey: .paneRef)
            try values.encode(keys, forKey: .keys)
        case let .action(commandID, paneID, paneRef, action):
            try values.encode("action", forKey: .type)
            try values.encode(commandID, forKey: .commandID)
            try values.encode(paneID, forKey: .paneID)
            try values.encode(paneRef, forKey: .paneRef)
            try values.encode(action, forKey: .action)
        }
    }
}

@_spi(Testing) public enum NativePathEvent: Equatable, Sendable {
    case viabilityChanged(Bool)
    case betterPathAvailable
}

@_spi(Testing) @MainActor
public protocol NativeConnectionServing: AnyObject {
    var pathEventHandler: (@MainActor (NativePathEvent) -> Void)? { get set }

    func open(
        origin: String,
        sessionToken: String
    ) -> AsyncThrowingStream<NativeServerMessage, Error>
    func send(_ message: NativeClientMessage) async throws
    func cancel()
}
