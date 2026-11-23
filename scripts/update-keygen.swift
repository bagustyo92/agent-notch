#!/usr/bin/env swift
// Generate an Ed25519 signing key pair for AgentNotch updates (D46).
// Usage: swift scripts/update-keygen.swift <out-private-key-file>
// Writes the base64 raw private key to <out-file> with mode 0600 and prints ONLY the public key.
import CryptoKit
import Darwin
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 2, !args[1].isEmpty, !args[1].hasPrefix("-") else {
    fail("usage: swift scripts/update-keygen.swift <out-file>")
}

let outPath = (args[1] as NSString).expandingTildeInPath
let privateKey = Curve25519.Signing.PrivateKey()
let privateB64 = privateKey.rawRepresentation.base64EncodedString() + "\n"
let publicB64 = privateKey.publicKey.rawRepresentation.base64EncodedString()

// Create atomically with mode 0600 and refuse to overwrite an existing key file.
let fd = open(outPath, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
if fd < 0 {
    let err = String(cString: strerror(errno))
    fail("could not create \(outPath): \(err)")
}

let bytes = Array(privateB64.utf8)
var written = 0
while written < bytes.count {
    let n = bytes.withUnsafeBytes { ptr in
        write(fd, ptr.baseAddress!.advanced(by: written), bytes.count - written)
    }
    if n < 0 {
        let err = String(cString: strerror(errno))
        close(fd)
        unlink(outPath)
        fail("could not write \(outPath): \(err)")
    }
    written += n
}

if fchmod(fd, S_IRUSR | S_IWUSR) != 0 || close(fd) != 0 {
    let err = String(cString: strerror(errno))
    unlink(outPath)
    fail("could not finalize \(outPath): \(err)")
}

// Print ONLY the public key; never print or log the private key.
print(publicB64)
