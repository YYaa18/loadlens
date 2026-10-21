import SwiftUI

struct LoadLensApp: App {
    @ObservedObject private var monitor = Monitor.shared

    init() {
        Notifier.shared.prepare()
        Monitor.shared.start()

        if CommandLine.arguments.contains("--ai-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                AIChatWindowController.shared.show()
                AIChat.shared.analyzeCurrentState()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(monitor: monitor)
        } label: {
            Text(monitor.menuTitle)
        }
        .menuBarExtraStyle(.window)
    }
}
