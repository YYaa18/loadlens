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

/// `--triage-eval <model.gguf> [cases.json] [--prompt v1|v2] [--reason-first] [--no-grammar]`:
/// runs every exam case through `Triage.judge` and scores it against the reviewed answers.
func runTriageEval(modelPath: String, casesPath: String, options: Triage.Options) -> Bool {
    struct Case: Decodable {
        let id: String
        let facts: DiskEventFacts
        let expect_notify: Bool
        /// Expected category (only in the generated test set).
        let category: String?
    }
    struct Exam: Decodable { let cases: [Case] }

    guard let data = FileManager.default.contents(atPath: casesPath),
          let exam = try? JSONDecoder().decode(Exam.self, from: data) else {
        print("读不到考题：\(casesPath)")
        return false
    }
    let modeText = options.mode == .category
        ? "模型判断类别，代码决定提醒"
        : "模型直接判断 · 提示词 \(options.prompt.rawValue) · \(options.reasonFirst ? "先理由后结论" : "先结论后理由")"
    print("设置：\(modeText) · \(options.useGrammar ? "语法约束" : "无约束")")

    do {
        let model = try LocalModel(path: modelPath)
        print("模型：\(model.description)\n")
        var correct = 0, misses = 0, falseAlarms = 0, unparsed = 0
        var categoryCases = 0, categoryCorrect = 0
        var times: [Double] = []

        for item in exam.cases {
            let start = Date()
            let verdict = try Triage.judge(item.facts, model: model, options: options)
            let ms = Date().timeIntervalSince(start) * 1000
            if !verdict.byRule { times.append(ms) }
            if !verdict.parsed { unparsed += 1 }

            var categoryMark = ""
            if let expected = item.category, options.mode == .category, !verdict.byRule {
                categoryCases += 1
                if verdict.category?.rawValue == expected { categoryCorrect += 1 } else { categoryMark = " （应为 \(expected)）" }
            }
            let right = verdict.notify == item.expect_notify
            if right { correct += 1 } else if item.expect_notify { misses += 1 } else { falseAlarms += 1 }

            let mark = right ? "✓" : "✗"
            let got = verdict.notify ? "提醒" : "不打扰"
            let source = verdict.byRule ? "规则" : String(format: "%4.0fms", ms)
            let category = verdict.category.map { "[\($0.rawValue)] " } ?? ""
            let detail = verdict.parsed ? category + verdict.reason : "（读不懂输出）\(verdict.raw.prefix(60))"
            print("\(mark) \(item.id) \(got)\t\(source)  \(detail)\(categoryMark)")
            fflush(stdout)
        }

        let total = exam.cases.count
        let average = times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count)
        print("")
        print("答对 \(correct)/\(total)（\(Int(Double(correct) / Double(total) * 100))%）· 漏报 \(misses) · 误报 \(falseAlarms) · 输出读不懂 \(unparsed)")
        if categoryCases > 0 {
            print("类别答对 \(categoryCorrect)/\(categoryCases)（\(Int(Double(categoryCorrect) / Double(categoryCases) * 100))%）")
        }
        print(String(format: "模型判断平均 %.0f ms，最慢 %.0f ms", average, times.max() ?? 0))
        return true
    } catch {
        print("失败：\(error.localizedDescription)")
        return false
    }
}

