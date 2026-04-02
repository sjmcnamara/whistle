import Foundation
import CryptoKit

/// Encrypts/decrypts the nsec using a Secure Enclave-bound P-256 key.
///
/// **How it works:**
/// 1. A P-256 private key is generated inside the Secure Enclave (hardware-bound, non-exportable).
/// 2. An ephemeral P-256 key pair is generated in software for one-time ECDH.
/// 3. ECDH between the SE key and ephemeral key produces a shared secret.
/// 4. HKDF derives an AES-256 key from the shared secret.
/// 5. AES-GCM encrypts the nsec. The sealed box (nonce + ciphertext + tag) is stored in the Keychain.
///
/// The SE private key never leaves hardware. The ephemeral public key is stored alongside
/// the sealed box so the same shared secret can be re-derived on decryption.
///
/// **secp256k1 incompatibility:** Secure Enclave only supports P-256 (NIST). Since Nostr uses
/// secp256k1 keys, we cannot store the nsec directly in SE. Instead we use SE as a key-wrapping
/// layer — the nsec is AES-encrypted with an SE-derived key.
struct SecureEnclaveService {

    private static let hkdfInfo = Data("org.findmyfam.nsec-wrap".utf8)

    /// Whether the device has a Secure Enclave.
    static var isAvailable: Bool {
        SecureEnclave.isAvailable
    }

    // MARK: - Encrypt

    /// Encrypt an nsec string using a Secure Enclave-derived AES key.
    /// Returns the SE private key data, ephemeral public key, and sealed box.
    struct EncryptionResult {
        let sePrivateKeyData: Data
        let ephemeralPublicKey: Data
        let sealedBox: Data
    }

    static func encrypt(nsec: String) throws -> EncryptionResult {
        guard SecureEnclave.isAvailable else {
            throw SEError.unavailable
        }

        let sePrivateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
        let ephemeralKey = P256.KeyAgreement.PrivateKey()

        let sharedSecret = try sePrivateKey.sharedSecretFromKeyAgreement(
            with: ephemeralKey.publicKey
        )

        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )

        let nsecData = Data(nsec.utf8)
        let sealedBox = try AES.GCM.seal(nsecData, using: symmetricKey)

        return EncryptionResult(
            sePrivateKeyData: sePrivateKey.dataRepresentation,
            ephemeralPublicKey: ephemeralKey.publicKey.compressedRepresentation,
            sealedBox: sealedBox.combined!
        )
    }

    // MARK: - Decrypt

    /// Decrypt an nsec from its SE-encrypted form.
    static func decrypt(
        sePrivateKeyData: Data,
        ephemeralPublicKey: Data,
        sealedBoxData: Data
    ) throws -> String {
        guard SecureEnclave.isAvailable else {
            throw SEError.unavailable
        }

        let sePrivateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            dataRepresentation: sePrivateKeyData
        )
        let ephemeralPub = try P256.KeyAgreement.PublicKey(
            compressedRepresentation: ephemeralPublicKey
        )

        let sharedSecret = try sePrivateKey.sharedSecretFromKeyAgreement(with: ephemeralPub)

        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )

        let sealedBox = try AES.GCM.SealedBox(combined: sealedBoxData)
        let plaintext = try AES.GCM.open(sealedBox, using: symmetricKey)

        guard let nsec = String(data: plaintext, encoding: .utf8) else {
            throw SEError.decryptionFailed
        }

        return nsec
    }

    // MARK: - Errors

    enum SEError: LocalizedError {
        case unavailable
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Secure Enclave is not available on this device"
            case .decryptionFailed: return "Failed to decrypt nsec from Secure Enclave-wrapped storage"
            }
        }
    }
}
