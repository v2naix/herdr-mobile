import Foundation

let nativeProtocolVersion = 1

enum NativeConnectionError: Error, Equatable, Sendable {
    case invalidEndpoint
    case tls
    case transport
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

    private enum CodingKeys: String, CodingKey {
        case type
        case subscriptionID = "subscription_id"
        case paneID = "pane_id"
        case paneRef = "pane_ref"
        case lines
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
        }
    }
}

@_spi(Testing) @MainActor
public protocol NativeConnectionServing: AnyObject {
    func open(
        origin: String,
        sessionToken: String
    ) -> AsyncThrowingStream<NativeServerMessage, Error>
    func send(_ message: NativeClientMessage) async throws
    func cancel()
}
