import DDCBackend
import CoreGraphics
import Foundation

final class DisplayDetector {
    private let displayProvider: (() -> [DisplaySnapshot])?

    init(displayProvider: (() -> [DisplaySnapshot])? = nil) {
        self.displayProvider = displayProvider
    }

    func onlineDisplays() -> [DisplaySnapshot] {
        if let displayProvider {
            return displayProvider()
        }
        var buffer = Array(repeating: DCLDisplayInfo(), count: Int(DCL_MAX_DISPLAYS))
        let count = DCLCopyOnlineDisplays(&buffer, Int32(buffer.count))
        var displays = count > 0 ? buffer.prefix(Int(count)).map(Self.snapshot) : []

        for activeDisplay in activeDisplaySnapshots() where !displays.contains(where: { sameDisplay($0, activeDisplay) }) {
            displays.append(activeDisplay)
        }

        return displays.filter { !$0.isVirtualPlaceholder }.sorted { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn {
                return !lhs.isBuiltIn
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    func activeDisplayCount() -> Int {
        onlineDisplays().filter(\.isActive).count
    }

    func findDisplay(for profile: DisplayProfile) -> DisplaySnapshot? {
        let candidates = onlineDisplays()
            .map { display in (display, matchScore(display: display, profile: profile)) }
            .filter { $0.1.matches }
        guard let bestScore = candidates.map({ $0.1.score }).max() else { return nil }
        let best = candidates.filter { $0.1.score == bestScore }
        guard best.count == 1 else { return nil }
        return best[0].0
    }

    func matchScore(display: DisplaySnapshot, profile: DisplayProfile) -> (matches: Bool, score: Int) {
        switch profile.matchMode {
        case .strict:
            return strictMatchScore(display: display, rule: profile.match)
        case .weighted:
            let score = weightedMatchScore(display: display, rule: profile.match)
            return (score >= DisplayMatchRule.normalizedThreshold(profile.match.matchThreshold), score)
        }
    }

    private func strictMatchScore(display: DisplaySnapshot, rule: DisplayMatchRule) -> (matches: Bool, score: Int) {
        let candidates: [(String?, String?, Int)] = [
            (DisplaySnapshot.normalizedIdentity(rule.edidUUID), DisplaySnapshot.normalizedIdentity(display.edidUUID), 100),
            (DisplaySnapshot.normalizedIdentity(rule.alphanumericSerial), DisplaySnapshot.normalizedIdentity(display.alphanumericSerial), 90),
            (vendorModelSerialIdentity(rule), display.vendorModelSerialIdentity, 80),
            (DisplaySnapshot.normalizedIdentity(rule.ioLocation), DisplaySnapshot.normalizedIdentity(display.ioLocation), 60),
            (DisplaySnapshot.normalizedIdentity(rule.displayName), DisplaySnapshot.normalizedIdentity(display.displayName), 20)
        ]
        for (expected, actual, score) in candidates where expected != nil {
            return (expected == actual, expected == actual ? score : 0)
        }
        return (false, 0)
    }

    private func weightedMatchScore(display: DisplaySnapshot, rule: DisplayMatchRule) -> Int {
        var score = 0
        if matchesConfigured(rule.edidUUID, display.edidUUID) { score += 100 }
        if matchesConfigured(rule.alphanumericSerial, display.alphanumericSerial) { score += 90 }
        if let expected = vendorModelSerialIdentity(rule), expected == display.vendorModelSerialIdentity { score += 80 }
        if matchesConfigured(rule.ioLocation, display.ioLocation) { score += 60 }
        if matchesConfigured(rule.displayName, display.displayName) { score += 20 }
        return min(100, score)
    }

    private func matchesConfigured(_ expected: String, _ actual: String) -> Bool {
        guard let expected = DisplaySnapshot.normalizedIdentity(expected) else { return false }
        return expected == DisplaySnapshot.normalizedIdentity(actual)
    }

    private func vendorModelSerialIdentity(_ rule: DisplayMatchRule) -> String? {
        guard let vendor = DisplaySnapshot.normalizedIdentity(rule.vendorId),
              let model = DisplaySnapshot.normalizedIdentity(rule.modelId),
              let serial = DisplaySnapshot.normalizedIdentity(rule.serialNumber) else { return nil }
        return "\(vendor)|\(model)|\(serial)"
    }

    private static func snapshot(_ info: DCLDisplayInfo) -> DisplaySnapshot {
        DisplaySnapshot(
            runtimeDisplayID: info.runtimeDisplayID,
            displayName: normalizedName(name: string(info.displayName), isBuiltIn: info.isBuiltIn),
            edidUUID: string(info.edidUUID),
            vendorId: String(format: "0x%04x", info.vendorID),
            modelId: String(format: "0x%04x", info.modelID),
            serialNumber: String(info.serialNumber),
            manufacturer: string(info.manufacturer),
            alphanumericSerial: string(info.alphanumericSerial),
            isBuiltIn: info.isBuiltIn,
            isActive: info.isActive,
            ioLocation: string(info.ioLocation)
        )
    }

    private func activeDisplaySnapshots() -> [DisplaySnapshot] {
        var displayIDs = Array(repeating: CGDirectDisplayID(), count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &count) == .success else {
            return []
        }

        return displayIDs.prefix(Int(count)).map { displayID in
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            return DisplaySnapshot(
                runtimeDisplayID: displayID,
                displayName: Self.normalizedName(name: "", isBuiltIn: isBuiltIn),
                edidUUID: "",
                vendorId: String(format: "0x%04x", CGDisplayVendorNumber(displayID)),
                modelId: String(format: "0x%04x", CGDisplayModelNumber(displayID)),
                serialNumber: String(CGDisplaySerialNumber(displayID)),
                manufacturer: "",
                alphanumericSerial: "",
                isBuiltIn: isBuiltIn,
                isActive: CGDisplayIsActive(displayID) != 0,
                ioLocation: ""
            )
        }
    }

    private func sameDisplay(_ lhs: DisplaySnapshot, _ rhs: DisplaySnapshot) -> Bool {
        lhs.hasSameStableIdentity(as: rhs)
    }

    private static func normalizedName(name: String, isBuiltIn: Bool) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return isBuiltIn ? "内置显示屏" : "外接显示器"
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: CChar.self).baseAddress else {
                return ""
            }
            return String(cString: baseAddress)
        }
    }
}
