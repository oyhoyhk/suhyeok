import CryptoKit
import Foundation
import Security

/// Signs ledger entries. The app uses a Secure Enclave key (it never leaves the chip, so a rewritten ledger
/// cannot be re-signed); Macs without one fall back to a software key kept in the keychain.
protocol LedgerSigning {
    var publicKey: P256.Signing.PublicKey { get }
    var strength: SignerStrength { get }
    /// Raw (r‖s) ECDSA P-256 / SHA-256 signature, the form WebCrypto verifies.
    func sign(_ data: Data) throws -> Data
}

enum SignerStrength: Equatable {
    case secureEnclave
    case software  // shown as "약한 보호"
}

struct SecureEnclaveSigner: LedgerSigning {
    let key: SecureEnclave.P256.Signing.PrivateKey

    init() throws { key = try SecureEnclave.P256.Signing.PrivateKey() }
    /// `dataRepresentation` is an encrypted handle only this Mac's Secure Enclave can use.
    init(dataRepresentation: Data) throws { key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: dataRepresentation) }

    var publicKey: P256.Signing.PublicKey { key.publicKey }
    var strength: SignerStrength { .secureEnclave }
    func sign(_ data: Data) throws -> Data { try key.signature(for: data).rawRepresentation }
}

struct SoftwareSigner: LedgerSigning {
    let key: P256.Signing.PrivateKey

    init() { key = P256.Signing.PrivateKey() }
    init(rawRepresentation: Data) throws { key = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation) }

    var publicKey: P256.Signing.PublicKey { key.publicKey }
    var strength: SignerStrength { .software }
    func sign(_ data: Data) throws -> Data { try key.signature(for: data).rawRepresentation }
}

/// The device's ledger key, stored in the login keychain (a Secure Enclave handle, or a software key's bytes).
enum DeviceKey {
    private static let service = "com.pickuma.agentdeck.ledger"
    private static let account = "device-key"

    /// Loads the stored key, or creates and stores one when none exists. nil when the keychain refuses.
    static func loadOrCreate() -> LedgerSigning? {
        if let stored = read() {
            if stored.first == 1, let s = try? SecureEnclaveSigner(dataRepresentation: stored.dropFirst()) { return s }
            if stored.first == 2, let s = try? SoftwareSigner(rawRepresentation: stored.dropFirst()) { return s }
            return nil  // present but unusable (another Mac's enclave handle): never overwrite it silently
        }
        if SecureEnclave.isAvailable, let s = try? SecureEnclaveSigner() {
            return write(Data([1]) + s.key.dataRepresentation) ? s : nil
        }
        let s = SoftwareSigner()
        return write(Data([2]) + s.key.rawRepresentation) ? s : nil
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func write(_ data: Data) -> Bool {
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}
