import Foundation
import Security

@_spi(Testing) @MainActor
public protocol KeychainItemAccessing: AnyObject {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ item: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

@MainActor
private final class SecurityKeychainItems: KeychainItemAccessing {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ item: [String: Any]) -> OSStatus {
        SecItemAdd(item as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
public final class KeychainCredentialStore: CredentialStoring {
    private let account = "herdr-mobile-bootstrap"
    private let items: KeychainItemAccessing

    public convenience init() {
        self.init(items: SecurityKeychainItems())
    }

    @_spi(Testing) public init(items: KeychainItemAccessing) {
        self.items = items
    }

    public func loadToken(for origin: String) throws -> String? {
        var query = try baseQuery(for: origin)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = items.copyMatching(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data,
              let token = String(data: data, encoding: .utf8)
        else {
            throw mappedError(status)
        }
        return token
    }

    public func saveToken(_ token: String, for origin: String) throws {
        let query = try baseQuery(for: origin)
        let data = Data(token.utf8)
        let updateStatus = items.update(
            query,
            attributes: [kSecValueData as String: data]
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw mappedError(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        let addStatus = items.add(item)
        guard addStatus == errSecSuccess else {
            throw mappedError(addStatus)
        }
    }

    public func deleteToken(for origin: String) throws {
        let status = items.delete(try baseQuery(for: origin))
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
