import Foundation
import IOKit

// MARK: - Models

struct VolumeInfo: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String
    let totalBytes: UInt64
    /// Free space right now.
    let freeBytes: UInt64
    /// Free space once the system purges caches, snapshots, etc. (what Finder shows as "available").
    let availableBytes: UInt64
    let isRoot: Bool
    let isInternal: Bool
    let isEjectable: Bool
    let fileSystem: String

    var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
    var purgeableBytes: UInt64 { availableBytes > freeBytes ? availableBytes - freeBytes : 0 }
    var usedRatio: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    var freeRatio: Double { 1 - usedRatio }
}

struct DiskHealth: Equatable {
    /// "Verified", "Failing", "Not Supported", …
    let smartStatus: String
    let solidState: Bool
    let localSnapshots: Int

    var isFailing: Bool { smartStatus.lowercased().contains("fail") }
    var label: String {
        switch smartStatus.lowercased() {
        case "verified": return "正常"
        case let s where s.contains("fail"): return "异常"
        default: return "不支持检测"
        }
    }
}

struct DiskSnapshot {
    var volumes: [VolumeInfo] = []
    var readRate: Double = 0    // bytes per second, whole machine
    var writeRate: Double = 0
    var health: DiskHealth?

    var root: VolumeInfo? { volumes.first(where: \.isRoot) }
}

struct DiskPoint {
    let date: Date
    let read: Double
    let write: Double
}

func formatRate(_ bytesPerSecond: Double) -> String {
    let mb = bytesPerSecond / 1_048_576
    if mb >= 100 { return String(format: "%.0f MB/s", mb) }
    if mb >= 1 { return String(format: "%.1f MB/s", mb) }
    let kb = bytesPerSecond / 1024
    if kb >= 1 { return String(format: "%.0f KB/s", kb) }
    return "0 KB/s"
}

func formatSize(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_000_000_000
    if gb >= 100 { return String(format: "%.0f GB", gb) }
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    let mb = Double(bytes) / 1_000_000
    if mb >= 1 { return String(format: "%.0f MB", mb) }
    return String(format: "%.0f KB", Double(bytes) / 1000)
}

// MARK: - Volumes

/// Mounted, user-visible volumes. Uses decimal GB like Finder.
func readVolumes() -> [VolumeInfo] {
    let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
        .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsRootFileSystemKey,
        .volumeLocalizedFormatDescriptionKey, .volumeIsBrowsableKey
    ]
    guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                           options: [.skipHiddenVolumes]) else { return [] }
    var result: [VolumeInfo] = []
    for url in urls {
        guard let values = try? url.resourceValues(forKeys: Set(keys)),
              values.volumeIsBrowsable != false,
              let total = values.volumeTotalCapacity, total > 0 else { continue }
        let free = UInt64(max(values.volumeAvailableCapacity ?? 0, 0))
        let important = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) } ?? free
        let isRoot = values.volumeIsRootFileSystem ?? (url.path == "/")
        result.append(VolumeInfo(name: values.volumeName ?? url.lastPathComponent,
                                 path: url.path,
                                 totalBytes: UInt64(total),
                                 freeBytes: free,
                                 availableBytes: max(important, free),
                                 isRoot: isRoot,
                                 isInternal: values.volumeIsInternal ?? isRoot,
                                 isEjectable: (values.volumeIsEjectable ?? false) || (values.volumeIsRemovable ?? false),
                                 fileSystem: values.volumeLocalizedFormatDescription ?? ""))
    }
    return result.sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
}

// MARK: - Throughput

/// Machine-wide bytes read/written, from the block storage drivers' statistics (no permissions needed).
final class DiskIOSampler {
    private var previous: (read: UInt64, write: UInt64, date: Date)?

    func sample() -> (read: Double, write: Double) {
        let totals = Self.readTotals()
        let now = Date()
        defer { previous = (totals.read, totals.write, now) }
        guard let previous else { return (0, 0) }
        let elapsed = max(now.timeIntervalSince(previous.date), 0.1)
        let read = totals.read >= previous.read ? Double(totals.read - previous.read) / elapsed : 0
        let write = totals.write >= previous.write ? Double(totals.write - previous.write) / elapsed : 0
        return (read, write)
    }

    private static func readTotals() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var write: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, write)
    }
}

// MARK: - Health

/// SMART status of the startup disk and the number of local Time Machine snapshots.
/// Both come from command-line tools, so they are read rarely.
func readDiskHealth() -> DiskHealth? {
    guard let data = runTool("/usr/sbin/diskutil", ["info", "-plist", "/"]),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        return nil
    }
    let smart = plist["SMARTStatus"] as? String ?? "Not Supported"
    let solid = plist["SolidState"] as? Bool ?? false

    var snapshots = 0
    if let output = runTool("/usr/bin/tmutil", ["listlocalsnapshots", "/"]),
       let text = String(data: output, encoding: .utf8) {
        snapshots = text.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
    }
    return DiskHealth(smartStatus: smart, solidState: solid, localSnapshots: snapshots)
}

private func runTool(_ path: String, _ arguments: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
}

// MARK: - Per-process disk I/O

/// Cumulative bytes a process has read/written, via proc_pid_rusage (works for the user's own processes).
func readProcessDiskIO(_ pid: pid_t) -> (read: UInt64, write: UInt64)? {
    var info = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
        }
    }
    guard result == 0 else { return nil }
    return (info.ri_diskio_bytesread, info.ri_diskio_byteswritten)
}

// MARK: - Text summaries

/// Lines describing disk state, shared by the AI context, the copied report and the terminal report.
func diskContextLines(_ disk: DiskSnapshot, apps: [AppUsage]) -> [String] {
    var lines: [String] = []
    if let root = disk.root {
        lines.append("启动盘「\(root.name)」：共 \(formatSize(root.totalBytes))，可用 \(formatSize(root.availableBytes))（其中可被系统自动清除约 \(formatSize(root.purgeableBytes))），已用 \(Int((root.usedRatio * 100).rounded()))%")
    }
    for volume in disk.volumes where !volume.isRoot {
        lines.append("其他磁盘「\(volume.name)」：共 \(formatSize(volume.totalBytes))，可用 \(formatSize(volume.availableBytes))")
    }
    if let health = disk.health {
        var text = "硬盘健康（SMART）：\(health.label)；\(health.solidState ? "固态硬盘" : "机械硬盘")"
        if health.localSnapshots > 0 { text += "；本地 Time Machine 快照 \(health.localSnapshots) 个" }
        lines.append(text)
    }
    lines.append("整机硬盘读写：读 \(formatRate(disk.readRate))，写 \(formatRate(disk.writeRate))")
    let busy = apps.filter { $0.diskTotal >= 512 * 1024 }.sorted { $0.diskTotal > $1.diskTotal }.prefix(3)
    if !busy.isEmpty {
        lines.append("读写最多的应用：" + busy.map { "\($0.name)（读 \(formatRate($0.diskRead))，写 \(formatRate($0.diskWrite))）" }
            .joined(separator: "、"))
    }
    return lines
}
