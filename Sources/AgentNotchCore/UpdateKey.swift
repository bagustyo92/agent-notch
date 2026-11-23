import Foundation

/// D45: Ed25519 public key compiled into the binary for update archive verification.
/// Generated with `scripts/update-keygen.swift`; the private key lives only in the
/// `UPDATE_SIGNING_KEY` GitHub Actions secret and the maintainer's password manager.
public enum UpdateKey {
    /// Base64-encoded 32-byte raw Curve25519 public key.
    public static let publicKeyBase64 = "7n1/GAwMMFMHOVCTTzyKbZ+shdbGkI+tj+d6TIjvxBA="

    /// Raw 32-byte public key decoded from `publicKeyBase64`.
    public static let publicKey: Data = Data(base64Encoded: publicKeyBase64) ?? Data()
}
