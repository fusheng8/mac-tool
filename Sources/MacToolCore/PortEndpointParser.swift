import Foundation

public struct ParsedPortEndpoint: Equatable, Sendable {
    public let localAddress: String
    public let localPort: Int
    public let remoteAddress: String?
    public let remotePort: Int?

    public var hasRemoteEndpoint: Bool { remoteAddress != nil || remotePort != nil }

    public var localDescription: String {
        localAddress.contains(":") ? "[\(localAddress)]:\(localPort)" : "\(localAddress):\(localPort)"
    }
}

public enum PortEndpointParser {
    public static func parse(_ endpoint: String) -> ParsedPortEndpoint? {
        let parts = endpoint.components(separatedBy: "->")
        guard parts.count <= 2, let local = parseSide(parts[0]) else { return nil }
        let remote: (address: String, port: Int)?
        if parts.count == 2 {
            guard let parsedRemote = parseSide(parts[1]) else { return nil }
            remote = parsedRemote
        } else {
            remote = nil
        }
        return ParsedPortEndpoint(
            localAddress: local.address,
            localPort: local.port,
            remoteAddress: remote?.address,
            remotePort: remote?.port
        )
    }

    public static func port(from endpoint: String) -> Int? {
        parse(endpoint)?.localPort
    }

    public static func inferredProtocol(from endpoint: String) -> String {
        endpoint.localizedCaseInsensitiveContains("udp") ? "UDP" : "TCP"
    }

    private static func parseSide(_ rawValue: String) -> (address: String, port: Int)? {
        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""
        guard !token.isEmpty else { return nil }

        if token.hasPrefix("["), let closing = token.firstIndex(of: "]") {
            let address = String(token[token.index(after: token.startIndex)..<closing])
            let suffix = token[token.index(after: closing)...]
            guard suffix.first == ":", let port = leadingPort(suffix.dropFirst()) else { return nil }
            return (address, port)
        }

        guard let colon = token.lastIndex(of: ":"), let port = leadingPort(token[token.index(after: colon)...]) else {
            return nil
        }
        let address = String(token[..<colon])
        return (address.isEmpty ? "*" : address, port)
    }

    private static func leadingPort<S: StringProtocol>(_ value: S) -> Int? {
        let digits = value.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}
