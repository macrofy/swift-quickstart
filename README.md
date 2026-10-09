# Macrofy iOS QuickStart Guide

Official native Swift & SwiftUI starter kit for Macrofy. The bundled `MacrofyClient` SDK supports AI meal vision, barcode resolution, food search, user profiles, and nutrition tracking against the live Macrofy API (`api-v0`). The included demo app exercises the authentication, AI meal scan, and diary/daily-totals workflows end-to-end; Provides copy-in code examples for barcode scanning, food search, and profile management to add to your own screens.

---

## 1. Project Overview & Architecture

The application is structured with zero third-party dependencies, relying exclusively on Apple's first-party frameworks: `Foundation`, `SwiftUI`, `Combine`, `CryptoKit`, and `Security` (iOS Keychain).

```mermaid
flowchart TD
    UI[SwiftUI Views & ViewModels\n@MainActor] --> Client[MacrofyClient\nActor Engine]
    Client --> Keychain[KeychainStore\nSecurity Framework]
    Client --> Config[AppConfig\nEndpoints & AppID]
    Client --> API[Macrofy API\napi.macrofy.com]
    Client --> Storage[Cloud Storage\nDirect Image Upload]
```


### Swift Concurrency & Strict Isolation Model
The codebase is configured for modern Swift concurrency (`Swift 5.9+ / Swift 6`):
- **Actor Isolation**: Network requests, tokens, and active sessions are managed inside the `MacrofyClient` actor to prevent data races.
- **MainActor Separation**: The presentation layer (`MacrofyAppViewModel`, `ContentView`) is isolated to `@MainActor`.
- **Nonisolated Domain Models**: All models (`Models.swift`), configuration (`Configuration.swift`), errors (`MacrofyError.swift`), and utilities (`KeychainStore.swift`) conform to `Sendable` and are marked `nonisolated` to allow seamless passing across actor boundaries without concurrency warnings.

---

## 2. Project File Structure

```
Nutrition AI QuickStart/
├── App/
│   ├── Nutrition_AI_QuickStartApp.swift   # SwiftUI App lifecycle entry point
│   └── Configuration.swift                # AppConfig (baseURL, appId)
├── Models/
│   └── Models.swift                       # Codable & Sendable data schemas
├── Services/
│   ├── MacrofyClient.swift                # Actor-based API client & network engine
│   ├── MacrofyError.swift                 # Error types & LocalizedError conformance
│   └── KeychainStore.swift                # Thread-safe Keychain persistence wrapper
├── Views/
│   └── ContentView.swift                  # SwiftUI demo view & MacrofyAppViewModel
└── Resources/
    ├── Assets.xcassets                    # App icons & accent colors
    └── sample_meal.png                    # Bundled demo meal image for AI scanning

scripts/
└── generate_signature.swift               # Standalone CLI HMAC signature generator
```

---

## 3. How the App Is Configured

### 1. API Configuration (`Configuration.swift`)
The base URL is preconfigured to Macrofy's live API:
```swift
public nonisolated struct AppConfig {
    public static let baseURL = URL(string: "https://api.macrofy.com")!
    public static let appId = "YOUR_APP_ID" // Replace with your portal App ID
}
```

### 2. Authentication Handshake (`ContentView.swift`)
Macrofy authenticates mobile clients using a cryptographic signature:
```swift
// In production, this call is made by your backend (see Step 5 below).
// For local testing, generate a signature in your terminal with:
//   ./scripts/generate_signature.swift <userId>
let response = try await client.connect(
    appId: AppConfig.appId,
    userId: developerUserId,
    signature: signature
)
```
Upon a successful connect call, `MacrofyClient` automatically stores the 30-day Bearer JWT and user profile in the iOS Keychain (scoped to this `appId` and host) and injects `Authorization: Bearer <token>` into all subsequent authenticated requests.

> **Security note**: To prevent accidental credential leaks, **no secrets are embedded in the iOS app**. For local testing, run `./scripts/generate_signature.swift <userId>` in your terminal and enter your secret at the secure prompt (terminal input is hidden so it is never recorded in shell history), then paste the resulting signature into the app's connect screen. The HMAC-SHA256 computation uses `appSecret` exactly as issued by the Developer Portal — its literal UTF-8 bytes are the HMAC key, even though the secret is formatted as a hex-looking string; do not hex-decode it first, or every signature will be rejected. Because `HMAC_SHA256(appSecret, userId)` is deterministic, treat any generated signature as sensitive and short-lived: generate it immediately before calling `connect`, never log it, and prefer proxying this exchange through your backend (Step 5 below) so the secret and signature never reach the client at all.

### 3. Food Diary & Daily Progress
`MacrofyAppViewModel.loadDailyData()` fetches diary entries and daily aggregate totals in parallel:
```swift
async let entries = client.getDiaryEntries(userId: user.id, date: today)
async let totals = client.getDailyTotals(userId: user.id, date: today)
self.diaryEntries = try await entries
self.dailyTotals = try await totals
```

