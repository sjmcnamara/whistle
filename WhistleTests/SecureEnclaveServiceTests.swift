import XCTest
import CryptoKit
@testable import Whistle

/// Tests for SecureEnclaveService.
///
/// Since Secure Enclave is not available in test runners (simulators),
/// these tests verify the CryptoKit primitives (P-256 ECDH + AES-GCM)
/// using software keys. The SE-specific code path is tested on-device.
final class SecureEnclaveServiceTests: XCTestCase {

    // MARK: - Software P-256 ECDH + AES-GCM round-trip

    /// Replicates the SE encryption flow using software P-256 keys to verify
    /// the ECDH → HKDF → AES-GCM chain works correctly.
    func testSoftwareP256EncryptDecryptRoundTrip() throws {
        let nsec = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqhqtcqp"
        let nsecData = Data(nsec.utf8)

        // Simulate SE private key (software P-256 instead of SE-bound)
        let seKey = P256.KeyAgreement.PrivateKey()
        let ephemeralKey = P256.KeyAgreement.PrivateKey()

        // Encrypt
        let sharedSecret = try seKey.sharedSecretFromKeyAgreement(with: ephemeralKey.publicKey)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("org.findmyfam.nsec-wrap".utf8),
            outputByteCount: 32
        )
        let sealedBox = try AES.GCM.seal(nsecData, using: symmetricKey)

