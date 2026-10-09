import Foundation
import CryptoKit

/// An in-process, thread-safe session registry that coordinates Keychain storage,
/// in-memory caching, authentication generation counters, and in-flight refresh
/// tracking across all `MacrofyClient` instances sharing the same tenant/host scope.
private nonisolated final class SessionRegistry: @unchecked Sendable {
    static let shared = SessionRegistry()
    private let lock = NSLock()

    private var sessions: [String: (token: String?, user: SessionUser?)] = [:]
    private var authGenerations: [String: UInt64] = [:]
    private var installedAuthGenerations: [String: UInt64] = [:]
    private var inFlightRefreshCounts: [String: Int] = [:]

    struct PersistedSession: Codable {
        let token: String
        let user: SessionUser
    }

    enum SaveSessionResult {
        case success
        case superseded
        case persistenceFailed
    }

    enum ClearSessionResult {
        case cleared
        case tokenMismatch
        case refreshInFlight
        case persistenceFailed
    }

    /// Ensures the session for `key` is loaded from Keychain and validated against `expectedAppId`.
    /// Distinguishes a genuinely missing item (`.notFound`) from a transient access error (`.failure`,
    /// e.g. device locked before first unlock) so temporary read failures do not cache an empty session.
    func restoreIfNeeded(for key: String, expectedAppId: String, using keychain: KeychainStore) {
        lock.lock()
        defer { lock.unlock() }

        guard sessions[key] == nil else { return }

        switch keychain.readResult(key: key) {
        case .success(let data):
            if let record = try? JSONDecoder().decode(PersistedSession.self, from: data),
               record.user.appId == expectedAppId {
                sessions[key] = (record.token, record.user)
            } else {
                keychain.delete(key: key)
                sessions[key] = (nil, nil)
            }
        case .notFound:
            sessions[key] = (nil, nil)
        case .failure:
            // Do not delete and do not cache (nil, nil) on transient access errors
            break
        }
    }

    /// Atomically reads the current (token, user) snapshot for `key`.
    func getSessionSnapshot(for key: String) -> (token: String?, user: SessionUser?) {
        lock.lock()
        defer { lock.unlock() }
        let session = sessions[key]
        return (session?.token, session?.user)
    }

    /// Allocates the next authentication generation counter for `key`.
    func nextAuthGeneration(for key: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let next = (authGenerations[key] ?? 0) &+ 1
        authGenerations[key] = next
        return next
    }

    /// Atomically checks generation and saves the session to Keychain + registry.
    /// If generation < installedAuthGeneration, rejects with `.superseded` without modifying storage.
    /// Advances `authGenerations` and `installedAuthGenerations` ONLY after Keychain persistence succeeds.
    func saveSessionIfCurrent(
        token: String,
        user: SessionUser,
        generation: UInt64?,
        for key: String,
        using keychain: KeychainStore
    ) -> SaveSessionResult {
        lock.lock()
        defer { lock.unlock() }

        let currentInstalled = installedAuthGenerations[key] ?? 0
        if let generation, generation < currentInstalled {
            return .superseded
        }

        let record = PersistedSession(token: token, user: user)
        guard let data = try? JSONEncoder().encode(record),
              keychain.save(key: key, data: data) else {
            return .persistenceFailed
        }

        sessions[key] = (token, user)

        // Advance auth generations so any earlier in-flight request is rejected
        let nextGen = max(authGenerations[key] ?? 0, generation ?? ((authGenerations[key] ?? 0) &+ 1))
        authGenerations[key] = nextGen
        installedAuthGenerations[key] = nextGen
        return .success
    }

    /// Atomically clears the session ONLY IF `matchingToken` matches the currently installed token
    /// (or if `matchingToken == nil`). In-memory credentials are always invalidated so rejected
    /// tokens cannot remain active even if Keychain deletion encounters an error.
    func clearSessionIfMatching(
        token matchingToken: String?,
        ignoreIfRefreshing: Bool = true,
        for key: String,
        using keychain: KeychainStore
    ) -> ClearSessionResult {
        lock.lock()
        defer { lock.unlock() }

        let currentToken = sessions[key]?.token

        // If a specific token was rejected, it must still match the active session.
        // If another operation already installed a replacement session, do not clear!
        if let matchingToken, matchingToken != currentToken {
            return .tokenMismatch
        }

        // If a refresh is in flight for this scope and ignoreIfRefreshing is true, do not clear.
        if ignoreIfRefreshing && (inFlightRefreshCounts[key] ?? 0) > 0 {
            return .refreshInFlight
        }

        // Always invalidate in-memory credentials and advance generations so earlier
        // in-flight requests are rejected and rejected tokens can never remain active.
        sessions[key] = (nil, nil)
        let nextGen = (authGenerations[key] ?? 0) &+ 1
        authGenerations[key] = nextGen
        installedAuthGenerations[key] = nextGen

        let deleted = keychain.delete(key: key)
        let fallbackOverwritten = !deleted ? keychain.save(key: key, data: Data()) : false

        guard deleted || fallbackOverwritten else {
            return .persistenceFailed
        }
        return .cleared
    }

    /// Increments the in-flight refresh counter for `key`.
    func beginRefresh(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        inFlightRefreshCounts[key, default: 0] += 1
    }

    /// Decrements the in-flight refresh counter for `key`.
    func endRefresh(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        let current = inFlightRefreshCounts[key, default: 1]
        inFlightRefreshCounts[key] = max(0, current - 1)
    }

    /// Returns whether any refresh is currently in flight for `key`.
    func isRefreshing(for key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (inFlightRefreshCounts[key] ?? 0) > 0
    }
}

