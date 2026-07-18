import Foundation
import Security

@MainActor
public final class KeychainCredentialStore: CredentialStoring {
    private let account = "herdr-mobile-bootstrap"

    public init() {}

    public func loadToken(for origin: String) throws -> String? {
        var query = try baseQuery(for: origin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else {
            throw mappedError(status)
        }
        return token
    }

    public func saveToken(_ token: String, for origin: String) throws {
        let query = try baseQuery(for: origin)
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw mappedError(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw mappedError(addStatus)
        }
    }

    public func deleteToken(for origin: String) throws {
        let status = SecItemDelete(try baseQuery(for: origin) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mappedError(status)
        }
    }

    private func baseQuery(for origin: String) throws -> [String: Any] {
        guard let components = URLComponents(string: origin),
              let host = components.host
        else {
            throw CredentialStoreError.unavailable
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrAccount as String: account,
            kSecAttrServer as String: host,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrLabel as String: origin,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let port = components.port {
            query[kSecAttrPort as String] = port
        }
        return query
    }

    private func mappedError(_ status: OSStatus) -> CredentialStoreError {
        switch status {
        case errSecAuthFailed, errSecInteractionNotAllowed:
            return .passcodeRequired
        default:
            return .unavailable
        }
    }
}
