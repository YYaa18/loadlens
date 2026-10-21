import SwiftUI

struct LoadLensApp: App {
    @ObservedObject private var monitor = Monitor.shared

    init() {
        Notifier.shared.prepare()
        Monitor.shared.start()

        if CommandLine.arguments.contains("--ai-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                AIChatWindowController.shared.show(anchor: nil, openSettings: false, autoAnalyze: true)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: monitor)
        } label: {
            Image(nsImage: MenuBarIcon.gauge(cpu: monitor.snapshot.cpu,
                                             hot: monitor.diagnosis.level == .hot))
            Text(monitor.menuTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