/// `--triage-export <facts.jsonl> <out.jsonl>`: turns generated training facts into chat examples
/// using the app's own prompt and description code, so training sees exactly what the app sends.
func runTriageExport(input: String, output: String) -> Bool {
    struct Row: Decodable {
        let facts: DiskEventFacts
        let category: String
        let reason: String
    }
    guard let text = try? String(contentsOfFile: input, encoding: .utf8) else {
        print("读不到：\(input)")
        return false
    }
    var lines: [String] = []
    for line in text.split(separator: "\n") where !line.isEmpty {
        guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)),
              Triage.Category(rawValue: row.category) != nil else {
            print("格式不对：\(line.prefix(80))")
            return false
        }
        // Same shape the grammar allows: {"category": "...", "reason": "..."}
        let reason = row.reason.replacingOccurrences(of: "\"", with: "'")
        let answer = "{\"category\": \"\(row.category)\", \"reason\": \"\(reason)\"}"
        let example: [String: Any] = ["messages": [
            ["role": "system", "content": Triage.categoryPrompt],
            ["role": "user", "content": row.facts.description],
            ["role": "assistant", "content": answer]
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: example, options: [.withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return false }
        lines.append(json)
    }
    do {
        try (lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
        print("\(lines.count) 条 → \(output)")
        return true
    } catch {
        print("写入失败：\(error.localizedDescription)")
        return false
    }
}

/// `--embed-export <model.gguf> <input> <out.jsonl> [--pooling mean|last]`: writes one vector per
/// example, from either generated facts (.jsonl) or an exam file (.json with "cases").
func runEmbedExport(modelPath: String, input: String, output: String, pooling: EmbeddingModel.Pooling,
                    instruction: String = "", lowercase: Bool = false, namesOnly: Bool = false) -> Bool {
    struct Item {
        let id: String
        let facts: DiskEventFacts
        let category: String?
        let expectNotify: Bool?
    }
    struct Row: Decodable { let facts: DiskEventFacts; let category: String }
    struct Case: Decodable { let id: String; let facts: DiskEventFacts; let category: String?; let expect_notify: Bool }
    struct Exam: Decodable { let cases: [Case] }

    var items: [Item] = []
    if input.hasSuffix(".json") {
        guard let data = FileManager.default.contents(atPath: input),
              let exam = try? JSONDecoder().decode(Exam.self, from: data) else { print("读不到：\(input)"); return false }
        items = exam.cases.map { Item(id: $0.id, facts: $0.facts, category: $0.category, expectNotify: $0.expect_notify) }
    } else {
        guard let text = try? String(contentsOfFile: input, encoding: .utf8) else { print("读不到：\(input)"); return false }
        for (n, line) in text.split(separator: "\n").enumerated() where !line.isEmpty {
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)) else { print("格式不对：第 \(n + 1) 行"); return false }
            items.append(Item(id: "\(n)", facts: row.facts, category: row.category, expectNotify: nil))
        }
    }

    do {
        let start = Date()
        let embedder = try EmbeddingModel(path: modelPath, pooling: pooling)
        var lines: [String] = []
        for item in items {
            let text = instruction + (namesOnly ? item.facts.names : item.facts.description)
            var row: [String: Any] = ["id": item.id, "embedding": try embedder.embed(lowercase ? text.lowercased() : text)]
            if let category = item.category { row["category"] = category }
            if let expect = item.expectNotify { row["expect_notify"] = expect }
            let data = try JSONSerialization.data(withJSONObject: row)
            lines.append(String(decoding: data, as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
        let seconds = Date().timeIntervalSince(start)
        print("\(items.count) 条，\(embedder.dimensions) 维，\(pooling.rawValue) 池化，用时 \(String(format: "%.1f", seconds)) 秒 → \(output)")
        return true
    } catch {
        print("失败：\(error.localizedDescription)")
        return false
    }
}

/// `--probe-eval <model.gguf> <probe.json> [cases.json]`: scores the Jev-style decision model and
/// shows what confidence thresholds buy: decide locally when sure, fall back (notify) otherwise.
func runProbeEval(modelPath: String, probePath: String, casesPath: String) -> Bool {
    struct Case: Decodable { let id: String; let facts: DiskEventFacts; let expect_notify: Bool; let category: String? }
    struct Exam: Decodable { let cases: [Case] }
    guard let data = FileManager.default.contents(atPath: casesPath),
          let exam = try? JSONDecoder().decode(Exam.self, from: data) else { print("读不到考题：\(casesPath)"); return false }

    do {
        let loadStart = Date()
        let model = try DecisionModel(probePath: probePath, modelPath: modelPath)
        print("决策模型：\(model.probe.pooling.rawValue) 池化 · 加载 \(Int(Date().timeIntervalSince(loadStart) * 1000)) ms\n")

        struct Result { let right: Bool; let expect: Bool; let confidence: Double; let categoryRight: Bool? }
        var results: [Result] = []
        var times: [Double] = []
        for item in exam.cases {
            if let reason = Triage.hardRule(item.facts) {
                print("✓ \(item.id) 提醒\t规则  \(reason)")
                results.append(Result(right: item.expect_notify, expect: item.expect_notify, confidence: 1, categoryRight: nil))
                continue
            }
            let start = Date()
            let decision = try model.decide(item.facts)
            times.append(Date().timeIntervalSince(start) * 1000)
            let notify = decision.category.notify
            let right = notify == item.expect_notify
            let categoryRight = item.category.map { $0 == decision.category.rawValue }
            results.append(Result(right: right, expect: item.expect_notify, confidence: decision.confidence, categoryRight: categoryRight))
            let second = decision.probabilities.count > 1 ? decision.probabilities[1] : decision.probabilities[0]
            let wrongCategory = (categoryRight == false) ? "（应为 \(item.category!)）" : ""
            print(String(format: "%@ %@ %@\t%3.0fms  %@ %.0f%%，其次 %@ %.0f%% · 提醒概率 %.0f%%%@",
                         right ? "✓" : "✗", item.id, notify ? "提醒" : "不打扰", times.last!,
                         decision.category.rawValue, decision.confidence * 100,
                         second.category.rawValue, second.probability * 100, decision.notifyProbability * 100, wrongCategory))
        }

        let n = Double(results.count)
        let correct = results.filter(\.right).count
        let misses = results.filter { !$0.right && $0.expect }.count
        let labelled = results.compactMap(\.categoryRight)
        print("")
        print("全部本地决定：答对 \(correct)/\(results.count)（\(Int(Double(correct) / n * 100))%）· 漏报 \(misses)"
              + (labelled.isEmpty ? "" : " · 类别 \(labelled.filter { $0 }.count)/\(labelled.count)"))
        print(String(format: "每次决定平均 %.0f ms，最慢 %.0f ms", times.reduce(0, +) / Double(max(times.count, 1)), times.max() ?? 0))
        print("\n置信度门槛（低于门槛就保守地提醒，或交给云端）：")
        for threshold in [0.5, 0.7, 0.8, 0.9, 0.95] {
            let sure = results.filter { $0.confidence >= threshold }
            let sureRight = sure.filter(\.right).count
            // Fallback = notify: right when the case expected a notification.
            let fallbackRight = results.filter { $0.confidence < threshold && $0.expect }.count
            let overallMisses = sure.filter { !$0.right && $0.expect }.count
            print(String(format: "  ≥%.0f%%：本地决定 %d 条（%.0f%%），其中答对 %.0f%% · 加上兜底总体答对 %.0f%% · 漏报 %d",
                         threshold * 100, sure.count, Double(sure.count) / n * 100,
                         sure.isEmpty ? 0 : Double(sureRight) / Double(sure.count) * 100,
                         Double(sureRight + fallbackRight) / n * 100, overallMisses))
        }
        return true
    } catch {
        print("失败：\(error.localizedDescription)")
        return false
    }
}

/// `--embed-text <model.gguf> <mean|last|cls> <text>…`: one JSON vector per text (developer check).
/// A function, so the model is released before the process exits (llama.cpp's GPU cleanup asserts
/// if a model is still loaded at exit).
func runEmbedText(modelPath: String, pooling: EmbeddingModel.Pooling, texts: [String]) -> Bool {
    do {
        let model = try EmbeddingModel(path: modelPath, pooling: pooling)
        for text in texts {
            let data = try JSONSerialization.data(withJSONObject: try model.embed(text))
            print(String(decoding: data, as: UTF8.self))
        }
        return true
    } catch {
        print("失败：\(error.localizedDescription)")
        return false
    }
}

/// `--hybrid-eval <model.gguf> <probe.json> <cases.json> [--passes N] [--threshold T] [--no-cloud]`
/// Runs the five-layer decision over the cases (in order, N times) with a simulated cloud that
/// always answers correctly, and a throwaway memory file. Nothing is sent anywhere.
func runHybridEval(modelPath: String, probePath: String, casesPath: String, passes: Int, threshold: Double,
                   useCloud: Bool) -> Bool {
    struct Case: Decodable { let id: String; let facts: DiskEventFacts; let expect_notify: Bool; let category: String? }
    struct Exam: Decodable { let cases: [Case] }
    guard let data = FileManager.default.contents(atPath: casesPath),
          let exam = try? JSONDecoder().decode(Exam.self, from: data) else { print("读不到考题：\(casesPath)"); return false }

    /// The simulated cloud: knows the right answer (category if given, else any notify-consistent one).
    final class OracleCloud: CloudJudge {
        var answers: [String: Triage.Category] = [:]
        var calls = 0
        func category(for facts: DiskEventFacts) async throws -> Triage.Category {
            calls += 1
            guard let category = answers[facts.description] else { throw LocalModel.LocalModelError.tokenizeFailed }
            return category
        }
    }

    do {
        let local = try DecisionModel(probePath: probePath, modelPath: modelPath)
        let memoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("loadlens-memory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: memoryURL) }
        let cloud = OracleCloud()
        for item in exam.cases {
            cloud.answers[item.facts.description] = item.category.flatMap(Triage.Category.init(rawValue:))
                ?? (item.expect_notify ? .unknown : .userActivity)
        }
        let triage = HybridTriage(local: local, memory: AnswerMemory(url: memoryURL),
                                  cloud: useCloud ? cloud : nil, threshold: threshold)
        print("门槛 \(Int(threshold * 100))% · \(useCloud ? "模拟云端（总是答对）" : "不联网")\n")

        for pass in 1...max(passes, 1) {
            var sources: [HybridTriage.Source: Int] = [:]
            var correct = 0, misses = 0, falseAlarms = 0
            var times: [Double] = []
            let callsBefore = cloud.calls
            for item in exam.cases {
                let start = Date()
                var result: HybridTriage.Result?
                let semaphore = DispatchSemaphore(value: 0)
                Task { result = await triage.decide(item.facts); semaphore.signal() }
                while semaphore.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
                times.append(Date().timeIntervalSince(start) * 1000)
                guard let result else { continue }
                sources[result.source, default: 0] += 1
                if result.notify == item.expect_notify { correct += 1 } else if item.expect_notify { misses += 1 } else { falseAlarms += 1 }
            }
            let n = exam.cases.count
            let order: [HybridTriage.Source] = [.rule, .memory, .local, .cloud, .fallback]
            let breakdown = order.compactMap { s in sources[s].map { "\(s.rawValue) \($0)（\(Int(Double($0) / Double(n) * 100))%）" } }
            print("第 \(pass) 遍：" + breakdown.joined(separator: " · "))
            print("  答对 \(correct)/\(n)（\(Int(Double(correct) / Double(n) * 100))%）· 漏报 \(misses) · 误报 \(falseAlarms) · 云端调用 \(cloud.calls - callsBefore) 次"
                  + String(format: " · 平均 %.1f ms", times.reduce(0, +) / Double(max(times.count, 1))))
        }
        print("\n记住了 \(triage.memory.entries.count) 个名字")
        return true
    } catch {
        print("失败：\(error.localizedDescription)")
        return false
    }
}

/// `--cloud-eval <cases.json>`: asks the configured cloud model about one case per distinct name
/// and scores it. Sends only the event descriptions in that file (meant for synthetic test data).
func runCloudEval(casesPath: String) -> Bool {
    struct Case: Decodable { let id: String; let facts: DiskEventFacts; let expect_notify: Bool; let category: String? }
    struct Exam: Decodable { let cases: [Case] }
    guard let data = FileManager.default.contents(atPath: casesPath),
          let exam = try? JSONDecoder().decode(Exam.self, from: data) else { print("读不到考题：\(casesPath)"); return false }

    var seen = Set<String>()
    let cases = exam.cases.filter { $0.category != nil && seen.insert($0.facts.names).inserted }
    let endpoint = AIConfigStore.shared.endpoint()
    print("云端：\(endpoint.preset.name) · \(endpoint.model) · \(cases.count) 条（每个名字一条）\n")

    struct Outcome { let item: Case; let got: Triage.Category?; let error: String?; let ms: Double }
    var outcomes: [Outcome] = []
    var finished = false
    Task {
        let judge = LLMCloudJudge()
        // A few at a time, to be quick without hammering the service.
        await withTaskGroup(of: Outcome.self) { group in
            var next = 0
            func add() {
                guard next < cases.count else { return }
                let item = cases[next]; next += 1
                group.addTask {
                    let start = Date()
                    do {
                        let got = try await judge.category(for: item.facts)
                        return Outcome(item: item, got: got, error: nil, ms: Date().timeIntervalSince(start) * 1000)
                    } catch {
                        return Outcome(item: item, got: nil, error: error.localizedDescription, ms: Date().timeIntervalSince(start) * 1000)
                    }
                }
            }
            for _ in 0..<4 { add() }
            for await outcome in group { outcomes.append(outcome); add() }
        }
        finished = true
    }
    while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    var right = 0, notifyRight = 0, failed = 0, misses = 0
    var confusion: [String: Int] = [:]
    for o in outcomes.sorted(by: { $0.item.id < $1.item.id }) {
        guard let got = o.got else {
            failed += 1
            print("！\(o.item.id) 调用失败：\(o.error ?? "")")
            continue
        }
        let expected = o.item.category!
        if got.rawValue == expected { right += 1 } else {
            confusion["\(expected) → \(got.rawValue)", default: 0] += 1
            print("✗ \(o.item.id) \(o.item.facts.names) 判成 \(got.rawValue)（应为 \(expected)）")
        }
        if got.notify == o.item.expect_notify { notifyRight += 1 } else if o.item.expect_notify { misses += 1 }
    }
    let answered = outcomes.count - failed
    let times = outcomes.map(\.ms).sorted()
    print("")
    print("类别答对 \(right)/\(answered)（\(answered > 0 ? right * 100 / answered : 0)%）· 提醒判断对 \(notifyRight)/\(answered) · 漏报 \(misses) · 调用失败 \(failed)")
    if !times.isEmpty {
        print(String(format: "耗时：中位数 %.0f ms，最慢 %.0f ms", times[times.count / 2], times.last!))
    }
    for (pair, count) in confusion.sorted(by: { $0.value > $1.value }).prefix(6) { print("  \(pair)：\(count)") }
    return failed < outcomes.count
}

/// `--triage-check`: judges a few typical events with the model bundled in the app (no notifications).
func runTriageCheck() -> Bool {
    typealias W = DiskEventFacts.Writer
    let samples: [(String, DiskEventFacts)] = [
        ("dd 狂写", DiskEventFacts(minutes: 1, drop_gb: 2.1, writers: [W(app: "dd", process: "dd", gb: 2.0)], free_gb: 250, total_gb: 494)),
        ("Firefox 下载", DiskEventFacts(minutes: 10, drop_gb: 5, writers: [W(app: "Firefox", process: "firefox", gb: 5)], free_gb: 200, total_gb: 494)),
        ("看不到写入者", DiskEventFacts(minutes: 10, drop_gb: 6, writers: [], free_gb: 200, total_gb: 494)),
        ("pip 缓存变大", DiskEventFacts(days: 7, path: "~/Library/Caches/pip", owner: "pip", grown_gb: 6, size_gb: 9, free_gb: 200, total_gb: 494)),
        ("文稿变大", DiskEventFacts(days: 7, path: "~/Documents", owner: nil, grown_gb: 8, size_gb: 30, free_gb: 200, total_gb: 494)),
        ("快满了", DiskEventFacts(minutes: 10, drop_gb: 5, writers: [W(app: "Firefox", process: "firefox", gb: 5)], free_gb: 9, total_gb: 494)),
    ]
    var loaded = true
    let before = physicalFootprint()
    for (title, facts) in samples {
        let start = Date()
        guard let result = TriageService.shared.checkLocally(facts) else {
            print("✗ \(title)：本地没把握（会去问云端或兜底提醒）")
            continue
        }
        let ms = Date().timeIntervalSince(start) * 1000
        let category = result.category?.rawValue ?? "-"
        let confidence = result.localConfidence.map { " \(Int($0 * 100))%" } ?? ""
        print(String(format: "%@ %@：%@ · %@%@ · %.0f ms", result.notify ? "🔔" : "🔕", title, category,
                     result.source.rawValue, confidence, ms))
        if result.source == .fallback { loaded = false }
    }
    print(String(format: "本进程内存：开始 %.1f MB，判断完 %.1f MB（模型在子进程里运行）", before, physicalFootprint()))
    return loaded
}

/// This process's memory as Activity Monitor shows it ("memory footprint"), in MB.
func physicalFootprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

/// `--triage-judge`: the helper process. Reads one event (JSON) on stdin, writes
/// {"category": ..., "confidence": ...} on stdout, then exits, giving all its memory back.
func runTriageJudge() -> Bool {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let facts = try? JSONDecoder().decode(DiskEventFacts.self, from: input) else { return false }
    // A function scope, so the model is freed before the process exits (llama.cpp asserts otherwise).
    func answer() -> Data? {
        guard let model = try? TriageService.loadBundledModel(), let result = try? model.judge(facts) else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["category": result.category.rawValue,
                                                            "confidence": result.confidence])
    }
    guard let data = answer() else { return false }
    FileHandle.standardOutput.write(data)
    return true
}

/// `--memory-selftest`: a user correction must survive a restart and win over the model.
func runMemorySelfTest() -> Bool {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("loadlens-memtest-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let facts = DiskEventFacts(minutes: 1, drop_gb: 2, writers: [.init(app: "perl", process: "perl", gb: 2)],
                               free_gb: 250, total_gb: 494)
    guard let key = AnswerMemory.key(for: facts) else { print("FAIL: no key"); return false }

    // Before: the model says "script" → notify.
    let before = HybridTriage(local: HelperProcessJudge(), memory: AnswerMemory(url: url), cloud: nil).decideLocally(facts).result
    // The user taps "这类不用提醒".
    AnswerMemory(url: url).correct(key: key, notify: false)
    // A cloud answer later must not overwrite the user's call.
    AnswerMemory(url: url).remember(facts, category: .unknown, source: "cloud")
    // "Restart": a fresh memory read from disk.
    let after = HybridTriage(local: HelperProcessJudge(), memory: AnswerMemory(url: url), cloud: nil).decideLocally(facts).result

    print("纠正前：\(before?.notify == true ? "提醒" : "不提醒")（\(before?.source.rawValue ?? "-")）")
    print("纠正并重新读取后：\(after?.notify == true ? "提醒" : "不提醒")（\(after?.source.rawValue ?? "-")）")
    print("文件：\(FileManager.default.fileExists(atPath: url.path) ? "已保存" : "不存在")")
    let passed = before?.notify == true && after?.notify == false && after?.source == .memory
    print(passed ? "PASS" : "FAIL")
    return passed
}
