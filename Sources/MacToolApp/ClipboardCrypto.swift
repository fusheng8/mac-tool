import CryptoKit
import Foundation
import MacToolCore
import Security

protocol ClipboardCryptoProviding: Sendable {
    var statusDescription: String { get }
    func seal(_ data: Data) throws -> Data
    func open(_ data: Data) throws -> Data
    func authenticationHash(_ data: Data) -> String
}

final class KeychainClipboardCryptoProvider: ClipboardCryptoProviding, @unchecked Sendable {
    private static let service = "com.fusheng.mac-tool.clipboard"
    private static let account = "history-key-v1"
    private let cipher: ClipboardCipher
    let statusDescription = "AES-256-GCM · 密钥仅限本机"

    init(createIfMissing: Bool) throws {
        switch Self.readKeyData() {
        case .success(let data):
            guard data.count == 32 else { throw ClipboardCryptoError.keyDamaged }
            cipher = ClipboardCipher(keyData: data)
        case .failure(let error as ClipboardCryptoError) where error == .keyMissing && createIfMissing:
            let generated = SymmetricKey(size: .bits256)
            let data = generated.withUnsafeBytes { Data($0) }
            try Self.saveKeyData(data)
            cipher = ClipboardCipher(keyData: data)
        case .failure(let error):
            throw error
        }
    }

    func seal(_ data: Data) throws -> Data {
        try cipher.seal(data)
    }

    func open(_ data: Data) throws -> Data {
        try cipher.open(data)
    }

    func authenticationHash(_ data: Data) -> String {
        cipher.authenticationHash(data)
    }

    private static func readKeyData() -> Result<Data, Error> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .failure(ClipboardCryptoError.keyMissing) }
        guard status == errSecSuccess, let data = result as? Data else {
            return .failure(ClipboardCryptoError.keychain(status))
        }
        return .success(data)
    }

    private static func saveKeyData(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ClipboardCryptoError.keychain(status) }
    }

    static func resetKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ClipboardCryptoError.keychain(status)
        }
    }
}

struct EphemeralClipboardCryptoProvider: ClipboardCryptoProviding {
    private let cipher: ClipboardCipher
    let statusDescription = "AES-256-GCM · 测试密钥"

    init(keyData: Data = Data(repeating: 0xA5, count: 32)) {
        cipher = ClipboardCipher(keyData: keyData)
    }

    func seal(_ data: Data) throws -> Data {
        try cipher.seal(data)
    }

    func open(_ data: Data) throws -> Data {
        try cipher.open(data)
    }

    func authenticationHash(_ data: Data) -> String {
        cipher.authenticationHash(data)
    }
}
