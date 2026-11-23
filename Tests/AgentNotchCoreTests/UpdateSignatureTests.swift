import CryptoKit
import Foundation
import Testing
@testable import AgentNotchCore

@Suite struct UpdateSignatureTests {
    @Test func committedPublicKeyHasValidLength() {
        #expect(UpdateKey.publicKey.count == UpdateSignature.publicKeyByteCount)
        #expect(UpdateSignature.decodePublicKey(base64: UpdateKey.publicKeyBase64) == UpdateKey.publicKey)
    }

    @Test func validSignaturePassesWithOrWithoutNewline() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let archive = Data("synthetic-agentnotch-archive-bytes".utf8)
        let signature = try privateKey.signature(for: archive).base64EncodedString()

        #expect(UpdateSignature.verify(archive: archive, signatureBase64: signature, publicKey: publicKey))
        #expect(UpdateSignature.verify(archive: archive, signatureBase64: signature + "\n", publicKey: publicKey))
        #expect(UpdateSignature.verify(archive: archive, signatureData: Data((signature + "\n").utf8), publicKey: publicKey))
    }

    @Test func flippedByteFailsVerification() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        var archive = Data("synthetic-agentnotch-archive-bytes".utf8)
        let signature = try privateKey.signature(for: archive).base64EncodedString()

        archive[0] ^= 0x01
        #expect(!UpdateSignature.verify(archive: archive, signatureBase64: signature, publicKey: publicKey))
    }

    @Test func truncatedBadBase64WrongKeyAndOversizeSigFail() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let archive = Data("synthetic-agentnotch-archive-bytes".utf8)
        let rawSig = try privateKey.signature(for: archive)
        let validB64 = rawSig.base64EncodedString()

        // Wrong public key
        #expect(!UpdateSignature.verify(archive: archive, signatureBase64: validB64, publicKey: otherKey.publicKey.rawRepresentation))

        // Truncated signature
        let truncatedB64 = rawSig.prefix(63).base64EncodedString()
        #expect(!UpdateSignature.verify(archive: archive, signatureBase64: truncatedB64, publicKey: publicKey))

        // Bad base64
        #expect(!UpdateSignature.verify(archive: archive, signatureBase64: "not valid base64!!!", publicKey: publicKey))
        #expect(!UpdateSignature.verify(archive: archive, signatureBase64: "", publicKey: publicKey))

        // Wrong public key length
        #expect(!UpdateSignature.verify(archive: archive, signatureBase64: validB64, publicKey: Data(repeating: 0, count: 16)))

        // Oversized signature payload
        let oversized = Data(repeating: UInt8(ascii: "A"), count: UpdateSignature.maxSignatureFileBytes + 1)
        #expect(!UpdateSignature.verify(archive: archive, signatureData: oversized, publicKey: publicKey))
    }
}
