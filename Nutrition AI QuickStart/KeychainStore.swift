import Foundation
import Security

nonisolated final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()
    private let defaultService: String

    init(service: String = "com.macrofy.sdk.session") {
        self.defaultService = service
    }

    func save(key: String, data: Data, service: String? = nil) -> Bool {
        let activeService = service ?? defaultService
        // Identity-only query: used to find and remove any existing item for
        // this account. Including kSecValueData here would make the delete's
        // search require an exact match on the *old* value, so an update
        // (e.g. a refreshed token) would silently fail to delete the stale
        // item and the following add would then fail as a duplicate.
        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: activeService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(searchQuery as CFDictionary)

        var addQuery = searchQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    func read(key: String, service: String? = nil) -> Data? {
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

    func delete(key: String, service: String? = nil) {
        let activeService = service ?? defaultService
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: activeService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    func clear(service: String? = nil) {
        let activeService = service ?? defaultService
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: activeService
        ]
        SecItemDelete(query as CFDictionary)
    }
}
