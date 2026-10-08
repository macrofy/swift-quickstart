import Foundation

public nonisolated struct AppConfig {
    public static let baseURL = URL(string: "https://api.macrofy.com")!
    
    // Application ID provided in your Macrofy Developer Portal
    // Format: 10–12 alphanumeric/URL-safe characters (e.g., "app_abc123xy")
    public static let appId = "YOUR_APP_ID"
}
