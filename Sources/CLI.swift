import Foundation
import AppKit
import SwiftUI

/// Terminal-mode report, used for testing and for `--diagnose`.
func runDiagnosticReport() {
    let cpuSampler = CPUSampler()
    let tracker = ProcessTracker()

    _ = cpuSampler.sample()
    _ = tracker.scan()
    Thread.sleep(forTimeInterval: 1.0)

    var snap = Snapshot()
    snap.cpu = cpuSampler.sample()
    let loads = readLoadAverage()
    snap.load1 = loads.0
    snap.load5 = loads.1
    snap.load15 = loads.2
    snap.memory = readMemoryStats()
    snap.thermal = readThermalState()
    snap.uptime = readSystemUptime()
    snap.cores = ProcessInfo.processInfo.processorCount
    snap.sampledAt = Date()

    let diskIO = DiskIOSampler()
    _ = diskIO.sample()
    _ = tracker.scan(includeDisk: true)
    Thread.sleep(forTimeInterval: 1.0)
    let io = diskIO.sample()
    snap.disk = DiskSnapshot(volumes: readVolumes(), readRate: io.read, writeRate: io.write, health: readDiskHealth())

    let userSamples = tracker.scan(includeDisk: true)
    let systemSamples = readSystemProcesses()
    let merged = mergeSamples(primary: userSamples, secondary: systemSamples)
    snap.apps = aggregate(merged, excluding: [getpid()])

    let diag = Diagnoser.evaluate(snap)

    print("")
    print("负载侦探 · 本机体检")
    print(String(repeating: "─", count: 38))
    print("状态：\(diag.headline)")
    print(diag.detail)
    print("温度：\(diag.thermalLabel)　内存压力：\(diag.memoryLabel)　硬盘：\(diag.diskLabel)")
    for line in diskContextLines(snap.disk, apps: snap.apps) {
        print(line)
    }
    print(String(repeating: "─", count: 38))
    print("占用最高的应用：")
    for (index, app) in snap.apps.prefix(6).enumerated() {
        let subtitle = app.subtitle.isEmpty ? "" : "（\(app.subtitle)）"
        print(String(format: "  %d. %@  %.0f%%  %@",
                     index + 1, app.name, app.cpu, subtitle))
    }
    print(String(repeating: "─", count: 38))
    print("建议：")
    for item in diag.advice {
        print("  • \(item)")
    }
    print("")
}

/// Opens the panel in a normal window for visual verification and for measuring open-panel cost.
@MainActor
func showPreviewWindow(seconds: Double) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let monitor = Monitor.shared
    monitor.start()
    monitor.panelDidOpen()

    let hosting = NSHostingView(rootView: PanelView(monitor: monitor))
    hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: 620)

    let window = NSWindow(contentRect: hosting.frame,
                          styleMask: [.titled, .closable],
                          backing: .buffered,
                          defer: false)
    window.title = "负载侦探预览"
    window.contentView = hosting
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    let fitting = hosting.fittingSize
    window.setContentSize(NSSize(width: panelWidth, height: min(max(fitting.height, 320), 820)))
    window.center()
    window.makeKeyAndOrderFront(nil)

    print("window-number \(window.windowNumber)")
    fflush(stdout)

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    window.close()
}

/// Renders the panel offscreen, used to verify layout without screen recording permission.
@MainActor
func renderPreview(to path: String) {
    _ = NSApplication.shared
    let monitor = Monitor.shared
    monitor.start()
    RunLoop.main.run(until: Date().addingTimeInterval(2.5))

    let view = PanelView(monitor: monitor)
        .frame(width: panelWidth)
        .background(Color(nsColor: .windowBackgroundColor))

    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("render failed")
        return
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(Int(image.size.width))x\(Int(image.size.height)))")
    } catch {
        print("write failed: \(error)")
    }
}

/// Terminal test for the disk-space alert: `--disk-watch [seconds] [thresholdGB] [windowMinutes]`.
/// Uses its own settings (never saved) and prints alerts instead of sending notifications.
func runDiskWatchTest(seconds: Double, thresholdGB: Double, windowMinutes: Int) {
    var rules = DiskWatchSettings()
    rules.enabled = true
    rules.thresholdGB = thresholdGB
    rules.windowMinutes = windowMinutes
    let watcher = DiskGrowthWatcher(settings: rules, persists: false)
    watcher.onEvent = { event in
        print("⚠️  \(event.title)：\(event.body)")
        fflush(stdout)
    }
    print("硬盘监控测试：\(windowMinutes) 分钟内少 \(thresholdGB) GB 即提醒，运行 \(Int(seconds)) 秒")
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if let status = watcher.observe() {
            print("可用 \(formatSize(status.free))　窗口内减少 \(formatSize(status.drop))")
            fflush(stdout)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(5))
    }
}

