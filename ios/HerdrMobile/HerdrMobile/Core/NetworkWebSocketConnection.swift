import Foundation
import Network

@available(iOS 26.0, macOS 26.0, *)
@MainActor
public final class NetworkWebSocketConnection: NativeConnectionServing {
    private static let maximumMessageSize = 8 * 1024

    private var connection: NetworkConnection<WebSocket>?
    private var receiveTask: Task<Void, Never>?

    public init() {}

    public func open(
        origin: String,
        sessionToken: String
    ) -> AsyncThrowingStream<NativeServerMessage, Error> {
        cancel()
        guard var components = URLComponents(string: origin) else {
            return failedStream(NativeConnectionError.invalidEndpoint)
        }
        components.scheme = "wss"
        components.path = "/ws"
        guard let url = components.url else {
            return failedStream(NativeConnectionError.invalidEndpoint)
        }

        let connection: NetworkConnection<WebSocket> = NetworkConnection(
            to: NWEndpoint.url(url)
        ) {
            WebSocket {
                TLS()
            }
            .additionalHeaders([("Authorization", "Bearer \(sessionToken)")])
            .autoReplyPing(true)
            .maximumMessageSize(Self.maximumMessageSize)
        }
        self.connection = connection

        return AsyncThrowingStream { continuation in
            receiveTask = Task {
                do {
                    for try await message in connection.messages {
                        let data = message.content
                        guard data.count <= Self.maximumMessageSize else {
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
                Task { @MainActor in self?.cancel() }
            }
        }
    }

    public func send(_ message: NativeClientMessage) async throws {
        guard let connection else { throw NativeConnectionError.transport }
        let data = try JSONEncoder().encode(message)
        guard data.count <= Self.maximumMessageSize,
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
        receiveTask?.cancel()
        receiveTask = nil
        connection = nil
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
