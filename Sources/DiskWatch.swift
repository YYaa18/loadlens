import Foundation

/// User-tunable rules for the "free space is dropping fast" alert.
struct DiskWatchSettings: Codable, Equatable {
    var enabled = false
    /// Alert when free space drops by at least this many GB...
    var thresholdGB: Double = 5
    /// ...within this many minutes.
    var windowMinutes: Int = 10
    /// Stay quiet for this long after an alert.
    var cooldownMinutes: Int = 30

    var thresholdBytes: UInt64 { UInt64(max(thresholdGB, 0.1) * 1_000_000_000) }
    var window: TimeInterval { TimeInterval(max(windowMinutes, 1) * 60) }
    var cooldown: TimeInterval { TimeInterval(max(cooldownMinutes, 1) * 60) }
}

/// One alert: how much space went, how fast, and who wrote the most meanwhile.
struct DiskGrowthEvent: Identifiable {
    struct Writer {
        /// Shown to the user, e.g. "Xcode 里的 Python".
        let name: String
        let app: String
        let process: String
        let bytes: UInt64
    }

    let id = UUID()
    let date: Date
    let dropBytes: UInt64
    let span: TimeInterval
    let freeBytes: UInt64
    let totalBytes: UInt64
    let writers: [Writer]

    /// What the triage model reads.
    var facts: DiskEventFacts {
        DiskEventFacts(minutes: max(Int((span / 60).rounded()), 1),
                       drop_gb: Double(dropBytes) / 1e9,
                       writers: writers.map { .init(app: $0.app, process: $0.process, gb: Double($0.bytes) / 1e9) },
                       free_gb: Double(freeBytes) / 1e9,
                       total_gb: Double(totalBytes) / 1e9)
    }

    var spanText: String {
        let minutes = Int((span / 60).rounded())
        return minutes >= 1 ? "\(minutes) 分钟" : "\(max(Int(span.rounded()), 1)) 秒"
    }

    var title: String { "硬盘空间在快速减少" }

    var body: String {
        var text = "最近 \(spanText)少了 \(formatSize(dropBytes))，还剩 \(formatSize(freeBytes))。"
        if writers.isEmpty {
            text += "没找到明显的写入者，可能是系统进程或已经结束的程序。"
        } else {
            let names = writers.prefix(2).map { "\($0.name)（\(formatSize($0.bytes))）" }
            text += "这段时间写入最多的是 " + names.joined(separator: "、") + "。"
        }
        return text
    }
}

/// Watches the startup disk's free space and alerts when it drops fast.
///
/// Two layers, so it stays cheap:
/// - every sample (~6 s): read free space (one statfs) and keep a short history;
/// - every minute: record each process's cumulative bytes written, so an alert can say who wrote
///   the most during the window. Only metadata from proc_pid_rusage, never file contents.
///
/// `observe()` runs on the sampler queue; settings are written on the main thread.
final class DiskGrowthWatcher: ObservableObject {
    static let shared = DiskGrowthWatcher()

    @Published var settings: DiskWatchSettings {
        didSet {
            guard settings != oldValue else { return }
            lock.locked { active = settings }
            if persists, let data = try? JSONEncoder().encode(settings) {
                Self.store.set(data, forKey: Self.key)
            }
        }
    }
    @Published private(set) var recentEvents: [DiskGrowthEvent] = []

    /// Called on alert instead of a system notification (used by the terminal test mode).
    var onEvent: ((DiskGrowthEvent) -> Void)?

    private struct FreePoint {
        let date: Date
        let free: UInt64
    }

    private struct WriteSnapshot {
        let date: Date
        /// pid -> (process name, executable path, cumulative bytes written)
        let processes: [pid_t: (name: String, path: String, written: UInt64)]
    }

    private static let key = "diskWatch"
    private static let debug = ProcessInfo.processInfo.environment["LOADLENS_DISKWATCH_DEBUG"] == "1"
    private static let store: UserDefaults =
        ProcessInfo.processInfo.environment["LOADLENS_SETTINGS_SUITE"]
            .flatMap { UserDefaults(suiteName: "local.loadlens.\($0)") } ?? .standard

    private let lock = NSLock()
    private var active: DiskWatchSettings
    private let persists: Bool
    private var points: [FreePoint] = []
    private var snapshots: [WriteSnapshot] = []
    private var lastAlert = Date.distantPast
    private var nameCache: [pid_t: (name: String, path: String)] = [:]
    private let ownPID = getpid()

