import DDCBackend
import Foundation

enum DDCError: LocalizedError {
    case invalidVCPCode(String)
    case invalidTargetValue(Int)
    case noEDID(DisplaySnapshot)
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .invalidVCPCode(let code):
            return "VCP 代码无效：\(code)"
        case .invalidTargetValue(let value):
            return "DDC 目标值无效：\(value)"
        case .noEDID(let display):
            return "显示器没有 EDID UUID：\(display.displayName)"
        case .backend(let message):
            return message
        }
    }
}

final class DDCController {
    func probe(display: DisplaySnapshot) throws -> Int {
        try readVCP(display: display, code: "0x10")
    }

    func readVCP(display: DisplaySnapshot, code: String) throws -> Int {
        guard let parsedCode = VCPCodeParser.parse(code) else {
            throw DDCError.invalidVCPCode(code)
        }
        guard !display.edidUUID.isEmpty else {
            throw DDCError.noEDID(display)
        }
        let result = display.edidUUID.withCString { pointer in
            DCLReadVCPByEDID(pointer, parsedCode)
        }
        guard result.status == DCLStatusOK else {
            throw DDCError.backend(statusDescription(result.status))
        }
        return Int(result.currentValue)
    }

    func writeVCP(display: DisplaySnapshot, code: String, value: Int) throws {
        guard let parsedCode = VCPCodeParser.parse(code) else {
            throw DDCError.invalidVCPCode(code)
        }
        guard (0...255).contains(value) else {
            throw DDCError.invalidTargetValue(value)
        }
        guard !display.edidUUID.isEmpty else {
            throw DDCError.noEDID(display)
        }
        let status = display.edidUUID.withCString { pointer in
            DCLWriteVCPByEDID(pointer, parsedCode, UInt8(value))
        }
        guard status == DCLStatusOK else {
            throw DDCError.backend(statusDescription(status))
        }
    }

    private func statusDescription(_ status: DCLStatus) -> String {
        guard let pointer = DCLStatusDescription(status) else {
            return "未知 DDC 错误"
        }
        return String(cString: pointer)
    }
}
