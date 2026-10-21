import Foundation

struct AppUsage: Identifiable {
    let id: String
    let name: String
    let cpu: Double
    let rss: UInt64
    let processCount: Int
    let busiestProcess: String
    let bundlePath: String?
    let isSystem: Bool

    var hint: String? {
        let lowered = busiestProcess.lowercased()
        if lowered.contains("render") { return "网页/界面内容" }
        if lowered.contains("gpu") { return "图形渲染" }
        if lowered.contains("mtlcompiler") { return "显卡着色器" }
        if busiestProcess == "backupd" { return "时间机器备份" }
        return nil
    }

    var subtitle: String {
        var parts: [String] = []
        if let hint { parts.append(hint) }
        if processCount > 1 { parts.append("\(processCount) 个进程") }
        if rss >= 80 * 1_048_576 { parts.append(formatBytes(rss)) }
        return parts.joined(separator: " · ")
    }
}

struct Snapshot {
    var cpu: Double = 0
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    var cores: Int = ProcessInfo.processInfo.processorCount
    var memory = MemoryStats()
    var thermal: ProcessInfo.ThermalState = .nominal
    var uptime: TimeInterval = 0
    var apps: [AppUsage] = []
    var sampledAt = Date()
}

struct CPUPoint {
    let date: Date
    let cpu: Double
}

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(bytes) / 1_048_576)
}

func formatGB(_ bytes: UInt64) -> String {
    String(format: "%.1f", Double(bytes) / 1_073_741_824)
}

private let friendlySystemNames: [String: String] = [
    "kernel_task": "系统内核（降温/调度）",
    "WindowServer": "窗口合成（系统）",
    "MTLCompilerService": "显卡着色器编译",
    "mds": "Spotlight 文件索引",
    "mds_stores": "Spotlight 文件索引",
    "mdworker": "Spotlight 文件索引",
    "mdworker_shared": "Spotlight 文件索引",
    "backupd": "Time Machine 备份",
    "coreaudiod": "音频服务",
    "diagnosticd": "系统诊断",
    "spindump": "系统诊断",
    "sysmond": "系统监控",
    "nehelper": "网络助手",
    "locationd": "定位服务",
    "opendirectoryd": "账户服务",
    "launchd": "系统启动服务",
    "loginwindow": "登录窗口",
    "powerd": "电源管理",
    "corebrightnessd": "亮度管理",
    "bluetoothd": "蓝牙服务",
    "airportd": "Wi-Fi 服务",
    "sharingd": "共享服务",
    "cloudd": "iCloud 同步",
    "bird": "iCloud 同步",
    "nsurlsessiond": "后台下载",
    "com.apple.WebKit.WebContent": "Safari 网页",
    "com.apple.WebKit.GPU": "Safari 图形",
    "com.apple.WebKit.Networking": "Safari 网络",
    "com.apple.WebKit.WebContent.Development": "Safari 网页",
    "siriknowledged": "Siri 建议服务",
    "siriactionsd": "Siri 服务",
    "assistantd": "Siri 服务",
    "duetexpertd": "Siri 建议服务",
    "corespeechd": "Siri 语音服务",
    "系统进程": "系统进程"
]

private let knownSystemNames: Set<String> = Set(friendlySystemNames.keys)

func appBundlePath(from executablePath: String) -> String? {
    guard !executablePath.isEmpty else { return nil }
    let components = executablePath.split(separator: "/", omittingEmptySubsequences: false)
    guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
    return components[0...index].joined(separator: "/")
}

func aggregate(_ samples: [ProcessSample], excluding: Set<pid_t>) -> [AppUsage] {
    struct Bucket {
        let name: String
        var cpu: Double = 0
        var rss: UInt64 = 0
        var count: Int = 0
        var busiestProcess: String
        var busiestCPU: Double = 0
        var bundlePath: String?
        var isSystem: Bool
    }

    var buckets: [String: Bucket] = [:]
    for sample in samples where !excluding.contains(sample.pid) {
        let bundle = appBundlePath(from: sample.path)
        let key: String
        let name: String
        let isSystem: Bool

        if let bundle {
            name = (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            key = "app:" + name
            isSystem = false
        } else if let friendly = friendlySystemNames[sample.name] {
            name = friendly
            key = "sys:" + friendly
            isSystem = true
        } else if sample.name.hasPrefix("zcode") {
            name = "ZCode"
            key = "app:ZCode"
            isSystem = false
        } else {
            name = sample.name
            key = "proc:" + sample.name
            isSystem = knownSystemNames.contains(sample.name)
        }

        var bucket = buckets[key] ?? Bucket(name: name,
                                            busiestProcess: sample.name,
                                            bundlePath: bundle,
                                            isSystem: isSystem)
        bucket.cpu += sample.cpu
        bucket.rss += sample.rss
        bucket.count += 1
        if sample.cpu > bucket.busiestCPU {
            bucket.busiestCPU = sample.cpu
            bucket.busiestProcess = sample.name
        }
        if bucket.bundlePath == nil { bucket.bundlePath = bundle }
        buckets[key] = bucket
    }

    return buckets.map { key, bucket in
        AppUsage(id: key,
                 name: bucket.name,
                 cpu: bucket.cpu,
                 rss: bucket.rss,
                 processCount: bucket.count,
                 busiestProcess: bucket.busiestProcess,
                 bundlePath: bucket.bundlePath,
                 isSystem: bucket.isSystem)
    }
    .sorted { $0.cpu > $1.cpu }
}

/// Reads processes owned by other users via ps.
/// Asking ps for names is expensive, so names are cached and refreshed far less often than CPU.
final class SystemProcessReader {
    private var cache: [pid_t: (name: String, path: String)] = [:]

    func sample(includeNames: Bool) -> [ProcessSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = includeNames
            ? ["-axo", "pid=,pcpu=,rss=,comm="]
            : ["-axo", "pid=,pcpu=,rss="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [ProcessSample] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ",
                                      maxSplits: includeNames ? 3 : 2,
                                      omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let pid = pid_t(parts[0]),
                  let cpu = Double(parts[1]),
                  let rssKB = UInt64(parts[2]) else { continue }

            let name: String
            let path: String
            if includeNames, parts.count == 4 {
                let rawPath = String(parts[3])
                name = (rawPath as NSString).lastPathComponent
                path = rawPath
                cache[pid] = (name, path)
            } else if let cached = cache[pid] {
                name = cached.name
                path = cached.path
            } else {
                name = "系统进程"
                path = ""
            }

            result.append(ProcessSample(pid: pid, name: name, path: path, cpu: cpu, rss: rssKB * 1024))
        }

        if cache.count > 4_000 {
            let alive = Set(result.map(\.pid))
            cache = cache.filter { alive.contains($0.key) }
        }
        return result
    }
}

/// One-shot full read (names included), used by the terminal report.
func readSystemProcesses() -> [ProcessSample] {
    SystemProcessReader().sample(includeNames: true)
}

func mergeSamples(primary: [ProcessSample], secondary: [ProcessSample]) -> [ProcessSample] {
    let seen = Set(primary.map(\.pid))
    var merged = primary
    for sample in secondary where !seen.contains(sample.pid) {
        merged.append(sample)
    }
    return merged
}
