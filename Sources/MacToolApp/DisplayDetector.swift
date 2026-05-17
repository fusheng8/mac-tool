import DDCBackend
import CoreGraphics
import Foundation

final class DisplayDetector {
    func onlineDisplays() -> [DisplaySnapshot] {
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
        onlineDisplays()
            .map { display in (display, matchScore(display: display, profile: profile)) }
            .filter { $0.1.matches }
            .sorted { $0.1.score > $1.1.score }
            .first?
            .0
    }

    func matchScore(display: DisplaySnapshot, profile: DisplayProfile) -> (matches: Bool, score: Int) {
        if matchesConfigured(profile.match.edidUUID, display.edidUUID) {
            return (true, 500)
        }
        if matchesConfigured(profile.match.alphanumericSerial, display.alphanumericSerial) {
            return (true, 400)
        }
        if matchesVendorModelSerial(display: display, rule: profile.match) {
            return (true, 300)
        }
        if matchesConfigured(profile.match.ioLocation, display.ioLocation) {
            return (true, 200)
        }
        if matchesConfigured(profile.match.displayName, display.displayName) {
            return (true, 100)
        }
        return (false, 0)
    }

    private func matchesConfigured(_ expected: String, _ actual: String) -> Bool {
        let normalizedExpected = normalizedIdentityValue(expected)
        return !normalizedExpected.isEmpty && normalizedExpected == normalizedIdentityValue(actual)
    }

    private func matchesVendorModelSerial(display: DisplaySnapshot, rule: DisplayMatchRule) -> Bool {
        let vendor = normalizedIdentityValue(rule.vendorId)
        let model = normalizedIdentityValue(rule.modelId)
        let serial = normalizedIdentityValue(rule.serialNumber)
        return !vendor.isEmpty
            && !model.isEmpty
            && !serial.isEmpty
            && vendor == normalizedIdentityValue(display.vendorId)
            && model == normalizedIdentityValue(display.modelId)
            && serial == normalizedIdentityValue(display.serialNumber)
    }

    private func normalizedIdentityValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
