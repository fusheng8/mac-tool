import Darwin
import Foundation

struct SystemInfoSnapshot {
    let generatedAt: Date
    let computerName: String
    let hostName: String
    let modelIdentifier: String
    let cpuBrand: String
    let architecture: String
    let processorCount: Int
    let activeProcessorCount: Int
    let operatingSystem: String
    let kernelVersion: String
    let uptimeSeconds: TimeInterval
    let physicalMemoryBytes: UInt64
    let loadAverage: [Double]
    let memory: SystemMemorySnapshot?
    let disk: SystemDiskSnapshot?
    let processorTicks: SystemProcessorTicks?
}

struct SystemMemorySnapshot {
    let pageSize: UInt64
    let freeBytes: UInt64
    let activeBytes: UInt64
    let inactiveBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64

    var usedBytes: UInt64 {
        activeBytes + wiredBytes + compressedBytes
    }
}

struct SystemDiskSnapshot {
    let mountPath: String
    let totalBytes: UInt64
    let freeBytes: UInt64

    var usedBytes: UInt64 {
        totalBytes > freeBytes ? totalBytes - freeBytes : 0
    }
}

struct SystemProcessorTicks {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    var total: UInt64 {
        user + system + idle + nice
    }
}

enum SystemInfoProvider {
    static func snapshot() -> SystemInfoSnapshot {
        let processInfo = ProcessInfo.processInfo
        return SystemInfoSnapshot(
            generatedAt: Date(),
            computerName: Host.current().localizedName ?? "--",
            hostName: Host.current().name ?? "--",
            modelIdentifier: sysctlString("hw.model") ?? "--",
            cpuBrand: sysctlString("machdep.cpu.brand_string") ?? appleSiliconDescription(),
            architecture: architectureName(),
            processorCount: processInfo.processorCount,
            activeProcessorCount: processInfo.activeProcessorCount,
            operatingSystem: processInfo.operatingSystemVersionString,
            kernelVersion: sysctlString("kern.version") ?? "--",
            uptimeSeconds: processInfo.systemUptime,
            physicalMemoryBytes: processInfo.physicalMemory,
            loadAverage: loadAverage(),
            memory: memorySnapshot(),
            disk: diskSnapshot(),
            processorTicks: processorTicks()
        )
    }

    static func cpuUsagePercent(previous: SystemProcessorTicks?, current: SystemProcessorTicks?) -> Double? {
        guard let previous, let current else {
            return nil
        }
        let totalDelta = current.total > previous.total ? current.total - previous.total : 0
        let idleDelta = current.idle > previous.idle ? current.idle - previous.idle : 0
        guard totalDelta > 0, idleDelta <= totalDelta else {
            return nil
        }
        return min(100, max(0, Double(totalDelta - idleDelta) / Double(totalDelta) * 100))
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func appleSiliconDescription() -> String {
        if sysctlInt("hw.optional.arm64") == 1 {
            return "Apple Silicon"
        }
        return "--"
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }

    private static func architectureName() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private static func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        let count = getloadavg(&values, Int32(values.count))
        guard count > 0 else {
            return []
        }
        return Array(values.prefix(Int(count)))
    }

    private static func memorySnapshot() -> SystemMemorySnapshot? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }

        let pageSize = UInt64(vm_kernel_page_size)
        return SystemMemorySnapshot(
            pageSize: pageSize,
            freeBytes: UInt64(stats.free_count) * pageSize,
            activeBytes: UInt64(stats.active_count) * pageSize,
            inactiveBytes: UInt64(stats.inactive_count) * pageSize,
            wiredBytes: UInt64(stats.wire_count) * pageSize,
            compressedBytes: UInt64(stats.compressor_page_count) * pageSize
        )
    }

    private static func processorTicks() -> SystemProcessorTicks? {
        var cpuInfo: processor_info_array_t?
        var cpuCount: natural_t = 0
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &infoCount
        )
        guard result == KERN_SUCCESS, let cpuInfo else {
            return nil
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: cpuInfo)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0

        for index in 0..<Int(cpuCount) {
            let offset = index * Int(CPU_STATE_MAX)
            user += UInt64(cpuInfo[offset + Int(CPU_STATE_USER)])
            system += UInt64(cpuInfo[offset + Int(CPU_STATE_SYSTEM)])
            idle += UInt64(cpuInfo[offset + Int(CPU_STATE_IDLE)])
            nice += UInt64(cpuInfo[offset + Int(CPU_STATE_NICE)])
        }

        return SystemProcessorTicks(user: user, system: system, idle: idle, nice: nice)
    }

    private static func diskSnapshot() -> SystemDiskSnapshot? {
        do {
            let url = URL(fileURLWithPath: "/", isDirectory: true)
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
            guard let total = attributes[.systemSize] as? NSNumber,
                  let free = attributes[.systemFreeSize] as? NSNumber else {
                return nil
            }
            return SystemDiskSnapshot(
                mountPath: url.path,
                totalBytes: total.uint64Value,
                freeBytes: free.uint64Value
            )
        } catch {
            return nil
        }
    }
}