/// `--folder-growth-selftest`: builds a temp folder tree, scans it twice around a 300 MB write
/// deep inside, and checks that the growth is reported at the deepest folder that explains it.
func runFolderGrowthSelfTest() -> Bool {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("loadlens-growth-\(UUID().uuidString)").path
    defer { try? fm.removeItem(atPath: root) }

    func write(_ relative: String, megabytes: Int) {
        let path = root + "/" + relative
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        let chunk = Data((0..<1_048_576).map { _ in UInt8.random(in: 0...255) })
        for _ in 0..<megabytes { handle.write(chunk) }
        try? handle.close()
    }

    write("a/old.bin", megabytes: 80)
    write("x/other.bin", megabytes: 60)
    // An unreadable folder, like the privacy-protected ones in a real home folder.
    let locked = root + "/a/locked"
    try? fm.createDirectory(atPath: locked + "/inner", withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
    let before = FolderGrowthTracker.scan(root: root, minBytes: 50_000_000)
    let backdated = FolderSnapshot(date: Date().addingTimeInterval(-3 * 86_400), total: before.total,
                                   folders: before.folders, skipped: before.skipped)

    write("a/b/c/d/new.bin", megabytes: 300)
    write("x/more.bin", megabytes: 20)
    let after = FolderGrowthTracker.scan(root: root, minBytes: 50_000_000)

    var rules = FolderGrowthSettings()
    rules.enabled = true
    rules.thresholdGB = 0.25
    let growth = FolderGrowthTracker.growth(current: after, history: [backdated, after],
                                            rules: rules, minimum: rules.thresholdBytes)
    print("before: \(before.folders.mapValues(formatSize))")
    print("after:  \(after.folders.mapValues(formatSize))")
    for item in growth { print("growth: \(item.displayPath) +\(formatSize(item.grown))") }

    let alerted = FolderGrowthTracker.alerts(in: growth, alerted: [:], rules: rules)
    let again = FolderGrowthTracker.alerts(in: growth, alerted: Dictionary(uniqueKeysWithValues: alerted.map { ($0.path, $0.size) }),
                                           rules: rules)
    print("notification: \(FolderGrowthTracker.title(for: alerted))：\(FolderGrowthTracker.body(for: alerted, rules: rules))")

    // "a" must still be measured as a whole (80 + 300 MB) despite the locked folder inside it.
    let aSize = after.folders["a"] ?? 0
    print("skipped: \(after.skipped)  a=\(formatSize(aSize))")
    let passed = growth.map(\.path) == ["a/b/c/d"] && alerted.count == 1 && again.isEmpty
        && after.skipped == ["a/locked"] && aSize >= 380 * 1_048_576
    print(passed ? "PASS" : "FAIL")
    return passed
}

/// `--folder-scan`: scans the real home folder once (nothing is saved) and prints what it found.
func runFolderScan() {
    let snapshot = FolderGrowthTracker.scan(root: NSHomeDirectory())
    print("用时 \(String(format: "%.1f", snapshot.duration)) 秒，共 \(formatSize(snapshot.total))，记录 \(snapshot.folders.count) 个文件夹")
    for (path, size) in snapshot.folders.sorted(by: { $0.value > $1.value }).prefix(15) {
        print("  \(formatSize(size))\t~/\(path)")
    }
    if !snapshot.skipped.isEmpty {
        print("无权访问：" + snapshot.skipped.prefix(10).map { "~/" + $0 }.joined(separator: "、"))
    }
}

/// `--llm-test <model.gguf>`: loads a local model and runs three small experiments that show
/// prefix reuse in the KV cache, prefill vs decode speed, and what sampling settings change.
func runLocalModelTest(path: String) {
    func show(_ title: String, _ result: (text: String, stats: LocalModel.Stats)) {
        let s = result.stats
        print("── \(title)")
        print("回答：\(result.text.trimmingCharacters(in: .whitespacesAndNewlines))")
        print(String(format: "提示 %d 词元（复用缓存 %d）· 读题 %.0f ms（%.0f 词元/秒）· 生成 %d 词元 %.0f ms（%.1f 词元/秒）",
                     s.promptTokens, s.reusedTokens, s.prefillSeconds * 1000, s.prefillTokensPerSecond,
                     s.generatedTokens, s.decodeSeconds * 1000, s.decodeTokensPerSecond))
        fflush(stdout)
    }

    do {
        let loadStart = Date()
        let model = try LocalModel(path: path)
        print("模型：\(model.description)，加载 \(Int(Date().timeIntervalSince(loadStart) * 1000)) ms，上下文 \(model.contextLength) 词元")

        // A long, fixed system prompt (the "不易" part) and short, changing questions ("变易").
        let system = "你是 Mac 硬盘助手。用一句简短的中文回答。背景知识：" + String(repeating:
            "~/Library/Caches 是应用缓存，删除后会自动重建；DerivedData 是 Xcode 编译缓存；Docker 的虚拟磁盘会只增不减。", count: 8)
        let first = try model.chatPrompt([("system", system), ("user", "Docker 的数据为什么越来越大？")])
        let second = try model.chatPrompt([("system", system), ("user", "应用缓存可以删吗？")])

        show("实验 1：冷启动（KV 缓存是空的）", try model.generate(prompt: first, maxTokens: 60, sampling: .greedy))
        show("实验 2：同一段背景、换个问题（背景部分直接复用）", try model.generate(prompt: second, maxTokens: 60, sampling: .greedy))
        model.clearCache()
        show("实验 2 对照：清空缓存后问同一个问题", try model.generate(prompt: second, maxTokens: 60, sampling: .greedy))

        let creative = try model.chatPrompt([("user", "用一句话形容硬盘快满了的感觉。")])
        for seed: UInt32 in [1, 2] {
            show("实验 3：温度 0（贪心），seed \(seed)", try model.generate(prompt: creative, maxTokens: 40,
                                                                    sampling: .init(temperature: 0, seed: seed)))
        }
        for seed: UInt32 in [1, 2] {
            show("实验 3：温度 1.2，seed \(seed)", try model.generate(prompt: creative, maxTokens: 40,
                                                                sampling: .init(temperature: 1.2, seed: seed)))
        }
    } catch {
        print("失败：\(error.localizedDescription)")
    }
}
