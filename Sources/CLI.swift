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

    let userSamples = tracker.scan()
    let systemSamples = readSystemProcesses()
    let merged = mergeSamples(primary: userSamples, secondary: systemSamples)
    snap.apps = aggregate(merged, excluding: [getpid()])

    let diag = Diagnoser.evaluate(snap)

    print("")
    print("负载侦探 · 本机体检")
    print(String(repeating: "─", count: 38))
    print("状态：\(diag.headline)")
    print(diag.detail)
    print("温度：\(diag.thermalLabel)　内存压力：\(diag.memoryLabel)")
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
    hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 620)

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
    window.setContentSize(NSSize(width: 400, height: min(max(fitting.height, 320), 820)))
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
        .frame(width: 400)
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
