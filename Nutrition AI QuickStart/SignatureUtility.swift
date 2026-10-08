import Foundation
import CryptoKit

nonisolated enum SignatureUtility: Sendable {
    /// Computes the 64-character lowercase hexadecimal HMAC-SHA256 signature.
    /// - Parameters:
    ///   - appSecret: The shared application secret hex key.
    ///   - userId: The external developer user ID (1-255 characters).
    /// - Returns: Hex-encoded HMAC-SHA256 string.
    static func generateHMAC(appSecret: String, userId: String) -> String {
        let key = SymmetricKey(data: Data(appSecret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(userId.utf8), using: key)
        return signature.map { String(format: "%02hhx", $0) }.joined()
    }
}
