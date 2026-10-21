import Foundation
import AppKit

final class Monitor: ObservableObject {
    static let shared = Monitor()

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var diagnosis = Diagnosis.initial
    @Published private(set) var menuTitle = "…"
    @Published private(set) var menuSymbol = "gauge"
    @Published private(set) var cpuHistory: [CPUPoint] = []
    @Published private(set) var diskHistory: [DiskPoint] = []
    /// Raw per-process samples from the latest full scan (for the AI's detail lookups).
    private(set) var processSamples: [ProcessSample] = []
    @Published private(set) var settingsMessage: String?

    @Published var launchAtLogin = LoginItem.isEnabled {
        didSet {
            guard !suppressLoginWrite else { return }
            do {
                try LoginItem.setEnabled(launchAtLogin)
            } catch {
                suppressLoginWrite = true
                launchAtLogin.toggle()
                suppressLoginWrite = false
                flashSettingsMessage("开机自启设置失败")
            }
        }
    }

    @Published var notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled") {
        didSet {
            guard !suppressNotificationWrite else { return }
            UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
            guard notificationsEnabled else { return }

            Notifier.shared.requestAuthorization { [weak self] granted in
                guard let self, !granted else { return }
                self.suppressNotificationWrite = true
                self.notificationsEnabled = false
                self.suppressNotificationWrite = false
                self.flashSettingsMessage("未获得通知权限，可在系统设置 → 通知里允许")
            }
        }
    }

    private let cpuSampler = CPUSampler()
    private let tracker = ProcessTracker()
    private let systemReader = SystemProcessReader()
    private let queue = DispatchQueue(label: "loadlens.sampler", qos: .utility)
    private var timer: Timer?
    private var panelOpen = false
    private var started = false
    private let diskIO = DiskIOSampler()
    private var volumes: [VolumeInfo] = []
    private var volumesDate = Date.distantPast
    private var diskHealth: DiskHealth?
    private var healthDate = Date.distantPast
    private var systemCache: [ProcessSample] = []
    private var systemCacheDate = Date.distantPast
    private var systemNamesDate = Date.distantPast
    private var iconCache: [String: NSImage] = [:]
    private let ownPID = getpid()
    private var suppressLoginWrite = false
    private var suppressNotificationWrite = false
    private var hotSince: Date?
    private var lastAlert = Date.distantPast

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        queue.async { [weak self] in
            guard let self else { return }
            _ = self.cpuSampler.sample()
            _ = self.tracker.scan()
            Thread.sleep(forTimeInterval: 1.0)
            self.capture(full: true)
        }
        schedule(every: 6)
    }

    func panelDidOpen() {
        panelOpen = true
        schedule(every: 5)
        requestSample(full: true)
    }

    func panelDidClose() {
        panelOpen = false
        schedule(every: 6)
    }

    func refreshNow() {
        requestSample(full: true)
    }

    func icon(for app: AppUsage) -> NSImage? {
        guard let path = app.bundlePath else { return nil }
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else {
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Asks the app to quit normally (it can still prompt to save documents).
    func quit(_ app: AppUsage) {
        guard let path = app.bundlePath else { return }
        for running in NSWorkspace.shared.runningApplications where running.bundleURL?.path == path {
            running.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshNow()
        }
    }

    func reveal(_ app: AppUsage) {
        guard let path = app.bundlePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(reportText(), forType: .string)
    }

    func reportText() -> String {
        let snap = snapshot
        let diag = diagnosis
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var lines: [String] = []
        lines.append("负载侦探诊断 · \(formatter.string(from: snap.sampledAt))")
        lines.append("状态：\(diag.headline)")
        lines.append(diag.detail)
        lines.append("温度：\(diag.thermalLabel) · 已运行 \(Int(snap.uptime / 86_400)) 天")
        lines.append(contentsOf: diskContextLines(snap.disk, apps: snap.apps))
        lines.append("")
        lines.append("占用最高的应用：")
        for (index, app) in snap.apps.prefix(6).enumerated() {
            lines.append(String(format: "%d. %@  %.0f%%  %@", index + 1, app.name, app.cpu, formatBytes(app.rss)))
        }
        lines.append("")
        lines.append("建议：")
        for item in diag.advice {
            lines.append("· " + item)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Sampling

    private func schedule(every interval: TimeInterval) {
        timer?.invalidate()
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.requestSample(full: self.panelOpen)
        }
        newTimer.tolerance = interval * 0.2
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func requestSample(full: Bool) {
        queue.async { [weak self] in
            self?.capture(full: full)
        }
    }

    private func capture(full: Bool) {
        let cpu = cpuSampler.sample()
        let memory = readMemoryStats()
        let loads = readLoadAverage()
        let thermal = readThermalState()
        let uptime = readSystemUptime()

        let userSamples = tracker.scan(includeDisk: full)
        let io = diskIO.sample()
        let disk = readDiskState(full: full, read: io.read, write: io.write)
        var samples = userSamples
        if full {
            let now = Date()
            if now.timeIntervalSince(systemCacheDate) > 30 {
                let refreshNames = now.timeIntervalSince(systemNamesDate) > 300
                systemCache = systemReader.sample(includeNames: refreshNames)
                systemCacheDate = now
                if refreshNames { systemNamesDate = now }
            }
            samples = mergeSamples(primary: userSamples, secondary: systemCache)
        }

        let apps = aggregate(samples, excluding: [ownPID])

        var snap = Snapshot()
        snap.cpu = cpu
        snap.load1 = loads.0
        snap.load5 = loads.1
        snap.load15 = loads.2
        snap.memory = memory
        snap.thermal = thermal
        snap.uptime = uptime
        snap.apps = apps
        snap.disk = disk
        snap.cores = ProcessInfo.processInfo.processorCount
        snap.sampledAt = Date()

        let diag = Diagnoser.evaluate(snap)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = snap
            if full { self.processSamples = samples.filter { $0.pid != self.ownPID } }
            self.diagnosis = diag
            let percent = "\(Int(cpu.rounded()))%"
            self.menuTitle = percent
            switch diag.level {
            case .calm: self.menuSymbol = "checkmark.circle"
            case .busy: self.menuSymbol = "exclamationmark.triangle"
            case .hot: self.menuSymbol = "flame.fill"
            }

            self.cpuHistory.append(CPUPoint(date: snap.sampledAt, cpu: snap.cpu))
            self.diskHistory.append(DiskPoint(date: snap.sampledAt, read: disk.readRate, write: disk.writeRate))
            if self.diskHistory.count > 160 {
                self.diskHistory.removeFirst(self.diskHistory.count - 160)
            }
            if self.cpuHistory.count > 160 {
                self.cpuHistory.removeFirst(self.cpuHistory.count - 160)
            }
            self.evaluateAlert(diagnosis: diag, snapshot: snap)
        }
    }

    /// Volumes are cheap but change rarely; health needs two command-line tools, so it is read
    /// at most every 30 minutes and only while the panel is open (or on first use).
    private func readDiskState(full: Bool, read: Double, write: Double) -> DiskSnapshot {
        let now = Date()
        if now.timeIntervalSince(volumesDate) > (full ? 15 : 120) {
            volumes = readVolumes()
            volumesDate = now
        }
        if (full || diskHealth == nil), now.timeIntervalSince(healthDate) > 1_800 {
            diskHealth = readDiskHealth()
            healthDate = now
        }
        return DiskSnapshot(volumes: volumes, readRate: read, writeRate: write, health: diskHealth)
    }

    /// Re-read volumes right away, e.g. after ejecting a disk.
    func refreshVolumes() {
        queue.async { [weak self] in
            self?.volumesDate = .distantPast
            self?.capture(full: true)
        }
    }

    private func flashSettingsMessage(_ message: String) {
        settingsMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.settingsMessage == message else { return }
            self.settingsMessage = nil
        }
    }

    private func evaluateAlert(diagnosis: Diagnosis, snapshot: Snapshot) {
        guard notificationsEnabled else {
            hotSince = nil
            return
        }
        guard diagnosis.level == .hot else {
            hotSince = nil
            return
        }

        if hotSince == nil { hotSince = Date() }
        guard let since = hotSince, Date().timeIntervalSince(since) >= 120 else { return }
        guard Date().timeIntervalSince(lastAlert) >= 1_800 else { return }

        let body: String
        if snapshot.thermal == .serious || snapshot.thermal == .critical {
            body = "温度已经很高，系统在限制性能。点开菜单栏看看是谁在占用。"
        } else if let top = snapshot.apps.first, top.cpu >= 10 {
            body = "已持续高负荷 2 分钟，主要是 \(top.name)（\(Int(top.cpu.rounded()))%）。点开菜单栏查看建议。"
        } else {
            body = "已持续高负荷 2 分钟。点开菜单栏查看是谁在占用。"
        }

        Notifier.shared.send(title: "电脑有点吃力", body: body)
        lastAlert = Date()
        hotSince = Date()
    }
}