    private convenience init() {
        let saved = Self.store.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(DiskWatchSettings.self, from: $0) }
        self.init(settings: saved ?? DiskWatchSettings(), persists: true)
    }

    /// A watcher with fixed settings that are never saved (terminal test mode).
    init(settings: DiskWatchSettings, persists: Bool) {
        self.settings = settings
        self.active = settings
        self.persists = persists
    }

    /// Latest status, for the terminal test mode.
    struct Status {
        let free: UInt64
        let drop: UInt64
        let span: TimeInterval
    }

    @discardableResult
    func observe(now: Date = Date()) -> Status? {
        let rules = lock.locked { active }
        if Self.debug, !rules.enabled { print("[disk-watch] disabled"); fflush(stdout) }
        guard rules.enabled, let free = Self.readFreeSpace() else {
            points.removeAll()
            snapshots.removeAll()
            return nil
        }

        points.append(FreePoint(date: now, free: free))
        points.removeAll { now.timeIntervalSince($0.date) > rules.window }

        if snapshots.last.map({ now.timeIntervalSince($0.date) >= 60 }) ?? true {
            snapshots.append(takeWriteSnapshot(now))
        }
        // Keep one snapshot older than the window as the baseline.
        while snapshots.count > 1, now.timeIntervalSince(snapshots[1].date) >= rules.window {
            snapshots.removeFirst()
        }

        // Compare against the fullest point in the window, so a drop is caught even when space
        // briefly went up in between (e.g. a temporary file was deleted).
        guard let peak = points.max(by: { $0.free < $1.free }) else { return nil }
        let drop = peak.free > free ? peak.free - free : 0
        let status = Status(free: free, drop: drop, span: now.timeIntervalSince(peak.date))
        if Self.debug {
            print("[disk-watch] free=\(free) drop=\(drop) points=\(points.count) rules=\(rules)")
            fflush(stdout)
        }

        guard drop >= rules.thresholdBytes,
              now.timeIntervalSince(lastAlert) >= rules.cooldown else { return status }

        let event = DiskGrowthEvent(date: now,
                                    dropBytes: drop,
                                    span: max(status.span, 1),
                                    freeBytes: free,
                                    totalBytes: Self.readTotalSpace() ?? 0,
                                    writers: topWriters(now: now, since: peak.date))
        lastAlert = now
        // Start over, so the same drop does not count again after the cooldown.
        points = [FreePoint(date: now, free: free)]

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentEvents.insert(event, at: 0)
            if self.recentEvents.count > 20 { self.recentEvents.removeLast() }
            if let onEvent = self.onEvent {
                onEvent(event)
            } else {
                TriageService.shared.handle(facts: event.facts, title: event.title, body: event.body)
            }
        }
        return status
    }

    // MARK: Reading

    /// Free space on the startup disk, not counting purgeable space (which macOS may reclaim).
    static func readFreeSpace() -> UInt64? {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let free = values.volumeAvailableCapacity, free >= 0 else { return nil }
        return UInt64(free)
    }

    static func readTotalSpace() -> UInt64? {
        let url = URL(fileURLWithPath: "/")
        guard let total = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity,
              total > 0 else { return nil }
        return UInt64(total)
    }

    private func takeWriteSnapshot(_ now: Date) -> WriteSnapshot {
        let pids = ProcessTracker.allPIDs()
        var processes: [pid_t: (name: String, path: String, written: UInt64)] = [:]
        processes.reserveCapacity(pids.count)
        for pid in pids where pid != ownPID {
            // Fails for other users' (root) processes; those simply stay unattributed.
            guard let io = readProcessDiskIO(pid) else { continue }
            let meta: (name: String, path: String)
            if let cached = nameCache[pid] {
                meta = cached
            } else {
                let path = ProcessTracker.processPath(pid)
                let name = ProcessTracker.processName(pid)
                meta = (name.isEmpty ? (path as NSString).lastPathComponent : name, path)
                nameCache[pid] = meta
            }
            processes[pid] = (meta.name, meta.path, io.write)
        }
        if nameCache.count > processes.count * 2 + 256 {
            nameCache = nameCache.filter { processes[$0.key] != nil }
        }
        return WriteSnapshot(date: now, processes: processes)
    }

    /// Bytes written per app between the baseline snapshot and now, biggest first.
    /// Note: bytes written are not the same as space used (a file can be rewritten or deleted),
    /// so this names the likely cause rather than proving it.
    private func topWriters(now: Date, since: Date) -> [DiskGrowthEvent.Writer] {
        let current = takeWriteSnapshot(now)
        let baseline = snapshots.last(where: { $0.date <= since }) ?? snapshots.first

        var samples: [ProcessSample] = []
        for (pid, process) in current.processes {
            var written = process.written
            if let before = baseline?.processes[pid], before.name == process.name {
                written = process.written >= before.written ? process.written - before.written : 0
            }
            // A process started after the baseline counts with everything it wrote.
            guard written > 0 else { continue }
            var sample = ProcessSample(pid: pid, name: process.name, path: process.path, cpu: 0, rss: 0)
            sample.diskWrite = Double(written)
            samples.append(sample)
        }

        // Group by app, but remember which process inside it wrote the most: tools such as
        // python3 or git live inside Xcode.app, and "Xcode" alone would point at the wrong thing.
        var apps: [String: (bytes: Double, topProcess: String, topBytes: Double)] = [:]
        for sample in samples {
            let app = aggregate([sample], excluding: []).first?.name ?? sample.name
            var entry = apps[app] ?? (0, sample.name, 0)
            entry.bytes += sample.diskWrite
            if sample.diskWrite > entry.topBytes {
                entry.topProcess = sample.name
                entry.topBytes = sample.diskWrite
            }
            apps[app] = entry
        }

        return apps
            .filter { $0.value.bytes >= 50_000_000 }
            .sorted { $0.value.bytes > $1.value.bytes }
            .prefix(3)
            .map { app, entry in
                let process = entry.topProcess
                let sameName = app.lowercased().contains(process.lowercased())
                    || process.lowercased().contains(app.lowercased())
                return DiskGrowthEvent.Writer(name: sameName ? app : "\(app) 里的 \(process)",
                                              app: app, process: process, bytes: UInt64(entry.bytes))
            }
    }
}

private extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
