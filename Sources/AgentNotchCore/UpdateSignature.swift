import CryptoKit
import Foundation

/// D46: Ed25519 signature verification over the exact bytes of an update archive.
public enum UpdateSignature {
    public static let publicKeyByteCount = 32
    public static let signatureByteCount = 64
    public static let maxSignatureFileBytes = 1024

    /// Decode a base64-encoded 32-byte Curve25519 public key.
    public static func decodePublicKey(base64: String) -> Data? {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = Data(base64Encoded: trimmed),
              data.count == publicKeyByteCount
        else {
            return nil
        }
        return data
    }

    /// Verify a base64-encoded 64-byte Ed25519 signature over `archive` against `publicKey`.
    public static func verify(
        archive: Data,
        signatureBase64: String,
        publicKey: Data = UpdateKey.publicKey
    ) -> Bool {
        guard publicKey.count == publicKeyByteCount else { return false }
        let trimmed = signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let sigData = Data(base64Encoded: trimmed),
              sigData.count == signatureByteCount
        else {
            return false
        }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(sigData, for: archive)
    }

    /// Verify a UTF-8 `.zip.sig` payload over `archive` against `publicKey`.
    public static func verify(
        archive: Data,
        signatureData: Data,
        publicKey: Data = UpdateKey.publicKey
    ) -> Bool {
        guard signatureData.count <= maxSignatureFileBytes,
              let text = String(data: signatureData, encoding: .utf8)
        else {
            return false
        }
        return verify(archive: archive, signatureBase64: text, publicKey: publicKey)
    }
}
