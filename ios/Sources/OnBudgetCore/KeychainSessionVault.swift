#if canImport(Security)
import Foundation
import Security

/// Device-only session storage, excluded from iCloud and widgets. Never stores password.
public final class KeychainSessionVault: NativeSessionVault, @unchecked Sendable {
    private let service: String
    private let account = "native-read-session"
    private let lock = NSLock()
    public init(service: String) { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    public func load() throws -> Data? {
        try lock.withLock {
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else { throw ConnectionError.invalidResponse }
            return data
        }
    }
    public func save(_ data: Data) throws {
        try lock.withLock {
            let attributes: [String: Any] = [kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var insert = query
                attributes.forEach { insert[$0.key] = $0.value }
                guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw ConnectionError.invalidResponse }
            } else if status != errSecSuccess { throw ConnectionError.invalidResponse }
        }
    }
    public func clear() throws {
        try lock.withLock {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ConnectionError.invalidResponse }
        }
    }
}
#endif
