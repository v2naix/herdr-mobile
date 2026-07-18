import Foundation

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
public final class NativeSessionHTTPClient: NativeSessionServing {
    private struct ExchangeResponse: Decodable {
        let token: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case token
            case expiresIn = "expires_in"
        }
    }

    private let session: URLSession
    private let redirectDelegate: NoRedirectDelegate?
    private let now: () -> Date

    public init(session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        if let session {
            self.session = session
            self.redirectDelegate = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let redirectDelegate = NoRedirectDelegate()
            self.redirectDelegate = redirectDelegate
            self.session = URLSession(
                configuration: configuration,
                delegate: redirectDelegate,
                delegateQueue: nil
            )
        }
        self.now = now
    }

    public func exchange(origin: String, bootstrapToken: String) async throws -> NativeSession {
        var request = URLRequest(url: try endpoint(origin: origin))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(bootstrapToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw NativeSessionError.invalidResponse
            }
            if response.statusCode == 401 {
                throw NativeSessionError.invalidCredentials
            }
            guard response.statusCode == 200,
                  let value = try? JSONDecoder().decode(ExchangeResponse.self, from: data),
                  !value.token.isEmpty,
                  value.expiresIn > 0
            else {
                throw NativeSessionError.invalidResponse
            }
            return NativeSession(
                token: value.token,
                expiresAt: now().addingTimeInterval(TimeInterval(value.expiresIn))
            )
        } catch let error as NativeSessionError {
            throw error
        } catch let error as URLError where Self.isTLSError(error.code) {
            throw NativeSessionError.tls
        } catch {
            throw NativeSessionError.transport
        }
    }

    public func revoke(origin: String, sessionToken: String) async throws {
        var request = URLRequest(url: try endpoint(origin: origin))
        request.httpMethod = "DELETE"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 204 || response.statusCode == 401
            else {
                throw NativeSessionError.invalidResponse
            }
        } catch let error as NativeSessionError {
            throw error
        } catch let error as URLError where Self.isTLSError(error.code) {
            throw NativeSessionError.tls
        } catch {
            throw NativeSessionError.transport
        }
    }

    private func endpoint(origin: String) throws -> URL {
        guard let base = URL(string: origin),
              let url = URL(string: "/api/native/session", relativeTo: base)?.absoluteURL
        else {
            throw NativeSessionError.invalidResponse
        }
        return url
    }

    private static func isTLSError(_ code: URLError.Code) -> Bool {
        switch code {
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return false
        }
    }
}
