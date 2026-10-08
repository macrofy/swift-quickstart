import Foundation
import CryptoKit

nonisolated enum SignatureUtility: Sendable {
    /// Computes the 64-character lowercase hexadecimal HMAC-SHA256 signature.
    ///
    /// The Macrofy portal issues `appSecret` as a 64-character hex string
    /// representing 32 raw key bytes, and the API computes the signature
    /// using those decoded bytes. This function decodes the hex string into
    /// `Data` before signing so the client and server derive the same key.
    /// If `appSecret` is not valid hex (for example a non-hex placeholder
    /// value), it falls back to signing the raw UTF-8 bytes of the string.
    /// - Parameters:
    ///   - appSecret: The shared application secret, typically a 64-character hex key.
    ///   - userId: The external developer user ID (1-255 characters).
    /// - Returns: Hex-encoded HMAC-SHA256 string.
    static func generateHMAC(appSecret: String, userId: String) -> String {
        let keyData = dataFromHexString(appSecret) ?? Data(appSecret.utf8)
        let key = SymmetricKey(data: keyData)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(userId.utf8), using: key)
        return signature.map { String(format: "%02hhx", $0) }.joined()
    }

    /// Decodes a hexadecimal string into raw bytes. Returns `nil` if the
    /// string is empty, has an odd length, or contains non-hexadecimal
    /// characters.
    private static func dataFromHexString(_ hex: String) -> Data? {
        let cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHex.isEmpty, cleanHex.count % 2 == 0 else { return nil }

        var data = Data(capacity: cleanHex.count / 2)
        var index = cleanHex.startIndex
        while index < cleanHex.endIndex {
            let nextIndex = cleanHex.index(index, offsetBy: 2)
            guard let byte = UInt8(cleanHex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}
