import Foundation

public nonisolated struct APIErrorResponse: Codable, Sendable {
    public let error: String?
    public let message: String?
}

public nonisolated enum MacrofyError: LocalizedError, Sendable {
    case invalidURL
    case networkError(Error)
    case badRequest(message: String)
    case unauthorized(message: String)
    case forbidden(message: String)
    case notFound(message: String)
    case rateLimited(retryAfter: Int?)
    case serverError(statusCode: Int, message: String)
    case decodingError(Error, String)
    case uploadFailed(statusCode: Int)
    case sseTimeout
    case scanFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The request URL was invalid."
        case .networkError(let error):
            return "Network connection error: \(error.localizedDescription)"
        case .badRequest(let message):
            return "Bad request (400): \(message)"
        case .unauthorized(let message):
            return "Authentication failed (401): \(message)"
        case .forbidden(let message):
            return "Access denied (403): \(message)"
        case .notFound(let message):
            return "Resource not found (404): \(message)"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limit exceeded (429). Retry after \(seconds) seconds."
            }
            return "Rate limit exceeded (429). Please wait before trying again."
        case .serverError(let statusCode, let message):
            return "Server error (\(statusCode)): \(message)"
        case .decodingError(let error, let context):
            return "JSON decoding failure in \(context): \(error.localizedDescription)"
        case .uploadFailed(let statusCode):
            return "Direct binary image upload failed with HTTP \(statusCode)."
        case .sseTimeout:
            return "AI Image scan timed out waiting for server completion."
        case .scanFailed(let message):
            return "Image analysis failed: \(message)"
        }
    }
}
