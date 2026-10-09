import Foundation
import Security

nonisolated final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()
    private let defaultService: String
    private let lock = NSLock()

    enum ReadResult {
        case success(Data)
        case notFound
        case failure(OSStatus)
    }

    init(service: String = "com.macrofy.sdk.session") {
        self.defaultService = service
    }

    /// Atomically updates an existing Keychain item in-place, or inserts it
    /// if it does not exist yet.
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

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }

        return false
    }

    /// Reads an item from Keychain, distinguishing a genuinely missing item (`.notFound`)
    /// from a transient error (`.failure`, e.g. device locked before first unlock).
    func readResult(key: String, service: String? = nil) -> ReadResult {
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
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            if let data = item as? Data {
                return .success(data)
            }
            return .notFound
        case errSecItemNotFound:
            return .notFound
        default:
            return .failure(status)
        }
    }

    func read(key: String, service: String? = nil) -> Data? {
        if case .success(let data) = readResult(key: key, service: service) {
            return data
        }
        return nil
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
