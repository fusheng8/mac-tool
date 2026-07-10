import DDCBackend
import Foundation

protocol DisplayBackend: Sendable {
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    func setDisplayEnabled(_ displayID: UInt32, enabled: Bool) throws
}

struct DCLDisplayBackend: DisplayBackend {
    let isAvailable = true
    let unavailableReason: String? = nil

    func setDisplayEnabled(_ displayID: UInt32, enabled: Bool) throws {
        let status = DCLSetDisplayEnabled(displayID, enabled)
        guard status == DCLStatusOK else {
            throw SoftDisconnectError.backendFailed(String(cString: DCLStatusDescription(status)))
        }
    }
}

struct UnavailableDisplayBackend: DisplayBackend {
    let reason: String
    var isAvailable: Bool { false }
    var unavailableReason: String? { reason }

    func setDisplayEnabled(_ displayID: UInt32, enabled: Bool) throws {
        throw SoftDisconnectError.backendUnavailable(reason)
    }
}
