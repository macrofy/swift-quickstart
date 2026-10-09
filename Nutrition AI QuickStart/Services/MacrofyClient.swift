import Foundation

public actor MacrofyClient {
    private let baseURL: URL
    private let appId: String
    private let session: URLSession
    private let keychain = KeychainStore.shared

    /// Scoped Keychain key combining the app ID and host so different
    /// tenants or environments (e.g. staging vs. prod) never share or
    /// overwrite each other's credentials.
    private let sessionKey: String

    private(set) public var currentToken: String?
    private(set) public var currentUser: SessionUser?

    /// Incremented whenever an auth operation starts OR when the session is
    /// explicitly modified/cleared, so pending operations can detect that
    /// their results have been superseded.
    private var authGeneration: UInt64 = 0

    /// The generation of the authentication call that most recently installed
    /// a session via `setSession`. Only advances when a session is actually
    /// installed or explicitly cleared/set, so older in-flight requests cannot
    /// overwrite newer ones or resurrect credentials after logout.
    private var installedAuthGeneration: UInt64 = 0

    /// Atomic on-disk representation storing token and user together in a
    /// single Keychain item, preventing concurrent writes from interleaving
    /// a token with the wrong user.
    private struct PersistedSession: Codable {
        let token: String
        let user: SessionUser
    }

    public init(
        appId: String = AppConfig.appId,
        baseURL: URL = AppConfig.baseURL,
        session: URLSession = .shared
    ) {
        self.appId = appId
        self.baseURL = baseURL
        self.session = session

        // Derive a tenant- and host-scoped key (e.g. "session_app_FitCorp123_api.macrofy.com")
        let host = baseURL.host ?? "default"
        self.sessionKey = "macrofy_session_\(appId)_\(host)"

        // Restore the token and user atomically from Keychain on launch.
        // In addition to decoding successfully, the restored user's appId
        // MUST match the configured appId — preventing an old tenant's
        // session from being used after an App ID reconfiguration.
        if let data = keychain.read(key: sessionKey),
           let record = try? JSONDecoder().decode(PersistedSession.self, from: data),
           record.user.appId == appId {
            self.currentToken = record.token
            self.currentUser = record.user
        } else {
            self.currentToken = nil
            self.currentUser = nil
            // Clear any corrupted or mismatched record for this scope.
            keychain.delete(key: sessionKey)
        }
    }

    // MARK: - Session Management

    /// Persists the session atomically in the Keychain and updates memory.
    ///
    /// If Keychain persistence fails, any previous in-memory session is
    /// preserved so in-memory state matches what is actually stored, and
    /// the call returns `false`. Calling this explicitly also advances
    /// `authGeneration` so any in-flight `connect()` or `refreshSession()`
    /// calls are marked superseded and will not overwrite this session.
    @discardableResult
    public func setSession(token: String, user: SessionUser) -> Bool {
        // Enforce tenant boundary: cannot install a user belonging to a
        // different appId than this client is configured for.
        guard user.appId == self.appId else {
            return false
        }

        // Advance auth generation to invalidate any in-flight auth requests
        authGeneration &+= 1
        installedAuthGeneration = authGeneration

        let previousToken = self.currentToken
        let previousUser = self.currentUser

        let record = PersistedSession(token: token, user: user)
        guard let data = try? JSONEncoder().encode(record),
              keychain.save(key: sessionKey, data: data) else {
            // Restore previous in-memory state on failure so memory and
            // Keychain remain consistent.
            self.currentToken = previousToken
            self.currentUser = previousUser
            return false
        }

        self.currentToken = token
        self.currentUser = user
        return true
    }

    /// Clears the session from memory and Keychain.
    ///
    /// Advances `authGeneration` so any in-flight `connect()` or
    /// `refreshSession()` cannot resurrect credentials after logout.
    public func clearSession() {
        authGeneration &+= 1
        installedAuthGeneration = authGeneration

        self.currentToken = nil
        self.currentUser = nil
        keychain.delete(key: sessionKey)
    }

    public var isAuthenticated: Bool {
        currentToken != nil && currentUser != nil
    }

    /// Atomically reads whether the client is authenticated together with
    /// the current user, in a single actor hop.
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
            // was rejected.
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
    /// guarding against staleness and persistence failures.
    private func applyAuthResponse(_ response: AuthResponse, generation: UInt64) throws -> AuthResponse {
        // If a newer auth operation has started or the session was explicitly
        // changed/cleared since this call began, fail with sessionSuperseded
        // rather than installing stale credentials or reporting false success.
        guard generation >= installedAuthGeneration && generation == authGeneration else {
            throw MacrofyError.sessionSuperseded
        }

        guard setSession(token: response.token, user: response.user) else {
            throw MacrofyError.serverError(
                statusCode: 0,
                message: "Authenticated successfully, but failed to persist the session securely. Please try again."
            )
        }
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
