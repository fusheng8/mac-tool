import DDCBackend
import CoreGraphics
import Foundation

final class DisplayDetector {
    private let displayProvider: (() -> [DisplaySnapshot])?
    private let safetyDisplayProvider: (() -> [DisplaySnapshot])?

    init(
        displayProvider: (() -> [DisplaySnapshot])? = nil,
        safetyDisplayProvider: (() -> [DisplaySnapshot])? = nil
    ) {
        self.displayProvider = displayProvider
        self.safetyDisplayProvider = safetyDisplayProvider
    }

    func onlineDisplays() -> [DisplaySnapshot] {
        if let displayProvider {
            return displayProvider()
        }
        return systemDisplays(includeUnmatchedActiveAliases: true)
    }

    /// Returns only active aliases that can be reconciled to a currently online
    /// physical display. WindowServer may briefly keep a removed display in the
    /// active list after hot-unplug; such an orphan must not block black-screen
    /// recovery.
    func safetyDisplays() -> [DisplaySnapshot] {
        if let safetyDisplayProvider {
            return safetyDisplayProvider()
        }
        if let displayProvider {
            return displayProvider()
        }
        return systemDisplays(includeUnmatchedActiveAliases: false)
    }

    private func systemDisplays(includeUnmatchedActiveAliases: Bool) -> [DisplaySnapshot] {
        var buffer = Array(repeating: DCLDisplayInfo(), count: Int(DCL_MAX_DISPLAYS))
        let count = DCLCopyOnlineDisplays(&buffer, Int32(buffer.count))
        let displays = count > 0 ? buffer.prefix(Int(count)).map(Self.snapshot) : []

        return Self.reconciledDisplays(
            online: displays,
            active: activeDisplaySnapshots(),
            includeUnmatchedActiveAliases: includeUnmatchedActiveAliases
        )
            .filter { !$0.isVirtualPlaceholder }
            .sorted { lhs, rhs in
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

    static func reconciledDisplays(
        online: [DisplaySnapshot],
        active: [DisplaySnapshot],
        includeUnmatchedActiveAliases: Bool = true
    ) -> [DisplaySnapshot] {
        var displays = online
        for activeDisplay in active {
            if let index = matchingOnlineDisplayIndex(for: activeDisplay, in: displays) {
                // WindowServer can expose a drawable alias with a different
                // runtime ID after a hot-plug or mirroring transition. Keep the
                // physical online display (it carries the stable identity used
                // by profiles), but take the active state from the alias.
                displays[index].isActive = true
            } else if includeUnmatchedActiveAliases {
                displays.append(activeDisplay)
            }
        }
        return displays
    }

    private static func matchingOnlineDisplayIndex(
        for activeDisplay: DisplaySnapshot,
        in displays: [DisplaySnapshot]
    ) -> Int? {
        if let exact = displays.firstIndex(where: {
            $0.runtimeDisplayID != 0 && $0.runtimeDisplayID == activeDisplay.runtimeDisplayID
        }) {
            return exact
        }

        let stableMatches = displays.indices.filter {
            displays[$0].hasSameStableIdentity(as: activeDisplay)
        }
        if stableMatches.count == 1 {
            return stableMatches[0]
        }

        // Active-list aliases often omit EDID, serial number and I/O location.
        // Vendor + model + built-in type is safe only when it identifies one
        // online display unambiguously.
        guard let activeVendor = DisplaySnapshot.normalizedIdentity(activeDisplay.vendorId),
              let activeModel = DisplaySnapshot.normalizedIdentity(activeDisplay.modelId) else {
            return nil
        }
        let hardwareMatches = displays.indices.filter { index in
            let candidate = displays[index]
            return candidate.isBuiltIn == activeDisplay.isBuiltIn
                && DisplaySnapshot.normalizedIdentity(candidate.vendorId) == activeVendor
                && DisplaySnapshot.normalizedIdentity(candidate.modelId) == activeModel
        }
        return hardwareMatches.count == 1 ? hardwareMatches[0] : nil
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
