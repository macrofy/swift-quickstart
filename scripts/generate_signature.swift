#!/usr/bin/env swift
//
// generate_signature.swift
// Macrofy QuickStart CLI Signature Generator
//
// Usage:
//   export MACROFY_APP_SECRET="<your-64-char-hex-secret>"
//   ./scripts/generate_signature.swift <user_id>
//
// Or inline:
//   ./scripts/generate_signature.swift --secret "<hex-secret>" <user_id>
//
// This standalone script runs OUTSIDE the iOS app build so that sensitive
// developer secrets are never compiled into the iOS client binary or
// source code. Copy the printed signature into the QuickStart app's UI.

import Foundation
import CryptoKit

func printUsageAndExit() -> Never {
    let scriptName = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "generate_signature.swift"
    fputs("""
    Usage:
      export MACROFY_APP_SECRET="<your-secret>"
      \(scriptName) <user_id>

      OR

      \(scriptName) --secret "<your-secret>" <user_id>

    Computes an HMAC-SHA256 signature for use with Macrofy's POST /api/auth/connect.
    Keep the app secret in your terminal environment — never embed it in client code.

    """, stderr)
    exit(1)
}

var secret: String? = ProcessInfo.processInfo.environment["MACROFY_APP_SECRET"]
var userId: String?

var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    if arg == "--secret" || arg == "-s" {
        guard !args.isEmpty else { printUsageAndExit() }
        secret = args.removeFirst()
    } else if arg == "--help" || arg == "-h" {
        printUsageAndExit()
    } else if userId == nil {
        userId = arg
    } else {
        printUsageAndExit()
    }
}

guard let cleanSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanSecret.isEmpty else {
    fputs("Error: Missing app secret. Set MACROFY_APP_SECRET environment variable or pass --secret.\n\n", stderr)
    printUsageAndExit()
}

guard let cleanUserId = userId?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanUserId.isEmpty else {
    fputs("Error: Missing user ID argument.\n\n", stderr)
    printUsageAndExit()
}

// Macrofy computes HMAC-SHA256 over the userId using the literal UTF-8 bytes of appSecret.
let key = SymmetricKey(data: Data(cleanSecret.utf8))
let code = HMAC<SHA256>.authenticationCode(for: Data(cleanUserId.utf8), using: key)
let signature = code.map { String(format: "%02hhx", $0) }.joined()

print("User ID:   \(cleanUserId)")
print("Signature: \(signature)")
