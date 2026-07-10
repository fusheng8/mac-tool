import Foundation

public enum PortEndpointParser {
    public static func port(from endpoint: String) -> Int? {
        guard let colonIndex = endpoint.lastIndex(of: ":") else { return nil }
        let tail = endpoint[endpoint.index(after: colonIndex)...]
        let digits = tail.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    public static func inferredProtocol(from endpoint: String) -> String {
        endpoint.localizedCaseInsensitiveContains("udp") ? "UDP" : "TCP"
    }
}
