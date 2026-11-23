#!/usr/bin/env swift
// Sign or verify an AgentNotch update archive with Ed25519 (D45).
// Sign:   UPDATE_SIGNING_KEY=<base64> swift scripts/sign-update.swift <zip>
// Verify: swift scripts/sign-update.swift --verify <zip> <pubkey-base64>
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func decodeExact(_ base64: String, length: Int, label: String) -> Data {
    let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = Data(base64Encoded: trimmed), data.count == length else {
        fail("invalid \(label)")
    }
    return data
}

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "--verify" {
    guard args.count == 3 else {
        fail("usage: swift scripts/sign-update.swift --verify <zip> <pubkey-base64>")
    }
    let zipURL = URL(fileURLWithPath: args[1])
    let sigURL = URL(fileURLWithPath: args[1] + ".sig")
    let pubKeyData = decodeExact(args[2], length: 32, label: "public key")

    guard let zipData = try? Data(contentsOf: zipURL) else {
        fail("could not read archive \(zipURL.path)")
    }
    guard let sigText = try? String(contentsOf: sigURL, encoding: .utf8) else {
        fail("could not read signature \(sigURL.path)")
    }
    let sigData = decodeExact(sigText, length: 64, label: "signature")

    guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData) else {
        fail("invalid Ed25519 public key")
    }
    guard publicKey.isValidSignature(sigData, for: zipData) else {
        fail("signature verification failed for \(zipURL.path)")
    }
    print("verified \(zipURL.lastPathComponent)")
    exit(0)
}

guard args.count == 1, !args[0].hasPrefix("-") else {
    fail("usage: swift scripts/sign-update.swift <zip> | --verify <zip> <pubkey-base64>")
}

guard let rawKeyB64 = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"],
      !rawKeyB64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    fail("UPDATE_SIGNING_KEY environment variable is missing or empty")
}

let privKeyData = decodeExact(rawKeyB64, length: 32, label: "UPDATE_SIGNING_KEY")
guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privKeyData) else {
    fail("could not initialize Ed25519 private key")
}

let zipURL = URL(fileURLWithPath: args[0])
guard let zipData = try? Data(contentsOf: zipURL) else {
    fail("could not read archive \(zipURL.path)")
}

guard let signature = try? privateKey.signature(for: zipData) else {
    fail("failed to sign \(zipURL.path)")
}

let sigURL = URL(fileURLWithPath: args[0] + ".sig")
let sigText = signature.base64EncodedString() + "\n"
do {
    try sigText.write(to: sigURL, atomically: true, encoding: .utf8)
} catch {
    fail("could not write \(sigURL.path): \(error.localizedDescription)")
}

print("signed \(sigURL.lastPathComponent)")
