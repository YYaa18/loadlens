import SwiftUI
import AppKit

final class DiskWatchWindowController: NSObject, NSWindowDelegate {
    static let shared = DiskWatchWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: DiskWatchSettingsView(watcher: .shared, folders: .shared, triage: .shared, ai: .shared))
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760),
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
    @ObservedObject var folders: FolderGrowthTracker
    @ObservedObject var triage: TriageService
    @ObservedObject var ai: AIConfigStore
    @State private var notificationsDenied = false

    private let windowChoices = [1, 5, 10, 30, 60]
    private let cooldownChoices = [10, 30, 60, 120]
    private let dayChoices = [3, 7, 14, 30]

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

            folderSection

            triageSection

            Section {
                if triage.records.isEmpty {
                    Text("还没有。触发提醒规则的事件都会列在这里，包括判断为不用打扰的。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(triage.records) { record in
                        recordRow(record)
                    }
                }
            } header: {
                Text("最近的判断")
            } footer: {
                Text("判断错了可以直接纠正，以后同一个程序或文件夹按你的意思来；硬盘快满的提醒不受影响。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 760)
    }

    @ViewBuilder
    private var folderSection: some View {
        Section {
            Toggle("文件夹持续变大时提醒我", isOn: folderEnabledBinding)
            Group {
                Picker("在多少天内", selection: $folders.settings.days) {
                    ForEach(dayChoices, id: \.self) { Text("\($0) 天").tag($0) }
                }
                Stepper(value: $folders.settings.thresholdGB, in: 1...200, step: 1) {
                    Text("某个文件夹涨了 \(Int(folders.settings.thresholdGB)) GB 以上")
                }
                HStack {
                    Text(scanStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if folders.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("现在扫描一次") { folders.scanNow() }
                    }
                }
            }
            .disabled(!folders.settings.enabled)
        } header: {
            Text("持续变大的文件夹")
        } footer: {
            Text("每天在电脑空闲时把家目录量一遍，只记文件夹大小，不读取文件内容。第一次扫描时 macOS 可能会询问能否访问桌面、文稿等文件夹，不允许的会跳过。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if folders.settings.enabled {
            Section("最近变大的文件夹") {
                if folders.latestGrowth.isEmpty {
                    Text(folders.snapshotCount < 2 ? "需要攒够至少一天的记录才能比较。" : "最近没有明显变大的文件夹。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(folders.latestGrowth) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("涨了 \(formatSize(item.grown))，现在 \(formatSize(item.size))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var triageSection: some View {
        Section {
            Toggle("先判断值不值得打扰我", isOn: $triage.settings.useLocal)
            Toggle(isOn: $triage.settings.askCloud) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("没把握时询问云端模型")
                    Text(ai.isReady ? "使用「AI 模型设置」里的 \(ai.activePreset.name)" : "需要先在「AI 模型设置」里配置模型服务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!ai.isReady)
        } header: {
            Text("智能判断")
        } footer: {
            Text("判断用的是内置的 25MB 小模型，在本机运行，不联网。询问云端时只发送程序名、文件夹路径和大小，不发送文件内容；问过的答案会记在本机，同一个名字不再重复询问。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func recordRow(_ record: TriageRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(record.notified ? "已提醒" : "未打扰")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(record.notified ? .orange : .secondary)
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                correctionControl(record)
            }
            Text(record.body)
                .font(.callout)
            Text(record.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func correctionControl(_ record: TriageRecord) -> some View {
        if let corrected = record.corrected {
            Text(corrected ? "已记住：以后提醒" : "已记住：以后不提醒")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if record.key != nil, record.source != .rule {
            Button(record.notified ? "这类不用提醒" : "这类应该提醒") {
                triage.correct(record.id, notify: !record.notified)
            }
            .controlSize(.small)
        }
    }

    private var scanStatus: String {
        if folders.isScanning { return "正在扫描，可能要一两分钟…" }
        guard let last = folders.lastSnapshot else { return "还没扫描过" }
        let when = last.date.formatted(date: .abbreviated, time: .shortened)
        let skipped = last.skipped.isEmpty ? "" : "，跳过 \(last.skipped.count) 个受系统保护的文件夹"
        return "上次 \(when)，用时 \(Int(last.duration.rounded())) 秒\(skipped)"
    }

    private var folderEnabledBinding: Binding<Bool> {
        Binding(
            get: { folders.settings.enabled },
            set: { isOn in
                folders.settings.enabled = isOn
                if isOn { Notifier.shared.requestAuthorization { _ in } }
            }
        )
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
