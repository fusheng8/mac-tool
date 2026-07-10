import CryptoKit
import Foundation

public struct FinderActionRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let id: UUID
    public let issuedAt: Int64
    public let action: String
    public let paths: [String]

    public init(
        version: Int = FinderActionRequest.currentVersion,
        id: UUID = UUID(),
        issuedAt: Int64 = Int64(Date().timeIntervalSince1970),
        action: String,
        paths: [String]
    ) {
        self.version = version
        self.id = id
        self.issuedAt = issuedAt
        self.action = action
        self.paths = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }
}

public enum FinderActionRequestError: LocalizedError, Equatable {
    case missingCredential
    case invalidEncoding
    case invalidSignature
    case unsupportedVersion
    case expired
    case unknownAction
    case invalidPath
    case tooManyPaths

    public var errorDescription: String? {
        switch self {
        case .missingCredential: return "Finder 桥接凭据不存在。请重新打开主应用后再试。"
        case .invalidEncoding: return "Finder 请求格式无效。"
        case .invalidSignature: return "Finder 请求签名校验失败。"
        case .unsupportedVersion: return "Finder 请求版本不受支持。"
        case .expired: return "Finder 请求已过期。"
        case .unknownAction: return "Finder 请求包含未知动作。"
        case .invalidPath: return "Finder 请求包含无效路径。"
        case .tooManyPaths: return "一次最多处理 100 个路径。"
        }
    }
}

public enum FinderActionCodec {
    public static func sign(_ request: FinderActionRequest, keyData: Data) throws -> (payload: String, signature: String) {
        guard keyData.count == 32 else { throw FinderActionRequestError.missingCredential }
        let payloadData = try encoder.encode(request)
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: payloadData,
            using: SymmetricKey(data: keyData)
        )
        return (base64URLEncode(payloadData), base64URLEncode(Data(authenticationCode)))
    }

    public static func verify(
        payload: String,
        signature: String,
        keyData: Data,
        now: Date = Date(),
        allowedActions: Set<String>
    ) throws -> FinderActionRequest {
        guard keyData.count == 32 else { throw FinderActionRequestError.missingCredential }
        guard let payloadData = base64URLDecode(payload),
              let signatureData = base64URLDecode(signature) else {
            throw FinderActionRequestError.invalidEncoding
        }
        let isValid = HMAC<SHA256>.isValidAuthenticationCode(
            signatureData,
            authenticating: payloadData,
            using: SymmetricKey(data: keyData)
        )
        guard isValid else { throw FinderActionRequestError.invalidSignature }
        let request = try decoder.decode(FinderActionRequest.self, from: payloadData)
        guard request.version == FinderActionRequest.currentVersion else {
            throw FinderActionRequestError.unsupportedVersion
        }
        guard abs(Int64(now.timeIntervalSince1970) - request.issuedAt) <= 30 else {
            throw FinderActionRequestError.expired
        }
        guard allowedActions.contains(request.action) else { throw FinderActionRequestError.unknownAction }
        guard !request.paths.isEmpty, request.paths.count <= 100 else {
            if request.paths.count > 100 { throw FinderActionRequestError.tooManyPaths }
            throw FinderActionRequestError.invalidPath
        }
        guard request.paths.allSatisfy({ path in
            path.hasPrefix("/") && URL(fileURLWithPath: path).standardizedFileURL.path == path
        }) else {
            throw FinderActionRequestError.invalidPath
        }
        return request
    }

    public static func makeURL(request: FinderActionRequest, keyData: Data) throws -> URL {
        let signed = try sign(request, keyData: keyData)
        var components = URLComponents()
        components.scheme = "macassistant"
        components.host = "context-menu"
        components.queryItems = [
            URLQueryItem(name: "payload", value: signed.payload),
            URLQueryItem(name: "signature", value: signed.signature)
        ]
        guard let url = components.url else { throw FinderActionRequestError.invalidEncoding }
        return url
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

public enum BridgeCredentialFile {
    public static func createIfMissing(at url: URL) throws -> Data {
        if FileManager.default.fileExists(atPath: url.path) {
            return try read(at: url)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try data.write(to: url, options: .withoutOverwriting)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return try read(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return data
    }

    public static func read(at url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FinderActionRequestError.missingCredential
        }
        let data = try Data(contentsOf: url)
        guard data.count == 32 else { throw FinderActionRequestError.missingCredential }
        return data
    }
}