### 4. AI Vision Meal Scanning Pipeline
The application demonstrates the full meal analysis lifecycle via `analyzeAndLogMeal(jpegData:)`:
1. **Create Scan Job (`POST /v1/scan/image`)**: Requests a job and receives a short-lived pre-signed PUT upload URL.
2. **Binary Upload (`PUT uploadUrl`)**: Streams the raw JPEG bytes directly to cloud storage without passing binary data through application web servers.
3. **SSE Pub/Sub Stream (`GET /v1/scan/image/:jobId/stream`)**: Subscribes to Server-Sent Events emitted by Macrofy's vision engine.
4. **Auto-Logging (`POST /v1/users/:id/diary`)**: Once meal recognition completes, logs the parsed meal and ingredients directly into the user's food diary and refreshes daily totals.

---

## 4. Setup & Running the QuickStart

### Prerequisites
- A Mac running a macOS release compatible with Xcode 26.1 or later (see Apple's Xcode release notes for exact requirements)
- Xcode 26.1 or later — this project's `.xcodeproj` uses a project file format (and Swift concurrency build settings) that older Xcode versions cannot open or compile
- iOS Deployment Target: iOS 26.1+

### Quick Run Steps
1. Open `Nutrition AI QuickStart.xcodeproj` in Xcode.
2. In `Configuration.swift`, ensure `appId` matches your registered Application ID from the Macrofy Developer Portal.
3. Select an iOS Simulator (e.g., iPhone 16 Pro) and press **Cmd + R** to run.
4. On the simulator's connect screen, tap the copy button next to the **External User ID** field.
5. In your terminal, run the standalone signature generator with the copied User ID:
   ```bash
   ./scripts/generate_signature.swift <pasted-user-id>
   ```
   When prompted, enter your Macrofy App Secret. The prompt hides your input so the secret is never saved in shell command history or process inspection tables. (You can also set `MACROFY_APP_SECRET` in your environment if you prefer.)
6. Paste the printed signature into the **HMAC Signature** field in the simulator and tap **Connect User**.
7. Once connected, view the Daily Totals and Logged Meals sections, or tap **Simulate Camera Scan (Sample Meal Photo)** to observe the real-time AI scan state machine.

---

## 5. How to Build on Top of This Project

The steps below are client-library code examples, not features of the bundled demo screen — copy them into your own SwiftUI views to exercise the parts of the `MacrofyClient` SDK (barcode scanning, food search, and profile management) that the demo app doesn't showcase directly. Use them as the starting point for evolving this QuickStart into a full production application:

### Step 1: Replace Sample Image with Real Camera / Photo Picker
In `ContentView.swift`, the AI scan demo currently uses mock JPEG bytes. Replace this with SwiftUI's `PhotosPicker` or `AVCaptureSession`:

```swift
import PhotosUI

struct MealPhotoPickerView: View {
    @ObservedObject var viewModel: MacrofyAppViewModel
    @State private var selectedItem: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $selectedItem, matching: .images) {
            Label("Scan Meal from Photo", systemImage: "camera")
        }
        .onChange(of: selectedItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    await viewModel.analyzeAndLogMeal(jpegData: data)
                }
            }
        }
    }
}
```

### Step 2: Add Live Barcode Scanning
Add a barcode scanning sheet using VisionKit or `AVCaptureMetadataOutput`:

```swift
// Example calling MacrofyClient once barcode is detected:
func handleBarcodeDetected(_ barcode: String) async {
    // Sanitize to numeric digits only (7 to 14 digits)
    let cleanCode = barcode.filter { $0.isNumber }
    do {
        let food = try await client.scanBarcode(barcode: cleanCode)
        print("Scanned product: \(food.name), Calories: \(food.macros.energy ?? 0)")
    } catch {
        print("Barcode lookup failed: \(error.localizedDescription)")
    }
}
```

### Step 3: Implement Text-Based Food Search & Autocomplete
Build a searchable food catalog view using `client.searchFoods(query:limit:)`:

```swift
struct FoodSearchView: View {
    @State private var searchQuery = ""
    @State private var searchResults: [FoodItem] = []
    let client = MacrofyClient()

    var body: some View {
        List(searchResults) { food in
            VStack(alignment: .leading) {
                Text(food.name).font(.headline)
                if let brand = food.brand {
                    Text(brand).font(.subheadline).foregroundStyle(.secondary)
                }
                Text("\(Int(food.macros.energy ?? 0)) kcal | P: \(Int(food.macros.protein ?? 0))g")
                    .font(.caption)
            }
        }
        .searchable(text: $searchQuery)
        .task(id: searchQuery) {
            guard searchQuery.count >= 2 else {
                searchResults = []
                return
            }
            do {
                try await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            } catch {
                return // Superseded by a newer keystroke; let the new task take over.
            }
            guard !Task.isCancelled,
                  let results = try? await client.searchFoods(query: searchQuery, limit: 20),
                  !Task.isCancelled else { return }
            self.searchResults = results
        }
    }
}
```

### Step 4: Add User Profile & Mifflin-St Jeor Goals
Allow users to update their stats and automatically compute customized macro goals:

```swift
func updateUserProfile(userId: String) async throws {
    let input = UserProfileInput(
        age: 30,
        gender: .male,
        height: HeightImperial(feet: 5, inches: 10), // must be a complete pair, or omitted entirely
        weight: 175,
        activityLevel: .moderate,
        calorieDeficit: .maintain,
        dietType: .highProtein
    )
    let profileWithGoals = try await client.updateProfile(userId: userId, input: input)
    print("New daily target: \(profileWithGoals.goals.calories) kcal")
}
```

### Step 5: Secure Production Handshake (Backend Architecture)
For production releases, **never send `appSecret`, or the HMAC signature it produces, to the iOS client**. `HMAC_SHA256(appSecret, userId)` is deterministic, so anyone who captures the signature in transit could replay it to request another 30-day JWT for that user. The fix is to keep the *entire* handshake — including the call to `POST /api/auth/connect` itself — on your backend:

```
iOS Client                     Your Backend                  Macrofy API
    |                               |                             |
    | 1. Request session (userId)   |                             |
    |------------------------------>|                             |
    |                               | 2. Compute HMAC SHA-256     |
    |                               |    using appSecret          |
    |                               | 3. POST /api/auth/connect   |
    |                               |    (appId, userId, signature)
    |                               |---------------------------->|
    |                               | 4. Returns { token, user }  |
    |                               |<-----------------------------|
    | 5. Returns { token, user }    |                             |
    |<-------------------------------|                             |
```
Your backend must forward **both** fields from Macrofy's response — not just the JWT. The iOS client needs the `SessionUser` object (specifically `user.id`) for every diary and profile call, so a JWT alone isn't enough to use the rest of the SDK. Install the backend's response directly on the device instead of calling `client.connect(...)` (which performs its own client-side call to Macrofy's `/api/auth/connect` — exactly what this flow avoids):
```swift
struct BackendSessionResponse: Decodable {
    let token: String
    let user: SessionUser
}

let backendResponse = try await yourBackendClient.requestSession(userId: developerUserId)
guard await client.setSession(token: backendResponse.token, user: backendResponse.user) else {
    throw MacrofyError.serverError(statusCode: 0, message: "Failed to persist session to Keychain.")
}
```
With this flow, neither `appSecret` nor the signature it produces ever reaches the device — only the resulting `{ token, user }` pair does — which eliminates the signature-replay risk entirely while still giving the client everything it needs. If you need additional protection against a compromised network path, ask Macrofy support whether `POST /api/auth/connect` supports a challenge/nonce option.

