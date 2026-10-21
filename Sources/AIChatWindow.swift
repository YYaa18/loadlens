import AppKit
import SwiftUI

final class AIChatWindowController: NSObject, NSWindowDelegate {
    static let shared = AIChatWindowController()
    private var window: NSWindow?
    private let defaultSize = NSSize(width: 420, height: 600)

    /// Opens the chat window.
    /// - Parameters:
    ///   - anchor: frame of the menu bar panel the user clicked from; the window opens in its place
    ///     so it feels attached to the menu bar instead of jumping to the middle of the screen.
    ///   - openSettings: jump straight to the API key page.
    ///   - autoAnalyze: start an overview analysis when the conversation is empty.
    func show(anchor: NSRect? = nil, openSettings: Bool = false, autoAnalyze: Bool = false) {
        let chat = AIChat.shared
        let isNew = window == nil || window?.isVisible == false

        if window == nil {
            let hosting = NSHostingView(rootView: AIChatView(chat: chat))
            let newWindow = NSWindow(contentRect: NSRect(origin: .zero, size: defaultSize),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered,
                                     defer: false)
            newWindow.title = "AI 诊断助手"
            newWindow.titleVisibility = .hidden
            newWindow.titlebarAppearsTransparent = true
            newWindow.isMovableByWindowBackground = true
            // An empty unified toolbar makes the title bar 52pt tall so the traffic lights
            // line up with our custom header.
            newWindow.toolbar = NSToolbar(identifier: "loadlens.ai")
            newWindow.toolbarStyle = .unified
            newWindow.titlebarSeparatorStyle = .none
            newWindow.contentView = hosting
            newWindow.isReleasedWhenClosed = false
            newWindow.minSize = NSSize(width: 380, height: 460)
            newWindow.delegate = self
            newWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window = newWindow
        }

        guard let window else { return }
        if isNew { position(window, anchor: anchor) }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        chat.refreshKeyState()
        if openSettings {
            chat.settingsOpen = true
        } else if autoAnalyze {
            chat.startIfEmpty()
        }

        if ProcessInfo.processInfo.environment["LOADLENS_AI_MOCK"] == "1"
            || CommandLine.arguments.contains("--ai-preview") {
            print("ai-window-number \(window.windowNumber)")
            fflush(stdout)
        }
    }

    private func position(_ window: NSWindow, anchor: NSRect?) {
        let screen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }

        let size = window.frame.size
        let margin: CGFloat = 8
        var origin: NSPoint
        if let anchor {
            // Same top edge as the panel, right edges aligned.
            origin = NSPoint(x: anchor.maxX - size.width, y: anchor.maxY - size.height)
        } else {
            // Top-right corner, just under the menu bar where the status item lives.
            origin = NSPoint(x: visible.maxX - size.width - margin * 2, y: visible.maxY - size.height - margin)
        }
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - size.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - size.height - margin)
        window.setFrameOrigin(origin)
    }

    func windowWillClose(_ notification: Notification) {
        AIChat.shared.cancel()
    }
}
