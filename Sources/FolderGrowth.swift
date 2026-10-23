import Foundation
import IOKit.ps

/// User-tunable rules for the "a folder keeps growing" alert.
struct FolderGrowthSettings: Codable, Equatable {
    var enabled = false
    /// Alert when a folder grew by at least this many GB...
    var thresholdGB: Double = 5
    /// ...over this many days.
    var days: Int = 7

    var thresholdBytes: UInt64 { UInt64(max(thresholdGB, 0.1) * 1_000_000_000) }
}

/// Folder sizes under the home folder at one moment. Paths are relative to the scanned root,
/// e.g. "Library/Caches/com.google.Chrome". Only folders above a size floor are kept.
struct FolderSnapshot: Codable {
    let date: Date
    let total: UInt64
    let folders: [String: UInt64]
    /// Folders that could not be read (privacy permission denied); their growth is unknown.
    let skipped: [String]
    var duration: TimeInterval = 0
}

/// One folder that grew between two snapshots.
struct FolderGrowth: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let grown: UInt64
    let size: UInt64
    let since: Date
    let owner: String?

    var displayPath: String { path.isEmpty ? "~" : "~/" + path }

    var label: String {
        owner.map { "\(displayPath)（\($0)）" } ?? displayPath
    }

    var line: String {
        "\(label) 涨了 \(formatSize(grown))，现在 \(formatSize(size))"
    }

    /// What the triage model reads.
    func facts(freeBytes: UInt64, totalBytes: UInt64) -> DiskEventFacts {
        let days = max(Int((Date().timeIntervalSince(since) / 86_400).rounded()), 1)
        return DiskEventFacts(days: days, path: displayPath, owner: owner, grown_gb: Double(grown) / 1e9,
                              size_gb: Double(size) / 1e9, free_gb: Double(freeBytes) / 1e9,
                              total_gb: Double(totalBytes) / 1e9)
    }
}

/// Once a day, measures every folder under the home folder (sizes only, never contents) and
/// alerts when one keeps growing. The history it keeps is also what the AI tool reads.
///
/// All published state and the history are touched on the main thread; the scan itself runs on
/// a throttled background queue.
final class FolderGrowthTracker: ObservableObject {
    static let shared = FolderGrowthTracker()

    @Published var settings: FolderGrowthSettings {
        didSet {
            guard settings != oldValue else { return }
            if let data = try? JSONEncoder().encode(settings) { Self.store.set(data, forKey: Self.key) }
            if settings.enabled && !oldValue.enabled && history.snapshots.isEmpty { scanNow() }
            refreshGrowth()
        }
    }
    @Published private(set) var isScanning = false
    /// Biggest growth since the comparison snapshot (above 100 MB), for the settings window.
    @Published private(set) var latestGrowth: [FolderGrowth] = []

    var lastSnapshot: FolderSnapshot? { history.snapshots.last }
    var snapshotCount: Int { history.snapshots.count }

    private struct History: Codable {
        var snapshots: [FolderSnapshot] = []
        /// path -> folder size when we last alerted about it, so the same growth is reported once.
        var alerted: [String: UInt64] = [:]
    }