### Step 6: Token Auto-Refresh
Before the 30-day JWT expires, call `client.refreshSession()` to maintain continuous authentication without requiring the user to reconnect:

```swift
func refreshTokenIfNeeded() async {
    do {
        _ = try await client.refreshSession()
    } catch {
        // Fall back to re-running the connect handshake
    }
}
```

---

## 6. API Guidelines & Guardrails

1. **Empty Body Header Constraint**: Fastify returns `400 Bad Request` if `Content-Type: application/json` is sent on `GET` or `DELETE` requests that have no body. `MacrofyClient.execute` already guards against this by checking `if let body = body`.
2. **Height Field Pairing**: The API persists height as a single value server-side, so `heightFeet` and `heightInches` must always be sent together or omitted entirely. `UserProfileInput.height: HeightImperial?` enforces this at the type level — construct it via `HeightImperial(feet:inches:)` or leave it `nil`; there is no way to set only one component.
3. **Date Formatting**: Diary endpoints expect strict `YYYY-MM-DD` string format (e.g., `2026-10-08`). Do not send full ISO-8601 timestamps with times.
4. **Barcode Validation**: Barcode lookups require 7 to 14 numeric characters. Always strip spaces, hyphens, and letters prior to making requests.
5. **Cloud Storage Upload Content-Type**: The `Content-Type` specified when creating a scan job (e.g., `image/jpeg`) must match the `Content-Type` header passed in the direct binary `PUT` upload.
6. **Clearing Nullable Fields**: In `UserProfileInput` and `DiaryEntryUpdate`, update fields use `NullableUpdate<T>`. Leaving a field `.unchanged` omits it from the JSON payload (leaving the server's existing value intact), whereas setting it to `.clear` encodes an explicit JSON `null` to clear the stored value. Setting `.set(value)` updates it to the new value.
