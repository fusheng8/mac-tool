import CryptoKit
import Foundation

public enum ClipboardCryptoError: LocalizedError, Equatable, Sendable {
    case keyMissing
    case keyDamaged
    case keychain(Int32)
    case invalidCiphertext

    public var errorDescription: String? {
        switch self {
        case .keyMissing:
            return "剪贴板加密密钥缺失。历史记录已暂停，请重试访问或清空无法解密的历史。"
        case .keyDamaged:
            return "剪贴板加密密钥已损坏。历史记录已暂停。"
        case .keychain(let status):
            return "无法访问钥匙串（错误码 \(status)）。"
        case .invalidCiphertext:
            return "剪贴板密文校验失败。"
        }
    }
}

public struct ClipboardCipher: Sendable {
    private let key: SymmetricKey

    public init(keyData: Data) {
        key = SymmetricKey(data: keyData)
    }

    public func seal(_ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw ClipboardCryptoError.invalidCiphertext
        }
        return combined
    }

    public func open(_ data: Data) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        } catch {
            throw ClipboardCryptoError.invalidCiphertext
        }
    }

    public func authenticationHash(_ data: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: key)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
