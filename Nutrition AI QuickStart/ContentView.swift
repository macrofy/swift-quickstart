//
//  ContentView.swift
//  Nutrition AI QuickStart
//
//  Created by Alexander Cleoni on 10/8/26.
//

import SwiftUI
import Combine
import UIKit

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
    private let developerUserId: String

    // MARK: - Development-Only Authentication
    //
    // `devAppSecret` only compiles into Debug builds running on the iOS
    // Simulator, so the literal secret can never end up inside a
    // distributable binary. `#if DEBUG` alone isn't sufficient: a Debug
    // build can still be signed and installed on a physical device (e.g.
    // shared ad hoc or via TestFlight), which would carry the real secret
    // with it. Release, TestFlight, App Store, and even Debug builds on a
    // physical device all get `nil` here, which forces `authenticate()`
    // onto the error path below rather than silently shipping a usable
    // client-side secret. Production apps must never embed `appSecret`
    // client-side at all: have your backend compute the HMAC signature and
    // return it to the device (see README "Secure Production Handshake").
    #if DEBUG && targetEnvironment(simulator)
    private let devAppSecret: String? = "YOUR_APP_SECRET"
    #else
    private let devAppSecret: String? = nil
    #endif

    /// Identifies the most recently started `loadDailyData()` call so a
    /// slower, superseded refresh can't overwrite newer results.
    private var latestDailyDataRequestID: UUID?

    init() {
        let (id, persisted) = Self.loadOrCreateDemoUserId()
        self.developerUserId = id
        if !persisted {
            self.errorMessage = "Could not save a stable demo user ID to the Keychain. Your demo diary may not persist across launches."
        }
        Task {
            await checkAuthentication()
        }
    }

    func checkAuthentication() async {
        // Read authentication state and the current user together in one
        // actor hop so they can't reflect two different moments in time
        // (e.g. a concurrent connect/clear happening between two separate
        // awaited reads).
        let snapshot = await client.sessionSnapshot()
        self.isAuthenticated = snapshot.isAuthenticated
        self.currentUser = snapshot.user
        if snapshot.isAuthenticated {
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
            await handleError(error)
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
            await handleError(error)
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

                    // 4. Automatically save recognized food to diary.
                    //
                    // Note: if this specific addDiaryEntry call succeeds on
                    // the server but its response is lost or fails to decode
                    // locally, a manual retry (a fresh tap of the scan
                    // button) will create a new scan job and post a second,
                    // duplicate entry. We intentionally don't try to detect
                    // and suppress that here: the Macrofy API has no
                    // idempotency-key mechanism to tie a retry back to a
                    // specific prior attempt, and a heuristic based on food
                    // name + recent timestamp alone would also incorrectly
                    // swallow a second, legitimate scan of the same food
                    // eaten again shortly after the first — silently
                    // dropping real data is worse than an occasional,
                    // user-correctable duplicate entry.
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
            await handleError(error)
            self.scanStatusText = ""
        }
        self.isScanning = false
    }

    // MARK: - Shared Error Handling

    /// Surfaces `error` to the UI. If the error indicates the session itself
    /// is no longer valid, re-checks the client's *actual current* session
    /// before clearing view-model authentication state: a 401 can be thrown
    /// for a request that used an old token even after a concurrent
    /// `refreshSession()` has already installed a newer, valid one, and in
    /// that case the client is still authenticated even though this
    /// particular request failed.
    private func handleError(_ error: Error) async {
        self.errorMessage = error.localizedDescription
        if case MacrofyError.unauthorized = error {
            let snapshot = await client.sessionSnapshot()
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
    ///
    /// Returns whether the ID is actually persisted in the Keychain. If
    /// persistence fails even after a retry, the ID is still usable for the
    /// current launch, but callers should warn that it won't survive a
    /// relaunch (a new, different ID would otherwise be generated next
    /// time, silently orphaning today's demo diary).
    private static func loadOrCreateDemoUserId() -> (id: String, persisted: Bool) {
        let key = "macrofy_demo_external_user_id"
        if let data = KeychainStore.shared.read(key: key),
           let existing = String(data: data, encoding: .utf8),
           !existing.isEmpty {
            return (existing, true)
        }

        let newId = "user_ios_\(UUID().uuidString.prefix(12))"
        guard let data = newId.data(using: .utf8) else {
            return (newId, false)
        }
        // Retry once in case of a transient Keychain failure before giving
        // up and falling back to an ephemeral (non-persisted) ID.
        if KeychainStore.shared.save(key: key, data: data) {
            return (newId, true)
        }
        if KeychainStore.shared.save(key: key, data: data) {
            return (newId, true)
        }
        return (newId, false)
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
                                Button("Simulate Camera Scan (Sample Meal Photo)") {
                                    Task {
                                        guard let jpegData = Self.loadSampleMealJPEGData() else {
                                            viewModel.errorMessage = "Could not load sample_meal.png from the app bundle."
                                            return
                                        }
                                        await viewModel.analyzeAndLogMeal(jpegData: jpegData)
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

    /// Loads the bundled `sample_meal.png` demo asset and re-encodes it as
    /// JPEG, since the scan pipeline is wired up for `image/jpeg` uploads
    /// (the `Content-Type` sent here must match the one used to create the
    /// scan job).
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
