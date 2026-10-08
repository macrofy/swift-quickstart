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

    private let developerUserId = "user_ios_001_demo"
    // Development HMAC secret (Replace with backend handshake in production)
    private let devAppSecret = "YOUR_APP_SECRET"

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
            self.errorMessage = error.localizedDescription
        }
    }

    func loadDailyData() async {
        guard let user = currentUser else { return }
        let today = "2026-10-08"

        do {
            async let entries = client.getDiaryEntries(userId: user.id, date: today)
            async let totals = client.getDailyTotals(userId: user.id, date: today)
            
            self.diaryEntries = try await entries
            self.dailyTotals = try await totals
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Complete AI Vision pipeline: Job creation -> Cloud Storage PUT -> SSE Stream -> Auto-log
    func analyzeAndLogMeal(jpegData: Data) async {
        guard let user = currentUser else { return }
        self.isScanning = true
        self.scanStatusText = "Initializing scan job..."

        do {
            // 1. Create Job & obtain pre-signed upload URL
            let job = try await client.createScanJob(contentType: "image/jpeg", imageType: "photo")
            self.scanStatusText = "Uploading photo to Cloud Storage..."

            // 2. Direct binary upload to Cloud Storage
            try await client.uploadImageBinary(uploadUrl: job.uploadUrl, imageData: jpegData)
            self.scanStatusText = "AI Vision analyzing meal..."

            // 3. Listen to SSE Pub/Sub
            for try await update in await client.streamScanJobUpdates(jobId: job.jobId) {
                if let result = update.result {
                    self.scanStatusText = "Found \(result.name) (\(Int(result.calories)) kcal)"
                    
                    // 4. Automatically save recognized food to diary
                    let input = DiaryEntryInput(
                        date: "2026-10-08",
                        mealType: .lunch,
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
                    break
                }
            }

            self.scanStatusText = "Completed!"
            await loadDailyData()
        } catch {
            self.errorMessage = error.localizedDescription
        }
        self.isScanning = false
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
