import AppKit
import SwiftUI

/// Shows the AI chat as a pane attached to the menu bar panel, on whichever side has room.
///
/// The panel is one window: opening the pane widens it. We remember where the main panel sat
/// under the menu bar icon and keep it there, so the window grows toward the free side
/// instead of sliding the main content around.
final class AIDock: ObservableObject {
    static let shared = AIDock()
    static let paneWidth: CGFloat = 400

    enum Side { case left, right }

    @Published private(set) var isOpen = false
    @Published private(set) var side: Side = .right

    private weak var window: NSWindow?
    private var mainMinX: CGFloat?
    private var top: CGFloat?
    private var observers: [NSObjectProtocol] = []
    private var adjusting = false

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        self.window = window
        observers = [NSWindow.didResizeNotification, NSWindow.didMoveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.keepInPlace()
            }
        }
    }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard !isOpen else { return }
        if let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            let frame = window.frame
            mainMinX = frame.minX
            top = frame.maxY
            let needed = Self.paneWidth + 8
            let roomRight = visible.maxX - frame.maxX
            let roomLeft = frame.minX - visible.minX
            if ProcessInfo.processInfo.environment["LOADLENS_DOCK_SIDE"] == "left" {
                side = .left   // test hook
            } else if roomRight >= needed {
                side = .right
            } else if roomLeft >= needed {
                side = .left
            } else {
                side = roomRight >= roomLeft ? .right : .left
            }
        }
        isOpen = true
        settle()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        settle()
    }

    /// The menu bar panel went away; start fresh next time.
    func panelClosed() {
        isOpen = false
        mainMinX = nil
        top = nil
    }

    /// SwiftUI resizes the window a moment after the content changes; re-check a few times.
    private func settle() {
        for delay in [0.0, 0.05, 0.15, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.keepInPlace()
            }
        }
    }

    private func keepInPlace() {
        guard !adjusting, let window, let mainMinX, let top else { return }
        let width = window.frame.width
        var x = (isOpen && side == .left) ? mainMinX - (width - panelWidth) : mainMinX
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + 4), visible.maxX - width - 4)
        }
        guard abs(window.frame.minX - x) > 0.5 || abs(window.frame.maxY - top) > 0.5 else { return }
        adjusting = true
        window.setFrameTopLeftPoint(NSPoint(x: x, y: top))
        adjusting = false
    }
}

/// Hands back the NSWindow that hosts a SwiftUI view.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
    }
}

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