    private static let key = "folderGrowth"
    private static let suite = ProcessInfo.processInfo.environment["LOADLENS_SETTINGS_SUITE"]
    private static let store: UserDefaults =
        suite.flatMap { UserDefaults(suiteName: "local.loadlens.\($0)") } ?? .standard
    private static let historyURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let name = suite.map { "folder-history.\($0).json" } ?? "folder-history.json"
        return base.appendingPathComponent("LoadLens", isDirectory: true).appendingPathComponent(name)
    }()

    private var history = History()
    private var timer: Timer?
    private let queue = DispatchQueue(label: "loadlens.folders", qos: .background)

    private init() {
        settings = Self.store.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(FolderGrowthSettings.self, from: $0) } ?? FolderGrowthSettings()
        if let data = try? Data(contentsOf: Self.historyURL),
           let saved = try? JSONDecoder().decode(History.self, from: data) {
            history = saved
        }
        refreshGrowth()
    }

    /// Checks every 30 minutes whether a daily scan is due.
    func start() {
        guard timer == nil else { return }
        let newTimer = Timer(timeInterval: 1_800, repeats: true) { [weak self] _ in self?.scanIfDue() }
        newTimer.tolerance = 300
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.scanIfDue() }
    }

    /// A scan is due once a day, preferably on power and while the Mac is not busy.
    private func scanIfDue() {
        guard settings.enabled, !isScanning else { return }
        let age = lastSnapshot.map { Date().timeIntervalSince($0.date) } ?? .infinity
        guard age >= 20 * 3_600 else { return }
        let overdue = age >= 36 * 3_600
        guard overdue || (Self.onPower() && Monitor.shared.snapshot.cpu < 40) else { return }
        scanNow()
    }

    func scanNow() {
        guard !isScanning else { return }
        isScanning = true
        let root = NSHomeDirectory()
        queue.async { [weak self] in
            let snapshot = Self.scan(root: root)
            DispatchQueue.main.async { self?.finish(snapshot) }
        }
    }

    private func finish(_ snapshot: FolderSnapshot) {
        isScanning = false
        // Keep one snapshot per day (the latest) for 45 days.
        let calendar = Calendar.current
        history.snapshots.removeAll { calendar.isDate($0.date, inSameDayAs: snapshot.date) }
        history.snapshots.append(snapshot)
        history.snapshots.removeAll { snapshot.date.timeIntervalSince($0.date) > 45 * 86_400 }

        if settings.enabled {
            let alerts = Self.alerts(in: Self.growth(current: snapshot, history: history.snapshots,
                                                     rules: settings, minimum: settings.thresholdBytes),
                                     alerted: history.alerted, rules: settings)
            let free = DiskGrowthWatcher.readFreeSpace() ?? 0
            let total = DiskGrowthWatcher.readTotalSpace() ?? 0
            for item in alerts {
                history.alerted[item.path] = item.size
                // Each folder is judged on its own: one may be a cache to clean, another your own files.
                TriageService.shared.handle(facts: item.facts(freeBytes: free, totalBytes: total),
                                            title: Self.title(for: [item]), body: Self.body(for: [item], rules: settings))
            }
        }
        save()
        refreshGrowth()
    }

    private func refreshGrowth() {
        guard let current = lastSnapshot else { latestGrowth = []; return }
        latestGrowth = Array(Self.growth(current: current, history: history.snapshots,
                                         rules: settings, minimum: 100_000_000).prefix(5))
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.historyURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: Self.historyURL, options: .atomic)
        } catch {
            // Losing a day of history is harmless (the next scan writes it again), but say so.
            NSLog("LoadLens: could not save folder history: %@", error.localizedDescription)
        }
    }

    // MARK: Scanning

    /// One pass over `root` like `du`: allocated bytes of every folder, kept when it is at most
    /// `maxDepth` levels deep and at least `minBytes` big. Reads sizes only.
    static func scan(root: String, maxDepth: Int = 4, minBytes: UInt64 = 200_000_000) -> FolderSnapshot {
        let started = Date()
        // Let normal disk work go first; this scan can wait.
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)

        var folders: [String: UInt64] = [:]
        var skipped: [String] = []
        var total: UInt64 = 0
        let prefix = root.hasSuffix("/") ? root : root + "/"

        guard let cPath = strdup(root) else {
            return FolderSnapshot(date: started, total: 0, folders: [:], skipped: [])
        }
        defer { free(cPath) }
        var roots: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            return FolderSnapshot(date: started, total: 0, folders: [:], skipped: [])
        }
        defer { fts_close(fts) }

        func relative(_ entry: UnsafeMutablePointer<FTSENT>) -> String {
            let path = String(cString: entry.pointee.fts_path)
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""
        }

        // Running totals of the folders we are inside, innermost last.
        var stack: [(level: Int, bytes: UInt64)] = []

        /// Closes the folder at `level`: records its size and adds it to its parent.
        func close(_ entry: UnsafeMutablePointer<FTSENT>, level: Int, record: Bool) {
            guard let top = stack.last, top.level == level else { return }
            stack.removeLast()
            if record, level >= 1, level <= maxDepth, top.bytes >= minBytes { folders[relative(entry)] = top.bytes }
            if !stack.isEmpty { stack[stack.count - 1].bytes += top.bytes }
        }

        while let entry = fts_read(fts) {
            let level = Int(entry.pointee.fts_level)
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                stack.append((level, 0))
            case FTS_DP:
                close(entry, level: level, record: true)
            case FTS_F:
                if let stat = entry.pointee.fts_statp {
                    let size = UInt64(max(stat.pointee.st_blocks, 0)) * 512
                    total += size
                    if !stack.isEmpty { stack[stack.count - 1].bytes += size }
                }
            case FTS_DNR, FTS_ERR:
                // A folder we may not read (privacy settings). fts reported it as FTS_D first but
                // sends no FTS_DP, so close it here or every total above it goes out of step.
                if level >= 1, level <= maxDepth { skipped.append(relative(entry)) }
                close(entry, level: level, record: false)
            default:
                break
            }
        }
        return FolderSnapshot(date: Date(), total: total, folders: folders, skipped: skipped,
                              duration: Date().timeIntervalSince(started))
    }

    private static func onPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPSACPowerValue
    }

    // MARK: Comparing

    /// Folders that grew by at least `minimum` since the oldest snapshot inside the rule's window,
    /// biggest first. A folder is replaced by its subfolder when that subfolder explains most of
    /// the growth, so the result points as deep as the data allows.
    static func growth(current: FolderSnapshot, history: [FolderSnapshot],
                       rules: FolderGrowthSettings, minimum: UInt64) -> [FolderGrowth] {
        let window = TimeInterval(max(rules.days, 1)) * 86_400 + 12 * 3_600
        guard let base = history
            .filter({ current.date.timeIntervalSince($0.date) >= 12 * 3_600
                      && current.date.timeIntervalSince($0.date) <= window })
            .min(by: { $0.date < $1.date }) else { return [] }

        let unknown = Set(base.skipped)
        var grown: [String: UInt64] = [:]
        for (path, size) in current.folders where !unknown.contains(path) {
            // A folder missing from the older snapshot was below the size floor (or did not exist).
            let before = base.folders[path] ?? 0
            if size > before, size - before >= minimum { grown[path] = size - before }
        }

        func isInside(_ path: String, _ ancestor: String) -> Bool { path.hasPrefix(ancestor + "/") }

        // Drop a folder when one of its subfolders accounts for at least 70% of its growth.
        let deepest = grown.filter { path, amount in
            !grown.contains { other, otherAmount in
                isInside(other, path) && Double(otherAmount) >= Double(amount) * 0.7
            }
        }
        // Of what is left, report a folder only once: drop subfolders of a folder already reported.
        let reported = deepest.filter { path, _ in !deepest.keys.contains { isInside(path, $0) } }

        return reported
            .sorted { $0.value > $1.value }
            .map { path, amount in
                FolderGrowth(path: path, grown: amount, size: current.folders[path] ?? amount,
                             since: base.date, owner: owner(of: path))
            }
    }

    /// Growth that has not been reported yet (or grew by another threshold since).
    static func alerts(in growth: [FolderGrowth], alerted: [String: UInt64],
                       rules: FolderGrowthSettings) -> [FolderGrowth] {
        growth.filter { item in
            guard let sizeAtAlert = alerted[item.path] else { return true }
            return item.size >= sizeAtAlert + rules.thresholdBytes
        }
    }

    static func title(for alerts: [FolderGrowth]) -> String {
        alerts.count == 1 ? "有个文件夹在持续变大" : "有 \(alerts.count) 个文件夹在持续变大"
    }

    static func body(for alerts: [FolderGrowth], rules: FolderGrowthSettings) -> String {
        guard let first = alerts.first else { return "" }
        let days = max(Int((Date().timeIntervalSince(first.since) / 86_400).rounded()), 1)
        var text = "最近 \(days) 天，" + alerts.prefix(2).map(\.line).joined(separator: "；") + "。"
        if alerts.count > 2 { text += "还有 \(alerts.count - 2) 个，打开「硬盘空间监控」查看。" }
        return text
    }

    /// Names the app a folder belongs to, from the innermost path component that we recognise.
    static func owner(of path: String) -> String? {
        let generic: Set<String> = ["Library", "Caches", "Application Support", "Containers", "Group Containers",
                                    "Data", "Developer", "Logs", "Documents", "Downloads", "Desktop"]
        for component in path.split(separator: "/").reversed().map(String.init) where !generic.contains(component) {
            if let owner = AppResolver.owner(of: component) { return owner.name }
        }
        return nil
    }

    // MARK: AI tool

    /// Summary for the AI's `get_folder_growth` tool.
    func toolSummary(days: Int?) -> [String: Any] {
        guard let current = lastSnapshot else {
            return ["status": settings.enabled ? "还没完成第一次扫描" : "「持续变大的文件夹」监控没有打开，暂无数据"]
        }
        var rules = settings
        if let days { rules.days = min(max(days, 1), 45) }
        let items = Self.growth(current: current, history: history.snapshots, rules: rules, minimum: 50_000_000)
        let biggest = current.folders
            .filter { !$0.key.contains("/") }
            .sorted { $0.value > $1.value }
            .prefix(10)
        let formatter = ISO8601DateFormatter()
        return [
            "last_scan": formatter.string(from: current.date),
            "snapshots": history.snapshots.count,
            "compared_since": items.first.map { formatter.string(from: $0.since) } ?? "历史不足 1 天，暂时无法比较",
            "growth": items.prefix(15).map { item -> [String: Any] in
                var dict: [String: Any] = ["path": item.displayPath, "grown": formatSize(item.grown),
                                           "size": formatSize(item.size)]
                if let owner = item.owner { dict["owner"] = owner }
                return dict
            },
            "top_level_folders": biggest.map { ["path": "~/" + $0.key, "size": formatSize($0.value)] },
            "unreadable": current.skipped.prefix(10).map { "~/" + $0 }
        ]
    }
}
