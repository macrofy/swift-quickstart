import Foundation
import Security

nonisolated final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()
    private let defaultService: String
    private let lock = NSLock()

    init(service: String = "com.macrofy.sdk.session") {
        self.defaultService = service
    }

    /// Atomically updates an existing Keychain item in-place, or inserts it
    /// if it does not exist yet.
    ///
    /// Rather than deleting the existing item first (which leaves a window where
    /// a failed insert loses the existing credentials, or concurrent saves can
    /// clobber each other), this uses `SecItemUpdate` first. If the item does not
    /// exist (`errSecItemNotFound`), it falls back to `SecItemAdd`.
    func save(key: String, data: Data, service: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let activeService = service ?? defaultService
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: activeService,
            kSecAttrAccount as String: key
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        // 1. Attempt in-place atomic update
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        // 2. If item does not exist yet, add it
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }

        return false
    }

    func read(key: String, service: String? = nil) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        let activeService = service ?? defaultService
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: activeService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return data
    }

    @discardableResult
    func delete(key: String, service: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let activeService = service ?? defaultService
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: activeService,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    @discardableResult
    func clear(service: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let activeService = service ?? defaultService
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: activeService
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
