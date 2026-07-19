import Foundation
import Network

@available(iOS 26.0, macOS 26.0, *)
@_spi(Testing) public struct NativeWebSocketHandshake: Equatable, Sendable {
    public let url: URL
    public let authorizationHeader: String
    public let autoReplyPing: Bool
    public let maximumMessageSize: Int
}

@available(iOS 26.0, macOS 26.0, *)
@_spi(Testing) @MainActor
public final class NetworkWebSocketConnection: NativeConnectionServing {
    @_spi(Testing) public static let maximumOutgoingMessageSize = 8 * 1024
    @_spi(Testing) public static let maximumIncomingMessageSize = 1024 * 1024

    private var connection: NetworkConnection<WebSocket>?
    private var receiveTask: Task<Void, Never>?
    private var streamContinuation: AsyncThrowingStream<NativeServerMessage, Error>.Continuation?
    private var streamGeneration = 0
    public var pathEventHandler: (@MainActor (NativePathEvent) -> Void)?

    public init() {}

    @_spi(Testing) public static func handshake(
        origin: String,
        sessionToken: String
    ) throws -> NativeWebSocketHandshake {
        guard var components = URLComponents(string: origin) else {
            throw NativeConnectionError.invalidEndpoint
        }
        components.scheme = "wss"
        components.path = "/ws"
        guard let url = components.url else {
            throw NativeConnectionError.invalidEndpoint
        }
        return NativeWebSocketHandshake(
            url: url,
            authorizationHeader: "Bearer \(sessionToken)",
            autoReplyPing: true,
            maximumMessageSize: maximumIncomingMessageSize
        )
    }

    public func open(
        origin: String,
        sessionToken: String
    ) -> AsyncThrowingStream<NativeServerMessage, Error> {
        cancel()
        let handshake: NativeWebSocketHandshake
        do {
            handshake = try Self.handshake(origin: origin, sessionToken: sessionToken)
        } catch {
            return failedStream(error)
        }

        let connection: NetworkConnection<WebSocket> = NetworkConnection(
            to: NWEndpoint.url(handshake.url)
        ) {
            WebSocket {
                TLS()
            }
            .additionalHeaders([("Authorization", handshake.authorizationHeader)])
            .autoReplyPing(handshake.autoReplyPing)
            .maximumMessageSize(handshake.maximumMessageSize)
        }
        let generation = streamGeneration
        connection.onViabilityUpdate { [weak self] _, isViable in
            guard self?.streamGeneration == generation else { return }
            self?.pathEventHandler?(.viabilityChanged(isViable))
        }
        connection.onBetterPathUpdate { [weak self] _, hasBetterPath in
            guard hasBetterPath,
                  self?.streamGeneration == generation
            else { return }
            self?.pathEventHandler?(.betterPathAvailable)
        }
        self.connection = connection

        return AsyncThrowingStream { continuation in
            streamContinuation = continuation
            receiveTask = Task {
                do {
                    for try await message in connection.messages {
                        switch message.metadata.opcode {
                        case .close:
                            if let error = Self.normalized(message.metadata.closeCode) {
                                continuation.finish(throwing: error)
                            } else {
                                continuation.finish()
                            }
                            return
                        case .ping, .pong:
                            continue
                        case .text:
                            break
                        case .binary, .cont:
                            throw NativeConnectionError.invalidMessage
                        @unknown default:
                            throw NativeConnectionError.invalidMessage
                        }
                        let data = message.content
                        guard data.count <= Self.maximumIncomingMessageSize else {
                            throw NativeConnectionError.messageTooLarge
                        }
                        guard let decoded = try? JSONDecoder().decode(
                            NativeServerMessage.self,
                            from: data
                        ) else {
                            throw NativeConnectionError.invalidMessage
                        }
                        continuation.yield(decoded)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalized(error))
                }
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard self?.streamGeneration == generation else { return }
                    self?.cancel()
                }
            }
        }
    }

    public func send(_ message: NativeClientMessage) async throws {
        guard let connection else { throw NativeConnectionError.transport }
        let data = try JSONEncoder().encode(message)
        guard data.count <= Self.maximumOutgoingMessageSize,
              let text = String(data: data, encoding: .utf8)
        else {
            throw NativeConnectionError.messageTooLarge
        }
        do {
            try await connection.send(text)
        } catch {
            throw Self.normalized(error)
        }
    }

    public func cancel() {
        streamGeneration += 1
        receiveTask?.cancel()
        receiveTask = nil
        streamContinuation?.finish()
        streamContinuation = nil
        connection = nil
    }

    @_spi(Testing) public static func normalized(
        _ closeCode: NWProtocolWebSocket.CloseCode?
    ) -> NativeConnectionError? {
        switch closeCode {
        case .protocolCode(.policyViolation): .authentication
        case .applicationCode(1013), .privateCode(1013),
             .protocolCode(.internalServerError): .backendUnavailable
        case .protocolCode(.tlsHandshake): .tls
        case .protocolCode(.protocolError), .protocolCode(.unsupportedData): .invalidMessage
        case .protocolCode(.messageTooBig): .messageTooLarge
        default: nil
        }
    }

    private static func normalized(_ error: Error) -> NativeConnectionError {
        if let error = error as? NativeConnectionError { return error }
        if case .tls = error as? NWError { return .tls }
        return .transport
    }

    private func failedStream(
        _ error: Error
    ) -> AsyncThrowingStream<NativeServerMessage, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }
}
