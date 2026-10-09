import Foundation

public actor MacrofyClient {
    private let baseURL: URL
    private let session: URLSession
    private let keychain = KeychainStore.shared
    
    private let tokenKey = "macrofy_jwt_token"
    private let userKey = "macrofy_session_user"

    private(set) public var currentToken: String?
    private(set) public var currentUser: SessionUser?

    /// Incremented at the start of every `connect()`/`refreshSession()`
    /// call so a slower, superseded call can detect that a newer
    /// authentication operation has already taken effect.
    private var authGeneration: UInt64 = 0

    /// The generation number of the authentication call that most recently
    /// installed a session via `setSession`. Unlike `authGeneration` (which
    /// advances the moment a call *starts*), this only advances when a call
    /// actually *succeeds* in installing a session, so a response is never
    /// discarded just because a different, newer call happened to start (and
    /// then fail) in the meantime.
    private var installedAuthGeneration: UInt64 = 0

    public init(baseURL: URL = AppConfig.baseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session

        // Restore the token and user from Keychain on launch. Both must
        // restore successfully for the session to be considered valid — a
        // partially-restored session (e.g. a decodable token but a
        // missing/corrupted user) would otherwise let `isAuthenticated`
        // report true while there's no user to load data for.
        let restoredToken = keychain.read(key: tokenKey).flatMap { String(data: $0, encoding: .utf8) }
        let restoredUser = keychain.read(key: userKey).flatMap { try? JSONDecoder().decode(SessionUser.self, from: $0) }

        if let restoredToken, let restoredUser {
            self.currentToken = restoredToken
            self.currentUser = restoredUser
        } else {
            self.currentToken = nil
            self.currentUser = nil
            if restoredToken != nil || restoredUser != nil {
                // Clean up whichever half of the pair did restore so a
                // future launch doesn't keep finding the same incomplete
                // session.
                keychain.delete(key: tokenKey)
                keychain.delete(key: userKey)
            }
        }
    }

    // MARK: - Session Management

    /// Persists the session in memory and in the Keychain.
    ///
    /// The in-memory session (`currentToken`/`currentUser`) is always set so
    /// the current app run can proceed immediately. If Keychain persistence
    /// fails or only partially succeeds, any partial write is rolled back so
    /// a future relaunch never reads a mismatched token/user pair (which
    /// would otherwise appear "authenticated" with no user to load data
    /// for). The return value reports whether persistence fully succeeded.
    @discardableResult
    public func setSession(token: String, user: SessionUser) -> Bool {
        self.currentToken = token
        self.currentUser = user

        guard let tokenData = token.data(using: .utf8),
              let userData = try? JSONEncoder().encode(user) else {
            keychain.delete(key: tokenKey)
            keychain.delete(key: userKey)
            return false
        }

        let tokenSaved = keychain.save(key: tokenKey, data: tokenData)
        let userSaved = keychain.save(key: userKey, data: userData)

        guard tokenSaved && userSaved else {
            // Avoid leaving a half-written session that would desync the
            // token and user on the next launch.
            keychain.delete(key: tokenKey)
            keychain.delete(key: userKey)
            return false
        }
        return true
    }

    public func clearSession() {
        self.currentToken = nil
        self.currentUser = nil
        keychain.delete(key: tokenKey)
        keychain.delete(key: userKey)
    }

    public var isAuthenticated: Bool {
        currentToken != nil && currentUser != nil
    }

    /// Atomically reads whether the client is authenticated together with
    /// the current user, in a single actor hop. Reading `isAuthenticated`
    /// and `currentUser` as two separate awaited property accesses risks the
    /// actor processing another call (e.g. a concurrent `clearSession()` or
    /// `connect()`) in between, yielding an inconsistent combination of the
    /// two from the caller's perspective.
    public func sessionSnapshot() -> (isAuthenticated: Bool, user: SessionUser?) {
        (isAuthenticated, currentUser)
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

        // In Fastify, setting Content-Type: application/json on GET/DELETE without a body causes 400 Bad Request
        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Track which token (if any) this specific request used, so a 401
        // response can be correlated back to it below.
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
            // Only clear the session if it still holds the exact token that
            // was rejected. A concurrent request may have already installed
            // a newer, valid session (e.g. via refreshSession()); clearing
            // unconditionally would discard that replacement session and
            // force an unnecessary reconnect.
            if let requestToken, requestToken == currentToken {
                clearSession()
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
        authGeneration &+= 1
        let generation = authGeneration

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
        authGeneration &+= 1
        let generation = authGeneration

        let response: AuthResponse = try await execute(
            path: "api/auth/refresh",
            method: "POST",
            body: nil,
            requiresAuth: true
        )

        return try applyAuthResponse(response, generation: generation)
    }

    /// Applies a `connect()`/`refreshSession()` response to the session,
    /// guarding against two races:
    /// - Staleness: only decline to install when a *strictly newer*
    ///   authentication operation has already installed its own session —
    ///   installing this response would then regress to older credentials.
    ///   Comparing against `installedAuthGeneration` (not `authGeneration`)
    ///   matters here: if a newer call merely *started* but failed before
    ///   installing anything, this response is still the only valid session
    ///   available and must be installed, or the caller would be told
    ///   "success" while the client has no token at all.
    /// - Persistence failure: if the Keychain write fails, this throws
    ///   instead of silently reporting success, since the session would
    ///   otherwise work only in memory and disappear on relaunch.
    private func applyAuthResponse(_ response: AuthResponse, generation: UInt64) throws -> AuthResponse {
        guard generation >= installedAuthGeneration else {
            if let currentToken, let currentUser {
                return AuthResponse(token: currentToken, user: currentUser)
            }
            return response
        }

        guard setSession(token: response.token, user: response.user) else {
            throw MacrofyError.serverError(
                statusCode: 0,
                message: "Authenticated successfully, but failed to persist the session securely. Please try again."
            )
        }
        installedAuthGeneration = generation
        return response
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
    ///
    /// A watchdog cancels the underlying connection if no terminal
    /// (`completed`/`failed`) update arrives within `timeout` seconds, so
    /// callers never wait indefinitely; the stream throws
    /// `MacrofyError.sseTimeout` in that case. If the caller stops iterating
    /// the stream early (for example, after it has already found a result),
    /// `onTermination` cancels the producer task so the underlying network
    /// connection doesn't keep running in the background. A 401 response is
    /// mapped to `MacrofyError.unauthorized` (instead of a generic
    /// `.serverError`) and, if it still matches the token this request used,
    /// clears the session — keeping parity with the REST pipeline so a
    /// rejected/expired token during a scan also resets authentication state
    /// instead of leaving the UI stuck on an authenticated screen with a
    /// dead session.
    public func streamScanJobUpdates(jobId: String, timeout: TimeInterval = 60) -> AsyncThrowingStream<ImageScanStatusUpdate, Error> {
        let streamURL = baseURL.appendingPathComponent("v1/scan/image/\(jobId)/stream")
        let token = self.currentToken
        let session = self.session

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
                            if let token, self.currentToken == token {
                                self.clearSession()
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

            // Fires when the stream finishes, is cancelled, or the consumer
            // stops iterating and releases it — ensures the network request
            // and watchdog never outlive interest in their results.
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
