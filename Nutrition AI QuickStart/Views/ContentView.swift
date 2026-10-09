//
//  ContentView.swift
//  Nutrition AI QuickStart
//
//  Created by Alexander Cleoni on 10/8/26.
//

import SwiftUI
import Combine
import UIKit

/// Manages the demo user identity atomically across concurrent view model initializations,
/// distinguishing genuine first-launch missing items from transient Keychain access failures.
private final class DemoIdentityManager: @unchecked Sendable {
    static let shared = DemoIdentityManager()
    private let lock = NSLock()
    private var cachedId: String?
    private let key = "macrofy_demo_external_user_id"

    func loadOrCreateDemoUserId(using keychain: KeychainStore) -> (id: String, persisted: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedId {
            return (cached, true)
        }

        switch keychain.readResult(key: key) {
        case .success(let data):
            if let existing = String(data: data, encoding: .utf8), !existing.isEmpty {
                cachedId = existing
                return (existing, true)
            }
        case .failure:
            // Keychain read encountered a transient error (e.g. device locked).
            // Do NOT generate a replacement ID or overwrite the existing key!
            let fallbackId = "user_ios_\(UUID().uuidString.prefix(12))"
            return (fallbackId, false)
        case .notFound:
            break
        }

        let newId = "user_ios_\(UUID().uuidString.prefix(12))"
        guard let data = newId.data(using: .utf8) else {
            return (newId, false)
        }
        if keychain.save(key: key, data: data) {
            cachedId = newId
            return (newId, true)
        }
        return (newId, false)
    }
}

@MainActor
final class MacrofyAppViewModel: ObservableObject {
    private let client = MacrofyClient()

    @Published var isAuthenticated = false
    @Published var currentUser: SessionUser?
    @Published var diaryEntries: [DiaryEntry] = []
    @Published var dailyTotals: DailyTotals?
    @Published var scanStatusText: String = ""
    @Published var isScanning = false
    @Published var errorMessage: String?
    @Published var persistenceWarning: String?

    // MARK: - Credentials & Signature Input
    //
    // No sensitive secrets are stored or compiled into this app.
    // Instead, compute an HMAC-SHA256 signature externally using
    // `./scripts/generate_signature.swift <userId>` (which reads the secret
    // from your shell environment) or via your backend, then paste the
    // resulting signature here.
    @Published var developerUserId: String
    @Published var signatureInput: String = ""

    /// Identifies the most recently started `loadDailyData()` call so a
    /// slower, superseded refresh can't overwrite newer results.
    private var latestDailyDataRequestID: UUID?

    /// Monotonically increasing counter for view-model auth updates.
    /// Prevents a slow background `checkAuthentication()` or a superseded
    /// 401 error from overwriting a newer published authenticated state.
    private var authRequestGeneration: UInt64 = 0

    /// Tracks the in-flight AI meal scan Task so that disconnecting or logging
    /// out cancels any active upload or stream immediately rather than leaving
    /// an orphaned task running or blocking future scans.
    private var activeScanTask: Task<Void, Never>?

    init() {
        let (id, persisted) = Self.loadOrCreateDemoUserId()
        self.developerUserId = id
        if !persisted {
            self.persistenceWarning = "Could not save demo user ID to the Keychain. Your demo diary may not persist across launches."
        }
        Task {
            await checkAuthentication()
        }
    }

    func checkAuthentication() async {
        authRequestGeneration &+= 1
        let generation = authRequestGeneration

        let snapshot = await client.sessionSnapshot()

        // Guard against an out-of-order snapshot application: if a newer
        // auth operation has started since this check began, discard this
        // result so it doesn't overwrite newer published state.
        guard generation == authRequestGeneration else { return }

        self.isAuthenticated = snapshot.isAuthenticated
        self.currentUser = snapshot.user
        if snapshot.isAuthenticated {
            await loadDailyData()
        }
    }

    func authenticate() async {
        self.errorMessage = nil

        let cleanUserId = developerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSignature = signatureInput.trimmingCharacters(in: .whitespacesAndNewlines)

        // Clear signature input from memory immediately after reading it,
        // whether the connection attempt succeeds or fails.
        defer {
            self.signatureInput = ""
        }

        guard !cleanUserId.isEmpty else {
            self.errorMessage = "User ID cannot be empty."
            return
        }

        guard !cleanSignature.isEmpty else {
            self.errorMessage = "Please enter an HMAC signature. Generate one using: ./scripts/generate_signature.swift \(cleanUserId)"
            return
        }

        authRequestGeneration &+= 1
        let generation = authRequestGeneration

        do {
            _ = try await client.connect(
                appId: AppConfig.appId,
                userId: cleanUserId,
                signature: cleanSignature
            )

            // Guard against an out-of-order completion: if a newer authentication
            // attempt was initiated while this one was in flight, discard this result.
            guard generation == authRequestGeneration else { return }

            // Publish the client's current atomic session snapshot rather than an obsolete response.
            let snapshot = await client.sessionSnapshot()
            guard generation == authRequestGeneration, snapshot.isAuthenticated else { return }

            self.isAuthenticated = true
            self.currentUser = snapshot.user
            await loadDailyData()
        } catch {
            guard generation == authRequestGeneration else { return }

            // Reconcile with the client's actual session: an overlapping connect
            // may have succeeded and installed a valid session!
            let snapshot = await client.sessionSnapshot()
            guard generation == authRequestGeneration else { return }

            if snapshot.isAuthenticated {
                self.isAuthenticated = true
                self.currentUser = snapshot.user
                self.errorMessage = nil
                await loadDailyData()
            } else {
                await handleError(error)
            }
        }
    }

