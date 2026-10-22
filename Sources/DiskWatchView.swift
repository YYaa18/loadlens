import SwiftUI
import AppKit

final class DiskWatchWindowController: NSObject, NSWindowDelegate {
    static let shared = DiskWatchWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: DiskWatchSettingsView(watcher: .shared))
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),
                                     styleMask: [.titled, .closable, .miniaturizable],
                                     backing: .buffered,
                                     defer: false)
            newWindow.title = "硬盘空间监控"
            newWindow.contentView = hosting
            newWindow.isReleasedWhenClosed = false
            newWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct DiskWatchSettingsView: View {
    @ObservedObject var watcher: DiskGrowthWatcher
    @State private var notificationsDenied = false

    private let windowChoices = [1, 5, 10, 30, 60]
    private let cooldownChoices = [10, 30, 60, 120]

    var body: some View {
        Form {
            Section {
                Toggle("硬盘空间快速减少时提醒我", isOn: enabledBinding)
                if notificationsDenied {
                    Text("没有通知权限，提醒只会记在下面。可以在「系统设置 → 通知 → 负载侦探」里打开。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("只看启动盘剩余空间和各程序写了多少数据，不读取任何文件内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("提醒规则") {
                Picker("在多长时间内", selection: $watcher.settings.windowMinutes) {
                    ForEach(windowChoices, id: \.self) { Text("\($0) 分钟").tag($0) }
                }
                Stepper(value: $watcher.settings.thresholdGB, in: 1...200, step: 1) {
                    Text("空间减少超过 \(Int(watcher.settings.thresholdGB)) GB")
                }
                Picker("提醒后安静多久", selection: $watcher.settings.cooldownMinutes) {
                    ForEach(cooldownChoices, id: \.self) { Text("\($0) 分钟").tag($0) }
                }
                Text(ruleSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!watcher.settings.enabled)

            Section("最近的提醒") {
                if watcher.recentEvents.isEmpty {
                    Text("还没有。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(watcher.recentEvents) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(event.body)
                                .font(.callout)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 460)
    }

    private var ruleSummary: String {
        let s = watcher.settings
        return "当 \(s.windowMinutes) 分钟内少了 \(Int(s.thresholdGB)) GB 以上时提醒，之后 \(s.cooldownMinutes) 分钟内不再重复。"
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { watcher.settings.enabled },
            set: { isOn in
                watcher.settings.enabled = isOn
                notificationsDenied = false
                guard isOn else { return }
                Notifier.shared.requestAuthorization { granted in
                    notificationsDenied = !granted
                }
            }
        )
    }
}
