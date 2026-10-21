import AppKit
import SwiftUI

final class AIChatWindowController {
    static let shared = AIChatWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = AIChatView(chat: AIChat.shared)
            let hosting = NSHostingView(rootView: view)
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                     backing: .buffered,
                                     defer: false)
            newWindow.title = "AI 分析 · 负载侦探"
            newWindow.contentView = hosting
            newWindow.isReleasedWhenClosed = false
            newWindow.minSize = NSSize(width: 420, height: 500)
            newWindow.center()
            window = newWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        AIChat.shared.refreshKeyState()

        if ProcessInfo.processInfo.environment["LOADLENS_AI_MOCK"] == "1"
            || CommandLine.arguments.contains("--ai-preview") {
            print("ai-window-number \(window?.windowNumber ?? 0)")
            fflush(stdout)
        }
    }
}