    func clearAuthentication() async {
        // Cancel any active scan immediately and reset its UI state so the
        // scan doesn't continue uploading after logout or block re-scanning.
        cancelActiveScan()

        authRequestGeneration &+= 1
        // Invalidate any in-flight daily data refresh so it cannot repopulate
        // the view model after logout.
        latestDailyDataRequestID = UUID()

        // Always update the UI to the logged-out state, because in-memory
        // credentials have been cleared and the client has no usable token.
        self.isAuthenticated = false
        self.currentUser = nil
        self.diaryEntries = []
        self.dailyTotals = nil

        do {
            try await client.clearSession()
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func loadDailyData() async {
        guard let user = currentUser, isAuthenticated else { return }
        let today = Self.diaryDateString()

        let requestID = UUID()
        latestDailyDataRequestID = requestID

        do {
            async let entriesTask = client.getDiaryEntries(userId: user.id, date: today)
            async let totalsTask = client.getDailyTotals(userId: user.id, date: today)

            let (entries, totals) = try await (entriesTask, totalsTask)

            guard requestID == latestDailyDataRequestID,
                  self.isAuthenticated,
                  self.currentUser?.id == user.id else { return }

            self.diaryEntries = entries
            self.dailyTotals = totals
            self.errorMessage = nil
        } catch {
            guard requestID == latestDailyDataRequestID,
                  self.isAuthenticated,
                  self.currentUser?.id == user.id else { return }
            await handleError(error)
        }
    }

    func cancelActiveScan() {
        activeScanTask?.cancel()
        activeScanTask = nil
        self.isScanning = false
        self.scanStatusText = ""
    }

    func startScan(jpegData: Data) {
        guard !isScanning, isAuthenticated else { return }
        activeScanTask = Task {
            await analyzeAndLogMeal(jpegData: jpegData)
            activeScanTask = nil
        }
    }

    /// Complete AI Vision pipeline: Job creation -> Cloud Storage PUT -> SSE Stream -> Auto-log
    func analyzeAndLogMeal(jpegData: Data) async {
        guard let user = currentUser, isAuthenticated else { return }
        guard !isScanning else { return }

        self.isScanning = true
        self.errorMessage = nil
        self.scanStatusText = "Initializing scan job..."

        defer {
            self.isScanning = false
            if !isAuthenticated || Task.isCancelled {
                self.scanStatusText = ""
            }
        }

        do {
            try Task.checkCancellation()
            guard isAuthenticated else { return }

            // 1. Create Job & obtain pre-signed upload URL
            let job = try await client.createScanJob(contentType: "image/jpeg", imageType: "photo")

            try Task.checkCancellation()
            guard isAuthenticated else { return }

            self.scanStatusText = "Uploading photo to Cloud Storage..."

            // 2. Direct binary upload to Cloud Storage
            try await client.uploadImageBinary(uploadUrl: job.uploadUrl, imageData: jpegData)

            try Task.checkCancellation()
            guard isAuthenticated else { return }

            self.scanStatusText = "AI Vision analyzing meal..."

            // 3. Listen to SSE Pub/Sub until a terminal status arrives.
            var loggedEntry = false
            for try await update in await client.streamScanJobUpdates(jobId: job.jobId) {
                try Task.checkCancellation()
                guard isAuthenticated else { return }

                if update.status == "failed" {
                    throw MacrofyError.scanFailed(update.errorMessage ?? "AI vision was unable to analyze this photo.")
                }

                if let result = update.result {
                    self.scanStatusText = "Found \(result.name) (\(Int(result.calories)) kcal)"

                    // 4. Automatically save recognized food to diary
                    let input = DiaryEntryInput(
                        date: Self.diaryDateString(),
                        mealType: Self.suggestedMealType(),
                        foodName: result.name,
                        servingSize: result.servingSize,
                        calories: result.calories,
                        protein: result.protein,
                        carbs: result.carbs,
                        fat: result.fat,
                        ingredients: result.ingredients,
                        addedMethod: .image
                    )
                    _ = try await client.addDiaryEntry(userId: user.id, entry: input)
                    loggedEntry = true
                    break
                }
            }

            try Task.checkCancellation()
            guard isAuthenticated else { return }

            guard loggedEntry else {
                throw MacrofyError.sseTimeout
            }

            self.scanStatusText = "Completed!"
            self.errorMessage = nil
            await loadDailyData()
        } catch is CancellationError {
            // Task was cancelled (e.g. user disconnected during scan)
            self.scanStatusText = ""
        } catch {
            guard !Task.isCancelled, isAuthenticated else { return }
            await handleError(error)
            self.scanStatusText = ""
        }
    }

    // MARK: - Shared Error Handling

    private func handleError(_ error: Error) async {
        self.errorMessage = error.localizedDescription
        if case MacrofyError.unauthorized = error {
            authRequestGeneration &+= 1
            let generation = authRequestGeneration

            let snapshot = await client.sessionSnapshot()
            guard generation == authRequestGeneration else { return }

            if snapshot.isAuthenticated {
                self.isAuthenticated = true
                self.currentUser = snapshot.user
            } else {
                self.isAuthenticated = false
                self.currentUser = nil
                self.diaryEntries = []
                self.dailyTotals = nil
            }
        }
    }

    // MARK: - Helpers

    private static func diaryDateString(from date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func suggestedMealType(from date: Date = Date()) -> MealType {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 4..<11: return .breakfast
        case 11..<16: return .lunch
        case 16..<21: return .dinner
        default: return .snacks
        }
    }

    private static func loadOrCreateDemoUserId() -> (id: String, persisted: Bool) {
        DemoIdentityManager.shared.loadOrCreateDemoUserId(using: KeychainStore.shared)
    }
}

struct ContentView: View {
    @StateObject private var viewModel = MacrofyAppViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if !viewModel.isAuthenticated {
                    ScrollView {
                        VStack(spacing: 16) {
                            VStack(spacing: 6) {
                                Text("Macrofy Nutrition Engine")
                                    .font(.title2).bold()
                                Text("Connect session via HMAC Handshake")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 10)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("External User ID")
                                    .font(.caption).bold()
                                    .foregroundStyle(.secondary)
                                HStack {
                                    TextField("User ID", text: $viewModel.developerUserId)
                                        .textFieldStyle(.roundedBorder)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                    Button {
                                        UIPasteboard.general.string = viewModel.developerUserId
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("HMAC Signature")
                                    .font(.caption).bold()
                                    .foregroundStyle(.secondary)
                                SecureField("Paste 64-char hex signature", text: $viewModel.signatureInput)
                                    .textFieldStyle(.roundedBorder)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(.system(.body, design: .monospaced))

                                Text("Generate in terminal: `./scripts/generate_signature.swift \(viewModel.developerUserId)`")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Button("Connect User") {
                                Task { await viewModel.authenticate() }
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 8)
                        }
                        .padding()
                    }
                } else {
                    List {
                        Section("Daily Totals") {
                            if let totals = viewModel.dailyTotals {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text("\(Int(totals.calories)) kcal").font(.headline)
                                        Text("Energy").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("P: \(Int(totals.protein))g  C: \(Int(totals.carbs))g  F: \(Int(totals.fat))g")
                                        .font(.subheadline)
                                }
                            } else {
                                Text("Loading daily goals...")
                            }
                        }

                        Section("Logged Meals") {
                            if viewModel.diaryEntries.isEmpty {
                                Text("No meals logged yet today.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(viewModel.diaryEntries) { entry in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(entry.foodName).font(.body)
                                            Text(entry.mealType.rawValue.capitalized)
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text("\(Int(entry.calories ?? 0)) kcal")
                                            .font(.subheadline).bold()
                                    }
                                }
                            }
                        }

                        Section("AI Scan Demo") {
                            if viewModel.isScanning {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text(viewModel.scanStatusText).font(.subheadline)
                                }
                            } else {
                                Button("Simulate Camera Scan (Sample Meal Photo)") {
                                    guard let jpegData = Self.loadSampleMealJPEGData() else {
                                        viewModel.errorMessage = "Could not load sample_meal.png from the app bundle."
                                        return
                                    }
                                    viewModel.startScan(jpegData: jpegData)
                                }
                            }
                        }

                        Section {
                            Button("Disconnect Session", role: .destructive) {
                                Task { await viewModel.clearAuthentication() }
                            }
                        }
                    }
                }

                if let warning = viewModel.persistenceWarning {
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
            }
            .navigationTitle("Macrofy")
        }
    }

    private static func loadSampleMealJPEGData() -> Data? {
        guard let url = Bundle.main.url(forResource: "sample_meal", withExtension: "png"),
              let pngData = try? Data(contentsOf: url),
              let image = UIImage(data: pngData),
              let jpegData = image.jpegData(compressionQuality: 0.9) else {
            return nil
        }
        return jpegData
    }
}

#Preview {
    ContentView()
}
