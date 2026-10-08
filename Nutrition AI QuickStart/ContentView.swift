//
//  ContentView.swift
//  Nutrition AI QuickStart
//
//  Created by Alexander Cleoni on 10/8/26.
//

import SwiftUI
import Combine

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

    // MARK: - Demo Identity
    //
    // `developerUserId` is a stable, per-install identifier generated once
    // and persisted in the Keychain, so each install of this QuickStart gets
    // its own isolated Macrofy user, profile, and diary rather than every
    // install sharing one hardcoded ID. In a real app, replace this with the
    // ID of your already-signed-in user (from your own account system)
    // instead of a device-generated ID.
    private let developerUserId: String = MacrofyAppViewModel.loadOrCreateDemoUserId()

    // MARK: - Development-Only Authentication
    //
    // `devAppSecret` only compiles into DEBUG builds, so the literal secret
    // can never end up inside a Release/TestFlight/App Store binary. In
    // Release builds this is always `nil`, which forces `authenticate()`
    // onto the error path below rather than silently shipping a usable
    // client-side secret. Production apps must never embed `appSecret`
    // client-side at all: have your backend compute the HMAC signature and
    // return it to the device (see README "Secure Production Handshake").
    #if DEBUG
    private let devAppSecret: String? = "YOUR_APP_SECRET"
    #else
    private let devAppSecret: String? = nil
    #endif

    /// Identifies the most recently started `loadDailyData()` call so a
    /// slower, superseded refresh can't overwrite newer results.
    private var latestDailyDataRequestID: UUID?

    init() {
        Task {
            await checkAuthentication()
        }
    }

    func checkAuthentication() async {
        let authState = await client.isAuthenticated
        let user = await client.currentUser
        self.isAuthenticated = authState
        self.currentUser = user
        if authState {
            await loadDailyData()
        }
    }

    func authenticate() async {
        self.errorMessage = nil

        guard let devAppSecret else {
            self.errorMessage = "Client-side signing is disabled in this build. Implement the backend handshake described in the README before shipping."
            return
        }

        do {
            let signature = SignatureUtility.generateHMAC(
                appSecret: devAppSecret,
                userId: developerUserId
            )
            let response = try await client.connect(
                appId: AppConfig.appId,
                userId: developerUserId,
                signature: signature
            )
            self.isAuthenticated = true
            self.currentUser = response.user
            await loadDailyData()
        } catch {
            handleError(error)
        }
    }

    func loadDailyData() async {
        guard let user = currentUser else { return }
        let today = Self.diaryDateString()

        let requestID = UUID()
        latestDailyDataRequestID = requestID

        do {
            async let entriesTask = client.getDiaryEntries(userId: user.id, date: today)
            async let totalsTask = client.getDailyTotals(userId: user.id, date: today)

            // Await both together so a failure in either one doesn't leave
            // the UI showing a mix of new entries and stale totals (or vice
            // versa) — we only assign once both have succeeded.
            let (entries, totals) = try await (entriesTask, totalsTask)

            // A newer refresh may have started and finished while this one
            // was in flight; don't let this stale result overwrite it.
            guard requestID == latestDailyDataRequestID else { return }

            self.diaryEntries = entries
            self.dailyTotals = totals
            self.errorMessage = nil
        } catch {
            guard requestID == latestDailyDataRequestID else { return }
            handleError(error)
        }
    }

    /// Complete AI Vision pipeline: Job creation -> Cloud Storage PUT -> SSE Stream -> Auto-log
    func analyzeAndLogMeal(jpegData: Data) async {
        guard let user = currentUser else { return }
        // Prevent a second scan from starting (and possibly double-logging)
        // while one is already in flight.
        guard !isScanning else { return }

        self.isScanning = true
        self.errorMessage = nil
        self.scanStatusText = "Initializing scan job..."

        do {
            // 1. Create Job & obtain pre-signed upload URL
            let job = try await client.createScanJob(contentType: "image/jpeg", imageType: "photo")
            self.scanStatusText = "Uploading photo to Cloud Storage..."

            // 2. Direct binary upload to Cloud Storage
            try await client.uploadImageBinary(uploadUrl: job.uploadUrl, imageData: jpegData)
            self.scanStatusText = "AI Vision analyzing meal..."

            // 3. Listen to SSE Pub/Sub until a terminal status arrives.
            var loggedEntry = false
            for try await update in await client.streamScanJobUpdates(jobId: job.jobId) {
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

            // The stream ended without ever delivering a result (e.g. the
            // connection dropped or the watchdog timeout fired) — treat that
            // as a failure rather than silently reporting success.
            guard loggedEntry else {
                throw MacrofyError.sseTimeout
            }

            self.scanStatusText = "Completed!"
            self.errorMessage = nil
            await loadDailyData()
        } catch {
            handleError(error)
            self.scanStatusText = ""
        }
        self.isScanning = false
    }

    // MARK: - Shared Error Handling

    /// Surfaces `error` to the UI. If the error indicates the session itself
    /// is no longer valid, also resets authentication state so the user
    /// returns to the connect screen instead of being stuck on an
    /// authenticated view that can no longer load data.
    private func handleError(_ error: Error) {
        self.errorMessage = error.localizedDescription
        if case MacrofyError.unauthorized = error {
            self.isAuthenticated = false
            self.currentUser = nil
            self.diaryEntries = []
            self.dailyTotals = nil
        }
    }

    // MARK: - Helpers

    /// Today's date formatted as `yyyy-MM-dd`, as required by the diary endpoints.
    private static func diaryDateString(from date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Heuristically derives a meal category from the time of the scan. A
    /// production app should let the user pick the meal (breakfast/lunch/
    /// dinner/snacks) instead of guessing from the clock.
    private static func suggestedMealType(from date: Date = Date()) -> MealType {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 4..<11: return .breakfast
        case 11..<16: return .lunch
        case 16..<21: return .dinner
        default: return .snacks
        }
    }

    /// Generates (once) or loads a stable, device-local external user ID for
    /// this QuickStart demo so separate installs don't share one Macrofy
    /// diary. Replace with your real signed-in user's ID in production.
    private static func loadOrCreateDemoUserId() -> String {
        let key = "macrofy_demo_external_user_id"
        if let data = KeychainStore.shared.read(key: key),
           let existing = String(data: data, encoding: .utf8),
           !existing.isEmpty {
            return existing
        }
        let newId = "user_ios_\(UUID().uuidString.prefix(12))"
        if let data = newId.data(using: .utf8) {
            _ = KeychainStore.shared.save(key: key, data: data)
        }
        return newId
    }
}

struct ContentView: View {
    @StateObject private var viewModel = MacrofyAppViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if !viewModel.isAuthenticated {
                    VStack(spacing: 12) {
                        Text("Macrofy Nutrition Engine")
                            .font(.title2).bold()
                        Text("Connect your session via HMAC Handshake")
                            .font(.subheadline).foregroundStyle(.secondary)

                        Button("Connect User") {
                            Task { await viewModel.authenticate() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
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

                        Section("AI Scan Demo") {
                            if viewModel.isScanning {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text(viewModel.scanStatusText).font(.subheadline)
                                }
                            } else {
                                Button("Simulate Camera Scan (Salmon Bowl)") {
                                    // Simulated 1x1 JPEG byte data for testing
                                    let sampleJpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
                                    Task {
                                        await viewModel.analyzeAndLogMeal(jpegData: sampleJpeg)
                                    }
                                }
                            }
                        }
                    }
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
}

#Preview {
    ContentView()
}