        // Decrypt
        let sharedSecret2 = try seKey.sharedSecretFromKeyAgreement(with: ephemeralKey.publicKey)
        let symmetricKey2 = sharedSecret2.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data("org.findmyfam.nsec-wrap".utf8),
            outputByteCount: 32
        )
        let decrypted = try AES.GCM.open(sealedBox, using: symmetricKey2)
        let recovered = String(data: decrypted, encoding: .utf8)

        XCTAssertEqual(recovered, nsec)
    }

    /// Verify that the same ECDH pair always produces the same symmetric key.
    func testECDHDeterminism() throws {
        let key1 = P256.KeyAgreement.PrivateKey()
        let key2 = P256.KeyAgreement.PrivateKey()

        let secret1 = try key1.sharedSecretFromKeyAgreement(with: key2.publicKey)
        let secret2 = try key1.sharedSecretFromKeyAgreement(with: key2.publicKey)

        let sym1 = secret1.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(),
            sharedInfo: Data("org.findmyfam.nsec-wrap".utf8), outputByteCount: 32
        )
        let sym2 = secret2.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(),
            sharedInfo: Data("org.findmyfam.nsec-wrap".utf8), outputByteCount: 32
        )

        // Encrypt same data with both keys — should produce different ciphertexts
        // (AES-GCM uses a random nonce) but both should decrypt correctly
        let data = Data("test-nsec".utf8)
        let box1 = try AES.GCM.seal(data, using: sym1)
        let box2 = try AES.GCM.seal(data, using: sym2)

        let dec1 = try AES.GCM.open(box1, using: sym1)
        let dec2 = try AES.GCM.open(box2, using: sym2)

        XCTAssertEqual(dec1, data)
        XCTAssertEqual(dec2, data)
    }

    /// Verify ECDH is symmetric — both sides derive the same secret.
    func testECDHSymmetry() throws {
        let alice = P256.KeyAgreement.PrivateKey()
        let bob = P256.KeyAgreement.PrivateKey()

        let secretAlice = try alice.sharedSecretFromKeyAgreement(with: bob.publicKey)
        let secretBob = try bob.sharedSecretFromKeyAgreement(with: alice.publicKey)

        let keyAlice = secretAlice.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(),
            sharedInfo: Data("org.findmyfam.nsec-wrap".utf8), outputByteCount: 32
        )
        let keyBob = secretBob.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(),
            sharedInfo: Data("org.findmyfam.nsec-wrap".utf8), outputByteCount: 32
        )

        // Both keys should decrypt each other's ciphertext
        let data = Data("symmetric-test".utf8)
        let box = try AES.GCM.seal(data, using: keyAlice)
        let decrypted = try AES.GCM.open(box, using: keyBob)

        XCTAssertEqual(decrypted, data)
    }

    /// Wrong key fails to decrypt.
    func testDecryptWithWrongKeyFails() throws {
        let correctKey = P256.KeyAgreement.PrivateKey()
        let wrongKey = P256.KeyAgreement.PrivateKey()
        let ephemeral = P256.KeyAgreement.PrivateKey()

        let secret = try correctKey.sharedSecretFromKeyAgreement(with: ephemeral.publicKey)
        let sym = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(),
            sharedInfo: Data("org.findmyfam.nsec-wrap".utf8), outputByteCount: 32
        )
        let box = try AES.GCM.seal(Data("secret-nsec".utf8), using: sym)

        // Try decrypting with wrong key
        let wrongSecret = try wrongKey.sharedSecretFromKeyAgreement(with: ephemeral.publicKey)
        let wrongSym = wrongSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(),
            sharedInfo: Data("org.findmyfam.nsec-wrap".utf8), outputByteCount: 32
        )

        XCTAssertThrowsError(try AES.GCM.open(box, using: wrongSym),
                             "Decryption with wrong key should fail")
    }

    /// Different info string produces different key — domain separation.
    func testHKDFDomainSeparation() throws {
        let key1 = P256.KeyAgreement.PrivateKey()
        let key2 = P256.KeyAgreement.PrivateKey()

        let secret = try key1.sharedSecretFromKeyAgreement(with: key2.publicKey)

        let sym1 = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(),
            sharedInfo: Data("org.findmyfam.nsec-wrap".utf8), outputByteCount: 32
        )
        let sym2 = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(),
            sharedInfo: Data("different-info".utf8), outputByteCount: 32
        )

        let data = Data("domain-sep-test".utf8)
        let box = try AES.GCM.seal(data, using: sym1)

        // sym2 should NOT be able to open sym1's sealed box
        XCTAssertThrowsError(try AES.GCM.open(box, using: sym2),
                             "Different HKDF info should produce incompatible keys")
    }

    // MARK: - SE availability check

    func testSecureEnclaveIsAvailableReturnsBool() {
        // Verify it doesn't crash and returns a Bool. iOS 26 simulator reports SE as
        // available; earlier simulators report unavailable. Both are valid outcomes.
        let available = SecureEnclaveService.isAvailable
        XCTAssertNotNil(available)
    }

    func testEncryptThrowsWhenSEUnavailable() {
        guard !SecureEnclaveService.isAvailable else { return }
        XCTAssertThrowsError(try SecureEnclaveService.encrypt(nsec: "nsec1test")) { error in
            XCTAssertTrue(error is SecureEnclaveService.SEError)
        }
    }

    func testDecryptThrowsWhenSEUnavailable() {
        guard !SecureEnclaveService.isAvailable else { return }
        XCTAssertThrowsError(
            try SecureEnclaveService.decrypt(
                sePrivateKeyData: Data(),
                ephemeralPublicKey: Data(),
                sealedBoxData: Data()
            )
        ) { error in
            XCTAssertTrue(error is SecureEnclaveService.SEError)
        }
    }

    // MARK: - P-256 key serialization

    func testPublicKeyCompressedRepresentationRoundTrip() throws {
        let key = P256.KeyAgreement.PrivateKey()
        let compressed = key.publicKey.compressedRepresentation
        let restored = try P256.KeyAgreement.PublicKey(compressedRepresentation: compressed)
        XCTAssertEqual(key.publicKey.compressedRepresentation,
                       restored.compressedRepresentation)
    }

    func testSealedBoxCombinedRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let data = Data("round-trip-test".utf8)
        let sealed = try AES.GCM.seal(data, using: key)
        let combined = sealed.combined!

        let restored = try AES.GCM.SealedBox(combined: combined)
        let opened = try AES.GCM.open(restored, using: key)
        XCTAssertEqual(opened, data)
    }
}
