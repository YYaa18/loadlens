import Foundation
import Darwin

struct MemoryStats {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
}

struct ProcessSample {
    let pid: pid_t
    let name: String
    let path: String
    let cpu: Double
    let rss: UInt64
    /// Bytes per second; only filled when disk I/O is sampled.
    var diskRead: Double = 0
    var diskWrite: Double = 0
}

/// Overall CPU load, derived from host_processor_info tick deltas.
final class CPUSampler {
    private var previous: [UInt32]?
    private(set) var lastValue: Double = 0

    func sample() -> Double {
        var cpuCount: natural_t = 0
        var infoPointer: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &infoPointer, &infoCount) == KERN_SUCCESS,
              let info = infoPointer else {
            return lastValue
        }
        let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size) }

        var user: UInt32 = 0
        var system: UInt32 = 0
        var idle: UInt32 = 0
        var nice: UInt32 = 0
        let states = Int(CPU_STATE_MAX)
        for i in 0..<Int(cpuCount) {
            let base = i * states
            user &+= UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            system &+= UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            idle &+= UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            nice &+= UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
        }

        let current = [user, system, idle, nice]
        defer { previous = current }
        guard let prev = previous else { return lastValue }

        let userDelta = Double(current[0] &- prev[0])
        let systemDelta = Double(current[1] &- prev[1])
        let idleDelta = Double(current[2] &- prev[2])
        let niceDelta = Double(current[3] &- prev[3])
        let total = userDelta + systemDelta + idleDelta + niceDelta
        guard total > 0 else { return lastValue }

        lastValue = (userDelta + systemDelta + niceDelta) / total * 100.0
        return lastValue
    }
}

func readMemoryStats() -> MemoryStats {
    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)

    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result: kern_return_t = withUnsafeMutablePointer(to: &stats) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
        }
    }

    var memory = MemoryStats()
    memory.totalBytes = ProcessInfo.processInfo.physicalMemory
    if result == KERN_SUCCESS {
        let pages = UInt64(pageSize)
        let active = UInt64(stats.active_count) * pages
        let wired = UInt64(stats.wire_count) * pages
        let compressed = UInt64(stats.compressor_page_count) * pages
        memory.compressedBytes = compressed
        memory.usedBytes = active &+ wired &+ compressed
    }

    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 {
        memory.swapUsedBytes = usage.xsu_used
        memory.swapTotalBytes = usage.xsu_total
    }
    return memory
}

func readLoadAverage() -> (Double, Double, Double) {
    var loads = [Double](repeating: 0, count: 3)
    guard getloadavg(&loads, 3) == 3 else { return (0, 0, 0) }
    return (loads[0], loads[1], loads[2])
}

func readThermalState() -> ProcessInfo.ThermalState {
    ProcessInfo.processInfo.thermalState
}

func readSystemUptime() -> TimeInterval {
    var bootTime = timeval()
    var size = MemoryLayout<timeval>.size
    if sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 {
        return Date().timeIntervalSince1970 - TimeInterval(bootTime.tv_sec)
    }
    return ProcessInfo.processInfo.systemUptime
}

/// Per-process CPU, derived from PROC_PIDTASKINFO delta. Process name/path is cached.
final class ProcessTracker {
    private struct Meta {
        let name: String
        let path: String
    }

    private var metaCache: [pid_t: Meta] = [:]
    private var previousTimes: [pid_t: UInt64] = [:]
    private var previousIO: [pid_t: (read: UInt64, write: UInt64)] = [:]
    private var previousIODate: Date?
    private var previousDate: Date?

    /// - Parameter includeDisk: also read per-process disk I/O (one extra syscall per process).
    func scan(includeDisk: Bool = false) -> [ProcessSample] {
        let now = Date()
        let elapsed = previousDate.map { max(now.timeIntervalSince($0), 0.05) }
        let pids = Self.allPIDs()
        var currentTimes = [pid_t: UInt64](minimumCapacity: pids.count)
        var currentIO = [pid_t: (read: UInt64, write: UInt64)]()
        let ioElapsed = previousIODate.map { max(now.timeIntervalSince($0), 0.05) }
        var samples = [ProcessSample]()
        samples.reserveCapacity(pids.count)

        for pid in pids {
            var info = proc_taskinfo()
            let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, taskInfoSize) == taskInfoSize else {
                continue
            }

            let meta: Meta
            if let cached = metaCache[pid] {
                meta = cached
            } else {
                let name = Self.processName(pid)
                let path = Self.processPath(pid)
                meta = Meta(name: name.isEmpty ? (path as NSString).lastPathComponent : name, path: path)
                metaCache[pid] = meta
            }

            let totalTime = info.pti_total_user &+ info.pti_total_system
            currentTimes[pid] = totalTime

            var cpu: Double = 0
            if let elapsed, let previous = previousTimes[pid] {
                cpu = Double(totalTime &- previous) / 1_000_000_000.0 / elapsed * 100.0
            }

            var sample = ProcessSample(pid: pid,
                                       name: meta.name,
                                       path: meta.path,
                                       cpu: max(0, min(cpu, 1600)),
                                       rss: info.pti_resident_size)
            if includeDisk, let io = readProcessDiskIO(pid) {
                currentIO[pid] = io
                if let ioElapsed, let previous = previousIO[pid] {
                    sample.diskRead = io.read >= previous.read ? Double(io.read - previous.read) / ioElapsed : 0
                    sample.diskWrite = io.write >= previous.write ? Double(io.write - previous.write) / ioElapsed : 0
                }
            }
            samples.append(sample)
        }

        previousTimes = currentTimes
        previousDate = now
        if includeDisk {
            previousIO = currentIO
            previousIODate = now
        } else {
            previousIO = [:]
            previousIODate = nil
        }

        if metaCache.count > max(pids.count * 2, 2048) {
            let alive = Set(pids)
            metaCache = metaCache.filter { alive.contains($0.key) }
        }
        return samples
    }

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let written = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written)))
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBytes { raw in
            proc_name(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    private static func processPath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }
}
