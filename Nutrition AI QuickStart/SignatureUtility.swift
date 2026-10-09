import Foundation
import CryptoKit

nonisolated enum SignatureUtility: Sendable {
    /// Computes the 64-character lowercase hexadecimal HMAC-SHA256 signature.
    ///
    /// `appSecret` is used as-is: its literal UTF-8 bytes are the HMAC key,
    /// even though the secret itself is formatted as a hex-looking string.
    /// (An earlier revision of this function decoded `appSecret` as hex into
    /// raw key bytes first, based on an unverified assumption about the API's
    /// key material; live testing against the production API confirmed that
    /// produces an invalid signature. Do not reintroduce hex-decoding here
    /// without confirming it against the real `/api/auth/connect` endpoint.)
    /// - Parameters:
    ///   - appSecret: The shared application secret, exactly as issued by the
    ///     Macrofy Developer Portal.
    ///   - userId: The external developer user ID (1-255 characters).
    /// - Returns: Hex-encoded HMAC-SHA256 string.
    static func generateHMAC(appSecret: String, userId: String) -> String {
        let key = SymmetricKey(data: Data(appSecret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(userId.utf8), using: key)
        return signature.map { String(format: "%02hhx", $0) }.joined()
    }
}
