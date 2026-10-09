#!/usr/bin/env swift
//
// generate_signature.swift
// Macrofy QuickStart CLI Signature Generator
//
// Usage:
//   export MACROFY_APP_SECRET="<your-64-char-hex-secret>"
//   ./scripts/generate_signature.swift <user_id>
//
// Or interactively:
//   ./scripts/generate_signature.swift <user_id>
//   (Prompts for the secret securely without echoing it to terminal or shell history)
//
// This standalone script runs OUTSIDE the iOS app build so that sensitive
// developer secrets are never compiled into the iOS client binary or
// exposed in process argument inspection.

import Foundation
import CryptoKit
import Darwin

func printUsageAndExit() -> Never {
    let scriptName = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "generate_signature.swift"
    fputs("""
    Usage:
      export MACROFY_APP_SECRET="<your-secret>"
      \(scriptName) <user_id>

      OR (Interactive Secure Prompt):
      \(scriptName) <user_id>

    Computes an HMAC-SHA256 signature for use with Macrofy's POST /api/auth/connect.
    Keep the app secret in your terminal environment or enter it via secure prompt.

    """, stderr)
    exit(1)
}

var userId: String?

for arg in CommandLine.arguments.dropFirst() {
    if arg == "--help" || arg == "-h" {
        printUsageAndExit()
    } else if userId == nil {
        userId = arg
    } else {
        printUsageAndExit()
    }
}

// 1. Resolve User ID
let resolvedUserId: String
if let id = userId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
    resolvedUserId = id
} else {
    // Prompt interactively if not supplied
    if isatty(STDIN_FILENO) != 0 {
        fputs("Enter User ID: ", stderr)
        guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            fputs("Error: User ID is required.\n", stderr)
            exit(1)
        }
        resolvedUserId = line
    } else {
        fputs("Error: Missing user ID argument.\n\n", stderr)
        printUsageAndExit()
    }
}

// 2. Resolve App Secret from Environment or Secure Prompt
var secret: String? = ProcessInfo.processInfo.environment["MACROFY_APP_SECRET"]

if (secret == nil || secret!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && isatty(STDIN_FILENO) != 0 {
    // Secure prompt without echo to prevent terminal history or process argument exposure
    if let pass = getpass("Enter Macrofy App Secret (input will be hidden): ") {
        secret = String(cString: pass)
    }
}

guard let cleanSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanSecret.isEmpty else {
    fputs("Error: Missing app secret. Set MACROFY_APP_SECRET environment variable or enter it at the prompt.\n\n", stderr)
    printUsageAndExit()
}

// Macrofy computes HMAC-SHA256 over the userId using the literal UTF-8 bytes of appSecret.
let key = SymmetricKey(data: Data(cleanSecret.utf8))
let code = HMAC<SHA256>.authenticationCode(for: Data(resolvedUserId.utf8), using: key)
let signature = code.map { String(format: "%02hhx", $0) }.joined()

print("User ID:   \(resolvedUserId)")
print("Signature: \(signature)")
