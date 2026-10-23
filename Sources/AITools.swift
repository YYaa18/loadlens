import Foundation
import AppKit

/// A function the model may call. Every tool is read-only: it looks things up, never changes the system.
struct ToolSpec {
    let name: String
    let description: String
    /// JSON Schema for the arguments.
    let parameters: [String: Any]
}

/// The data-lookup tools offered to the AI, and their implementations.
enum AITools {
    static let specs: [ToolSpec] = [
        ToolSpec(name: "list_apps",
                 description: "列出当前占用资源的应用（同一应用的多个进程已合并），可按 CPU、内存或磁盘读写排序。用于回答“谁最占内存/CPU/硬盘”“某类应用占了多少”等问题。",
                 parameters: [
                    "type": "object",
                    "properties": [
                        "sort_by": ["type": "string", "enum": ["cpu", "memory", "disk"], "description": "排序依据，默认 cpu"],
                        "limit": ["type": "integer", "description": "返回条数，默认 15，最多 40"]
                    ],
                    "additionalProperties": false
                 ]),
        ToolSpec(name: "get_app_processes",
                 description: "查看某个应用下面的每一个进程（名称、PID、CPU、内存、磁盘读写）。用于分析某个应用为什么占用高、是哪个子进程。",
                 parameters: [
                    "type": "object",
                    "properties": [
                        "app_name": ["type": "string", "description": "应用名，与 list_apps 返回的 name 一致，例如 Google Chrome"]
                    ],
                    "required": ["app_name"],
                    "additionalProperties": false
                 ]),
        ToolSpec(name: "get_memory_details",
                 description: "内存详情：总量、已用、压缩内存、交换区，以及占内存最多的应用。",
                 parameters: ["type": "object", "properties": [:], "additionalProperties": false]),
        ToolSpec(name: "get_disk_details",
                 description: "硬盘详情：所有磁盘的容量与可用空间、可自动清除空间、SMART 健康、本地 Time Machine 快照、当前读写速度和读写最多的应用。",
                 parameters: ["type": "object", "properties": [:], "additionalProperties": false]),
        ToolSpec(name: "get_space_overview",
                 description: "可清理空间总览：下载、废纸篓、应用缓存、日志、Xcode、iOS 模拟器、开发工具缓存、iPhone 备份各占多少。没分析过时会自动分析（可能需要几十秒）。",
                 parameters: ["type": "object", "properties": [:], "additionalProperties": false]),
        ToolSpec(name: "analyze_folder",
                 description: "查看某个目录里每个子文件夹/文件占多少空间，并识别属于哪个应用、该应用是否还安装、是否正在运行、最近修改时间。用于分析“应用缓存里都是哪些应用”“下载里哪些大”等。target 用于常见位置；也可以用 path 指定家目录或 /Applications 下的其他目录。",
                 parameters: [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string",
                                   "enum": ["caches", "downloads", "logs", "xcode", "simulators", "devcache", "backups", "trash"],
                                   "description": "常见位置：caches=应用缓存，downloads=下载，logs=日志，xcode=Xcode 编译缓存，simulators=iOS 模拟器，devcache=开发工具缓存，backups=iPhone 备份，trash=废纸篓"],
                        "path": ["type": "string", "description": "其他目录的绝对路径或以 ~ 开头的路径，只能在家目录或 /Applications 内"],
                        "limit": ["type": "integer", "description": "返回条数，默认 20，最多 50"]
                    ],
                    "additionalProperties": false
                 ]),
        ToolSpec(name: "get_history",
                 description: "最近几分钟的趋势（面板打开期间记录）：CPU 占用或硬盘读写速度的最小/平均/最大值和按时间的采样点。",
                 parameters: [
                    "type": "object",
                    "properties": [
                        "metric": ["type": "string", "enum": ["cpu", "disk"], "description": "cpu 或 disk"]
                    ],
                    "required": ["metric"],
                    "additionalProperties": false
                 ]),
        ToolSpec(name: "get_folder_growth",
                 description: "家目录里哪些文件夹最近在变大：每天扫描一次记下的各文件夹大小，和几天前对比的增长量（已定位到最能解释增长的子文件夹）、所属应用，以及家目录下各顶层文件夹大小。用于回答“硬盘空间被谁慢慢吃掉了”“这周哪里涨了”。",
                 parameters: [
                    "type": "object",
                    "properties": [
                        "days": ["type": "integer", "description": "和几天前对比，默认用设置里的天数，最多 45"]
                    ],
                    "additionalProperties": false
                 ]),
        ToolSpec(name: "get_system_info",
                 description: "这台 Mac 的基本信息：型号、芯片、核数、内存、macOS 版本、已运行时间、温度状态、负载。",
                 parameters: ["type": "object", "properties": [:], "additionalProperties": false])
    ]

    /// Short Chinese label shown in the chat while a tool runs.
    static func label(_ name: String, _ args: [String: Any]) -> String {
        switch name {
        case "list_apps":
            let by = ["memory": "内存", "disk": "磁盘读写"][args["sort_by"] as? String ?? ""] ?? "CPU"
            return "查看应用列表（按\(by)）"
        case "get_app_processes": return "查看「\(args["app_name"] as? String ?? "应用")」的进程"
        case "get_memory_details": return "查看内存详情"
        case "get_disk_details": return "查看硬盘详情"
        case "get_space_overview": return "查看可清理空间"
        case "analyze_folder":
            if let target = args["target"] as? String { return "查看「\(targetTitle(target))」明细" }
            return "查看目录「\((args["path"] as? String ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"))」"
        case "get_history": return (args["metric"] as? String) == "disk" ? "查看硬盘读写趋势" : "查看 CPU 趋势"
        case "get_folder_growth": return "查看最近变大的文件夹"
        case "get_system_info": return "查看系统信息"
        default: return "查询 \(name)"
        }
    }

    private static func targetTitle(_ id: String) -> String {
        ["caches": "应用缓存", "downloads": "下载", "logs": "日志", "xcode": "Xcode 编译缓存",
         "simulators": "iOS 模拟器", "devcache": "开发工具缓存", "backups": "iPhone 备份", "trash": "废纸篓"][id] ?? id
    }

    // MARK: Execution

    static func execute(_ name: String, _ args: [String: Any]) async -> String {
        switch name {
        case "list_apps": return await listApps(args)
        case "get_app_processes": return await appProcesses(args)
        case "get_memory_details": return await memoryDetails()
        case "get_disk_details": return await diskDetails()
        case "get_space_overview": return await spaceOverview()
        case "analyze_folder": return await analyzeFolder(args)
        case "get_history": return await history(args)
        case "get_folder_growth":
            let days = intArg(args["days"])
            return json(await MainActor.run { FolderGrowthTracker.shared.toolSummary(days: days) })
        case "get_system_info": return await systemInfo()
        default: return json(["error": "未知工具 \(name)"])
        }
    }

    private static func listApps(_ args: [String: Any]) async -> String {
        let snapshot = await MainActor.run { Monitor.shared.snapshot }
        let sortBy = args["sort_by"] as? String ?? "cpu"
        let limit = min(max(intArg(args["limit"]) ?? 15, 1), 40)
        let apps: [AppUsage]
        switch sortBy {
        case "memory": apps = snapshot.apps.sorted { $0.rss > $1.rss }
        case "disk": apps = snapshot.apps.sorted { $0.diskTotal > $1.diskTotal }
        default: apps = snapshot.apps.sorted { $0.cpu > $1.cpu }
        }
        return json([
            "sampled_at": timeString(snapshot.sampledAt),
            "total_apps": snapshot.apps.count,
            "note": "cpu 为占一个核心的百分比（可超过 100）；系统进程的磁盘读写无法单独读取",
            "apps": apps.prefix(limit).map(appDict)
        ])
    }

    private static func appDict(_ app: AppUsage) -> [String: Any] {
        var dict: [String: Any] = [
            "name": app.name,
            "cpu_percent": round1(app.cpu),
            "memory": formatBytes(app.rss),
            "processes": app.processCount,
            "busiest_process": app.busiestProcess,
            "type": app.isSystem ? "系统服务" : "应用"
        ]
        if app.diskTotal > 0 {
            dict["disk_read"] = formatRate(app.diskRead)
            dict["disk_write"] = formatRate(app.diskWrite)
        }
        return dict
    }

    private static func appProcesses(_ args: [String: Any]) async -> String {
        let query = (args["app_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let (snapshot, samples) = await MainActor.run { (Monitor.shared.snapshot, Monitor.shared.processSamples) }
        guard let app = snapshot.apps.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame })
                ?? snapshot.apps.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) else {
            return json(["error": "没有找到名为「\(query)」的应用", "available": snapshot.apps.prefix(20).map(\.name)])
        }
        let members = samples.filter { sample in
            if let bundle = app.bundlePath { return sample.path.hasPrefix(bundle + "/") || sample.path == bundle }
            return sample.name == app.busiestProcess || prettifyProcessName(sample.name) == app.name
        }
        .sorted { $0.cpu > $1.cpu }
        return json([
            "app": appDict(app),
            "process_list": members.prefix(40).map { sample -> [String: Any] in
                var dict: [String: Any] = ["name": sample.name, "pid": Int(sample.pid),
                                           "cpu_percent": round1(sample.cpu), "memory": formatBytes(sample.rss)]
                if sample.diskRead + sample.diskWrite > 0 {
                    dict["disk_read"] = formatRate(sample.diskRead)
                    dict["disk_write"] = formatRate(sample.diskWrite)
                }
                return dict
            },
            "note": members.isEmpty ? "进程明细只在面板打开时采集，稍后再试" : "按 CPU 排序"
        ])
    }

    private static func memoryDetails() async -> String {
        let (snapshot, diagnosis) = await MainActor.run { (Monitor.shared.snapshot, Monitor.shared.diagnosis) }
        let memory = snapshot.memory
        return json([
            "total": formatBytes(memory.totalBytes),
            "used": formatBytes(memory.usedBytes),
            "compressed": formatBytes(memory.compressedBytes),
            "swap_used": formatBytes(memory.swapUsedBytes),
            "swap_total": formatBytes(memory.swapTotalBytes),
            "pressure": diagnosis.memoryLabel,
            "top_apps_by_memory": snapshot.apps.sorted { $0.rss > $1.rss }.prefix(12).map {
                ["name": $0.name, "memory": formatBytes($0.rss), "processes": $0.processCount] as [String: Any]
            }
        ])
    }

    private static func diskDetails() async -> String {
        let (snapshot, diagnosis) = await MainActor.run { (Monitor.shared.snapshot, Monitor.shared.diagnosis) }
        let disk = snapshot.disk
        var result: [String: Any] = [
            "space_status": diagnosis.diskLabel,
            "volumes": disk.volumes.map { volume -> [String: Any] in
                [
                    "name": volume.name, "path": volume.path, "is_startup_disk": volume.isRoot,
                    "internal": volume.isInternal, "format": volume.fileSystem,
                    "total": formatSize(volume.totalBytes), "available": formatSize(volume.availableBytes),
                    "purgeable": formatSize(volume.purgeableBytes), "free_now": formatSize(volume.freeBytes),
                    "used_percent": Int((volume.usedRatio * 100).rounded())
                ]
            },
            "read_rate": formatRate(disk.readRate),
            "write_rate": formatRate(disk.writeRate),
            "busiest_apps": snapshot.apps.filter { $0.diskTotal > 0 }.sorted { $0.diskTotal > $1.diskTotal }.prefix(8).map {
                ["name": $0.name, "read": formatRate($0.diskRead), "write": formatRate($0.diskWrite)] as [String: Any]
            }
        ]
        if let health = disk.health {
            result["smart_status"] = health.smartStatus
            result["solid_state"] = health.solidState
            result["local_time_machine_snapshots"] = health.localSnapshots
        }
        return json(result)
    }

    private static func spaceOverview() async -> String {
        let scanner = SpaceScanner.shared
        let needsScan = await MainActor.run { scanner.scannedAt == nil && !scanner.isScanning }
        if needsScan { await MainActor.run { scanner.scan() } }
        await scanner.waitUntilIdle(timeout: 120)
        let items = await MainActor.run { scanner.items }
        return json([
            "items": items.map { item -> [String: Any] in
                var dict: [String: Any] = ["id": item.id, "title": item.title, "hint": item.hint]
                switch item.state {
                case .done(let bytes): dict["size"] = formatSize(bytes)
                case .denied: dict["size"] = "无权限（需要完全磁盘访问权限）"
                case .missing: dict["size"] = "不存在"
                default: dict["size"] = "统计未完成"
                }
                return dict
            },
            "note": "可以用 analyze_folder 查看任意一项的明细"
        ])
    }

    private static func analyzeFolder(_ args: [String: Any]) async -> String {
        let limit = min(max(intArg(args["limit"]) ?? 20, 1), 50)
        var title = ""
        var paths: [String] = []
        var children: [FolderChild]?

        if let target = args["target"] as? String {
            // Use the scan's breakdown when we have it. Otherwise measure just this one place
            // (waiting for a whole scan would mean waiting on the biggest folder too).
            let scanner = SpaceScanner.shared
            let scanning = await MainActor.run { scanner.isScanning }
            if scanning { await scanner.waitUntilIdle(timeout: 120) }
            guard let item = await MainActor.run(body: { scanner.items.first { $0.id == target } }) else {
                return json(["error": "未知位置 \(target)"])
            }
            title = item.title
            paths = item.paths
            switch item.state {
            case .denied:
                return json(["target": title, "error": "这个目录受系统隐私保护，需要在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中允许负载侦探"])
            case .missing:
                return json(["target": title, "result": "这个位置不存在，占用为 0"])
            case .done:
                children = item.children
            default:
                // Not scanned yet: check which paths exist and whether we may read them.
                let fm = FileManager.default
                let existing = item.paths.filter { fm.fileExists(atPath: $0) }
                if existing.isEmpty { return json(["target": title, "result": "这个位置不存在，占用为 0"]) }
                paths = existing.filter { (try? fm.contentsOfDirectory(atPath: $0)) != nil }
                if paths.isEmpty {
                    return json(["target": title, "error": "这个目录受系统隐私保护，需要在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中允许负载侦探"])
                }
            }
        } else if let raw = args["path"] as? String {
            let path = (raw as NSString).expandingTildeInPath
            let standard = (path as NSString).standardizingPath
            let home = NSHomeDirectory()
            guard standard.hasPrefix(home) || standard.hasPrefix("/Applications") else {
                return json(["error": "只能查看家目录或 /Applications 里的目录"])
            }
            guard (try? FileManager.default.contentsOfDirectory(atPath: standard)) != nil else {
                return json(["error": "目录不存在或没有权限读取：\(standard)"])
            }
            title = standard.replacingOccurrences(of: home, with: "~")
            paths = [standard]
        } else {
            return json(["error": "需要 target 或 path 参数"])
        }

        if children == nil {
            let collected = await Task.detached(priority: .utility) { () -> [FolderChild] in
                paths.flatMap { SpaceScanner.breakdown($0, progress: { _ in }, cancelled: { false }).children }
            }.value
            children = collected.sorted { $0.bytes > $1.bytes }
        }

        let all = children ?? []
        let total = all.reduce(0) { $0 + $1.bytes }
        let running = await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
        let shown = all.prefix(limit)
        let rest = all.dropFirst(limit)

        return json([
            "folder": title,
            "total": formatSize(total),
            "item_count": all.count,
            "items": shown.map { child -> [String: Any] in
                var dict: [String: Any] = [
                    "name": child.name,
                    "size": formatSize(child.bytes),
                    "kind": child.isDirectory ? "文件夹" : "文件"
                ]
                if let modified = child.modified { dict["last_modified"] = dayString(modified) }
                if let owner = AppResolver.owner(of: child.name) {
                    dict["app"] = owner.name
                    if let installed = owner.installed { dict["app_installed"] = installed }
                    if let bundleID = owner.bundleID { dict["app_running"] = running.contains(bundleID) }
                }
                return dict
            },
            "others": rest.isEmpty ? "无" : "其余 \(rest.count) 项共 \(formatSize(rest.reduce(0) { $0 + $1.bytes }))",
            "note": "只统计了大小，没有读取文件内容。app_installed=false 通常说明是已卸载应用留下的残留。"
        ])
    }

    private static func history(_ args: [String: Any]) async -> String {
        let metric = args["metric"] as? String ?? "cpu"
        let (cpu, disk) = await MainActor.run { (Monitor.shared.cpuHistory, Monitor.shared.diskHistory) }
        func summary(_ values: [Double], _ format: (Double) -> String) -> [String: Any] {
            guard !values.isEmpty else { return ["note": "还没有历史数据"] }
            let avg = values.reduce(0, +) / Double(values.count)
            // Compress to ~12 points so the model sees the shape without a wall of numbers.
            let stride = max(values.count / 12, 1)
            let points = Swift.stride(from: 0, to: values.count, by: stride).map { format(values[$0]) }
            return ["min": format(values.min() ?? 0), "avg": format(avg), "max": format(values.max() ?? 0),
                    "points_old_to_new": points]
        }
        if metric == "disk" {
            let span = disk.first.map { Int(Date().timeIntervalSince($0.date) / 60) } ?? 0
            return json(["span_minutes": span,
                         "read": summary(disk.map(\.read), formatRate),
                         "write": summary(disk.map(\.write), formatRate)])
        }
        let span = cpu.first.map { Int(Date().timeIntervalSince($0.date) / 60) } ?? 0
        return json(["span_minutes": span, "cpu": summary(cpu.map(\.cpu)) { String(format: "%.0f%%", $0) }])
    }

    private static func systemInfo() async -> String {
        let (snapshot, diagnosis) = await MainActor.run { (Monitor.shared.snapshot, Monitor.shared.diagnosis) }
        let info = ProcessInfo.processInfo
        return json([
            "model": sysctlString("hw.model") ?? "未知",
            "chip": sysctlString("machdep.cpu.brand_string") ?? "未知",
            "cores": info.processorCount,
            "memory": formatBytes(info.physicalMemory),
            "macos": info.operatingSystemVersionString,
            "uptime_days": round1(snapshot.uptime / 86_400),
            "thermal": diagnosis.thermalLabel,
            "load_1_5_15": [round1(snapshot.load1), round1(snapshot.load5), round1(snapshot.load15)]
        ])
    }

    // MARK: Helpers

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func intArg(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// One decimal place, serialised without binary noise (0.1 instead of 0.10000000000000001).
    private static func round1(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.1f", value))
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Works out which app a cache/support folder belongs to from its name.
enum AppResolver {
    struct Owner {
        let name: String
        let bundleID: String?
        /// nil when we can't tell.
        let installed: Bool?
    }

    private static var cache: [String: Owner?] = [:]
    private static let lock = NSLock()

    private static let known: [String: String] = [
        "Homebrew": "Homebrew（命令行包管理器）",
        "pip": "Python pip", "pypoetry": "Poetry（Python）", "pnpm": "pnpm（Node.js）",
        "Yarn": "Yarn（Node.js）", "node-gyp": "Node.js 编译工具", "ms-playwright": "Playwright 浏览器",
        "go-build": "Go 编译缓存", "CocoaPods": "CocoaPods", "JetBrains": "JetBrains IDE",
        "Google": "Google 应用（Chrome 等）", "Microsoft": "Microsoft 应用", "Adobe": "Adobe 应用",
        "Cypress": "Cypress 测试工具", "typescript": "TypeScript", "huggingface": "Hugging Face 模型缓存",
        "torch": "PyTorch", "uv": "uv（Python）", "deno": "Deno", "bun": "Bun", "electron": "Electron",
        "SiriTTS": "Siri 语音", "GeoServices": "地图服务", "CloudKit": "iCloud", "Arc": "Arc 浏览器"
    ]

    static func owner(of folderName: String) -> Owner? {
        lock.lock()
        if let cached = cache[folderName] { lock.unlock(); return cached }
        lock.unlock()

        let result = resolve(folderName)
        lock.lock()
        cache[folderName] = result
        lock.unlock()
        return result
    }

    private static func resolve(_ name: String) -> Owner? {
        if let label = known[name] { return Owner(name: label, bundleID: nil, installed: nil) }
        // Leftover installers from Electron/Squirrel auto-updaters, e.g. "kimi-desktop-updater".
        if name.hasSuffix("-updater") || name.hasSuffix(".ShipIt") {
            let base = name.replacingOccurrences(of: "-updater", with: "").replacingOccurrences(of: ".ShipIt", with: "")
            return Owner(name: "\(base) 的自动更新安装包（更新完成后通常可删除）", bundleID: nil, installed: nil)
        }

        // Reverse-DNS names like com.google.Chrome or com.tinyspeck.slackmacgap.ShipIt
        let parts = name.split(separator: ".")
        if parts.count >= 2, name.range(of: " ") == nil, parts.first?.count ?? 0 <= 5 {
            for length in stride(from: parts.count, through: 2, by: -1) {
                let candidate = parts.prefix(length).joined(separator: ".")
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) {
                    let appName = FileManager.default.displayName(atPath: url.path)
                        .replacingOccurrences(of: ".app", with: "")
                    return Owner(name: appName, bundleID: candidate, installed: true)
                }
            }
            // Looks like an app ID but nothing installed answers to it.
            if ["com", "org", "net", "io", "app", "cn", "me", "dev", "co"].contains(String(parts[0])) {
                if name.hasPrefix("com.apple.") {
                    return Owner(name: "Apple 系统组件", bundleID: name, installed: nil)
                }
                return Owner(name: String(parts.count > 2 ? parts[2] : parts[1]), bundleID: name, installed: false)
            }
        }
        // Plain names that match an installed app (e.g. "Spotify", "Code").
        for folder in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let path = "\(folder)/\(name).app"
            if FileManager.default.fileExists(atPath: path) {
                return Owner(name: name, bundleID: Bundle(path: path)?.bundleIdentifier, installed: true)
            }
        }
        return nil
    }
}