public actor MacrofyClient {
    private let baseURL: URL
    private let appId: String
    private let session: URLSession
    private let keychain = KeychainStore.shared

    /// Scoped Keychain key combining the app ID, host, and a hash of the full
    /// API origin and base path, preventing sessions from crossing different
    /// environments, schemes, ports, or base paths.
    private let sessionKey: String

    public var currentToken: String? {
        sessionSnapshot().token
    }

    public var currentUser: SessionUser? {
        sessionSnapshot().user
    }

    public init(
        appId: String = AppConfig.appId,
        baseURL: URL = AppConfig.baseURL,
        session: URLSession = .shared
    ) {
        self.appId = appId
        self.baseURL = baseURL
        self.session = session

        // Derive a unique session key including app ID, host, and full origin/base path hash
        let normalizedOrigin = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let originHash = SHA256.hash(data: Data(normalizedOrigin.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
        let sanitizedHost = (baseURL.host ?? "api").filter { $0.isLetter || $0.isNumber }
        self.sessionKey = "macrofy_session_\(appId)_\(sanitizedHost)_\(originHash)"

        SessionRegistry.shared.restoreIfNeeded(for: sessionKey, expectedAppId: appId, using: keychain)
    }

    // MARK: - Session Management

    /// Persists the session atomically in the Keychain and updates memory across
    /// all client instances sharing this tenant/host scope.
    @discardableResult
    public func setSession(token: String, user: SessionUser) -> Bool {
        guard user.appId == self.appId else {
            return false
        }
        let result = SessionRegistry.shared.saveSessionIfCurrent(
            token: token,
            user: user,
            generation: nil,
            for: sessionKey,
            using: keychain
        )
        return result == .success
    }

    /// Clears the session from memory and Keychain across all clients sharing this scope.
    /// Throws if Keychain deletion fails and cannot be invalidated.
    @discardableResult
    public func clearSession() throws -> Bool {
        let result = SessionRegistry.shared.clearSessionIfMatching(
            token: nil,
            ignoreIfRefreshing: false,
            for: sessionKey,
            using: keychain
        )
        if result == .persistenceFailed {
            throw MacrofyError.serverError(
                statusCode: 0,
                message: "Failed to remove stored session from Keychain."
            )
        }
        return result == .cleared
    }

    public var isAuthenticated: Bool {
        sessionSnapshot().isAuthenticated
    }

    /// Atomically reads whether the client is authenticated together with
    /// the current token and user, in a single synchronized registry lookup.
    public func sessionSnapshot() -> (isAuthenticated: Bool, token: String?, user: SessionUser?) {
        SessionRegistry.shared.restoreIfNeeded(for: sessionKey, expectedAppId: appId, using: keychain)
        let (token, user) = SessionRegistry.shared.getSessionSnapshot(for: sessionKey)
        let authed = (token != nil && user != nil)
        return (authed, authed ? token : nil, authed ? user : nil)
    }

    // MARK: - Generic Request Pipeline

    private func execute<T: Decodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil,
        requiresAuth: Bool = true
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)
        if let queryItems = queryItems, !queryItems.isEmpty {
            components?.queryItems = queryItems
        }

        guard let url = components?.url else {
            throw MacrofyError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30.0

        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var requestToken: String?
        if requiresAuth {
            guard let token = currentToken else {
                throw MacrofyError.unauthorized(message: "Missing session token. Call connect() first.")
            }
            requestToken = token
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MacrofyError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MacrofyError.serverError(statusCode: 0, message: "Invalid response from server")
        }

        switch httpResponse.statusCode {
        case 200...299:
            if T.self == EmptyResponse.self {
                return EmptyResponse() as! T
            }
            do {
                let decoder = JSONDecoder()
                return try decoder.decode(T.self, from: data)
            } catch {
                throw MacrofyError.decodingError(error, "Decoding \(T.self)")
            }

        case 400:
            let msg = parseErrorMessage(data: data) ?? "Validation failed"
            throw MacrofyError.badRequest(message: msg)

        case 401:
            // Atomically clear the session ONLY if the rejected token is still current,
            // and no token refresh is currently in flight.
            if let requestToken {
                _ = SessionRegistry.shared.clearSessionIfMatching(
                    token: requestToken,
                    ignoreIfRefreshing: true,
                    for: sessionKey,
                    using: keychain
                )
            }
            let msg = parseErrorMessage(data: data) ?? "Session expired or invalid"
            throw MacrofyError.unauthorized(message: msg)

        case 403:
            let msg = parseErrorMessage(data: data) ?? "Forbidden"
            throw MacrofyError.forbidden(message: msg)

        case 404:
            let msg = parseErrorMessage(data: data) ?? "Not Found"
            throw MacrofyError.notFound(message: msg)

        case 429:
            let retryHeader = httpResponse.value(forHTTPHeaderField: "Retry-After")
            let retrySecs = retryHeader.flatMap { Int($0) }
            throw MacrofyError.rateLimited(retryAfter: retrySecs)

        default:
            let msg = parseErrorMessage(data: data) ?? "Internal Server Error"
            throw MacrofyError.serverError(statusCode: httpResponse.statusCode, message: msg)
        }
    }

    private func parseErrorMessage(data: Data) -> String? {
        if let errObj = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
            return errObj.message ?? errObj.error
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 1. Auth Endpoints

    /// Exchanges HMAC-SHA256 signature for a Bearer JWT session token.
    public func connect(appId: String, userId: String, signature: String) async throws -> AuthResponse {
        guard appId == self.appId else {
            throw MacrofyError.badRequest(message: "App ID '\(appId)' does not match client's configured App ID '\(self.appId)'.")
        }

        let generation = SessionRegistry.shared.nextAuthGeneration(for: sessionKey)

        let req = ConnectRequest(appId: appId, userId: userId, signature: signature)
        let body = try JSONEncoder().encode(req)

        let response: AuthResponse = try await execute(
            path: "api/auth/connect",
            method: "POST",
            body: body,
            requiresAuth: false
        )

        return try applyAuthResponse(response, generation: generation)
    }

    /// Refreshes the active Bearer JWT token before expiration.
    public func refreshSession() async throws -> AuthResponse {
        let requestToken = currentToken
        let generation = SessionRegistry.shared.nextAuthGeneration(for: sessionKey)

        SessionRegistry.shared.beginRefresh(for: sessionKey)
        defer {
            SessionRegistry.shared.endRefresh(for: sessionKey)
        }

        do {
            let response: AuthResponse = try await execute(
                path: "api/auth/refresh",
                method: "POST",
                body: nil,
                requiresAuth: true
            )
            return try applyAuthResponse(response, generation: generation)
        } catch {
            if case MacrofyError.unauthorized = error {
                // If another refresh is still in flight for this scope, do not clear.
                if let requestToken, !SessionRegistry.shared.isRefreshing(for: sessionKey) {
                    _ = SessionRegistry.shared.clearSessionIfMatching(
                        token: requestToken,
                        ignoreIfRefreshing: true,
                        for: sessionKey,
                        using: keychain
                    )
                }
            }
            throw error
        }
    }

    /// Applies a `connect()`/`refreshSession()` response to the session,
    /// atomically verifying that the response has not been superseded.
    private func applyAuthResponse(_ response: AuthResponse, generation: UInt64) throws -> AuthResponse {
        let result = SessionRegistry.shared.saveSessionIfCurrent(
            token: response.token,
            user: response.user,
            generation: generation,
            for: sessionKey,
            using: keychain
        )
        switch result {
        case .success:
            return response
        case .superseded:
            throw MacrofyError.sessionSuperseded
        case .persistenceFailed:
            throw MacrofyError.serverError(
                statusCode: 0,
                message: "Authenticated successfully, but failed to persist the session securely. Please try again."
            )
        }
    }

    // MARK: - 2. Food Endpoints

    /// Full-text search across foods.
    public func searchFoods(query: String, limit: Int = 20) async throws -> [FoodItem] {
        let queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        return try await execute(
            path: "v1/foods/search",
            method: "GET",
            queryItems: queryItems,
            requiresAuth: false
        )
    }

    /// Resolves product nutrition by UPC/EAN/GTIN barcode (7-14 numeric digits).
    public func scanBarcode(barcode: String) async throws -> FoodItem {
        let cleanBarcode = barcode.filter { $0.isNumber }
        return try await execute(
            path: "v1/foods/barcode/\(cleanBarcode)",
            method: "GET",
            requiresAuth: false
        )
    }

    // MARK: - 3. AI Image Scanning Pipeline

    /// Creates an image scan job and returns the pre-signed PUT upload URL.
    public func createScanJob(contentType: String = "image/jpeg", imageType: String = "photo") async throws -> CreateScanJobResponse {
        let body = try JSONEncoder().encode(CreateScanJobRequest(contentType: contentType, imageType: imageType))
        return try await execute(
            path: "v1/scan/image",
            method: "POST",
            body: body,
            requiresAuth: true
        )
    }

    /// Uploads raw binary image data directly to cloud storage via pre-signed URL.
    public func uploadImageBinary(uploadUrl: String, imageData: Data, contentType: String = "image/jpeg") async throws {
        guard let url = URL(string: uploadUrl) else {
            throw MacrofyError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = imageData

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 500
            throw MacrofyError.uploadFailed(statusCode: code)
        }
    }

    /// Subscribes to real-time status updates via Server-Sent Events (SSE).
    public func streamScanJobUpdates(jobId: String, timeout: TimeInterval = 60) -> AsyncThrowingStream<ImageScanStatusUpdate, Error> {
        let streamURL = baseURL.appendingPathComponent("v1/scan/image/\(jobId)/stream")
        let token = self.currentToken
        let session = self.session
        let sessionKey = self.sessionKey

        return AsyncThrowingStream { continuation in
            let producerTask = Task {
                var request = URLRequest(url: streamURL)
                request.httpMethod = "GET"
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                if let token {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }

                do {
                    let (asyncBytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 500
                        if code == 401 {
                            if let token {
                                _ = SessionRegistry.shared.clearSessionIfMatching(
                                    token: token,
                                    ignoreIfRefreshing: true,
                                    for: sessionKey,
                                    using: keychain
                                )
                            }
                            continuation.finish(throwing: MacrofyError.unauthorized(message: "Session expired or invalid"))
                        } else {
                            continuation.finish(throwing: MacrofyError.serverError(statusCode: code, message: "SSE Connection failed"))
                        }
                        return
                    }

                    for try await line in asyncBytes.lines {
                        try Task.checkCancellation()

                        // Skip heartbeats and empty lines
                        if line.hasPrefix(":") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                            continue
                        }

                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))
                            if let data = jsonString.data(using: .utf8) {
                                let update = try JSONDecoder().decode(ImageScanStatusUpdate.self, from: data)
                                continuation.yield(update)

                                if update.status == "completed" || update.status == "failed" {
                                    continuation.finish()
                                    return
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: MacrofyError.sseTimeout)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            let watchdogTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                producerTask.cancel()
            }

            continuation.onTermination = { _ in
                producerTask.cancel()
                watchdogTask.cancel()
            }
        }
    }

    // MARK: - 4. User Profile & Goals

    public func getProfile(userId: String) async throws -> ProfileWithGoals {
        return try await execute(
            path: "v1/users/\(userId)/profile",
            method: "GET",
            requiresAuth: true
        )
    }

    public func updateProfile(userId: String, input: UserProfileInput) async throws -> ProfileWithGoals {
        let body = try JSONEncoder().encode(input)
        return try await execute(
            path: "v1/users/\(userId)/profile",
            method: "PUT",
            body: body,
            requiresAuth: true
        )
    }

    // MARK: - 5. Food Diary Endpoints

    public func getDiaryEntries(userId: String, date: String) async throws -> [DiaryEntry] {
        let queryItems = [URLQueryItem(name: "date", value: date)]
        return try await execute(
            path: "v1/users/\(userId)/diary",
            method: "GET",
            queryItems: queryItems,
            requiresAuth: true
        )
    }

    public func addDiaryEntry(userId: String, entry: DiaryEntryInput) async throws -> DiaryEntry {
        let body = try JSONEncoder().encode(entry)
        return try await execute(
            path: "v1/users/\(userId)/diary",
            method: "POST",
            body: body,
            requiresAuth: true
        )
    }

    public func updateDiaryEntry(userId: String, entryId: String, updates: DiaryEntryUpdate) async throws -> DiaryEntry {
        let body = try JSONEncoder().encode(updates)
        return try await execute(
            path: "v1/users/\(userId)/diary/\(entryId)",
            method: "PUT",
            body: body,
            requiresAuth: true
        )
    }

    public func deleteDiaryEntry(userId: String, entryId: String) async throws {
        let _: EmptyResponse = try await execute(
            path: "v1/users/\(userId)/diary/\(entryId)",
            method: "DELETE",
            body: nil,
            requiresAuth: true
        )
    }

    public func getDailyTotals(userId: String, date: String) async throws -> DailyTotals {
        let queryItems = [URLQueryItem(name: "date", value: date)]
        return try await execute(
            path: "v1/users/\(userId)/diary/totals",
            method: "GET",
            queryItems: queryItems,
            requiresAuth: true
        )
    }
}

public nonisolated struct EmptyResponse: Codable, Sendable {}
