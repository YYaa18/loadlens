import SwiftUI
import AppKit

let panelWidth: CGFloat = 360

struct PanelView: View {
    @ObservedObject var monitor: Monitor
    @State private var toast: String?
    @State private var spin = 0.0

    var body: some View {
        VStack(spacing: 0) {
            topBar
            VStack(spacing: 10) {
                heroCard
                metricTiles
                topAppsCard
                adviceCard
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            Divider().opacity(0.5)
            footer
        }
        .frame(width: panelWidth)
        .overlay(alignment: .bottom) { toastView }
        .onAppear { monitor.panelDidOpen() }
        .onDisappear { monitor.panelDidClose() }
        .onChange(of: monitor.settingsMessage) { message in
            if let message { showToast(message) }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            BrandMark(size: 20)
            Text("负载侦探")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "立即刷新") {
                withAnimation(.easeInOut(duration: 0.6)) { spin += 360 }
                monitor.refreshNow()
            }
            .rotationEffect(.degrees(spin))
            settingsMenu
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var settingsMenu: some View {
        Menu {
            Toggle("开机自动启动", isOn: $monitor.launchAtLogin)
            Toggle("持续高负载时通知我", isOn: $monitor.notificationsEnabled)
            Divider()
            Button("AI 设置（API Key）…") { openAI(settings: true) }
            Button("复制诊断报告") { copyReport() }
            Button("打开活动监视器") { monitor.openActivityMonitor() }
            Divider()
            Button("退出负载侦探") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("设置")
    }

    // MARK: Hero

    private var heroCard: some View {
        let diag = monitor.diagnosis
        let tint = diag.level.tint
        let cpu = Int(monitor.snapshot.cpu.rounded())

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Image(systemName: diag.level.symbol)
                        Text(diag.level.badge)
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tint.opacity(0.15)))

                    Text(diag.headline)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(heroSummary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text("\(cpu)")
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("%")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Text("CPU 占用")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .animation(.easeOut(duration: 0.3), value: cpu)
            }

            TrendChart(values: monitor.cpuHistory.map(\.cpu), tint: tint)
                .frame(height: 44)

            HStack {
                Text(historySpan)
                Spacer()
                Text(historyStats)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.04)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.4), value: diag.level)
    }

    private var heroSummary: String {
        let diag = monitor.diagnosis
        if monitor.snapshot.apps.isEmpty { return diag.detail }
        if let top = monitor.snapshot.apps.first, top.cpu >= 12 {
            let lead = diag.level == .calm ? "整体轻松，目前占用最多的是" : "主要来自"
            return "\(lead) \(top.name)（\(Int(top.cpu.rounded()))%）"
        }
        switch diag.level {
        case .calm: return "电脑很轻松，暂时不需要处理"
        case .busy: return "多个应用一起占用，暂无单一元凶"
        case .hot: return "负载很高，建议关掉暂时不用的应用"
        }
    }

    private var historySpan: String {
        guard let first = monitor.cpuHistory.first?.date,
              let last = monitor.cpuHistory.last?.date else { return "趋势" }
        let minutes = Int(last.timeIntervalSince(first) / 60)
        return minutes >= 1 ? "近 \(minutes) 分钟" : "近 1 分钟内"
    }

    private var historyStats: String {
        let values = monitor.cpuHistory.map(\.cpu)
        guard !values.isEmpty else { return "" }
        let avg = values.reduce(0, +) / Double(values.count)
        let peak = values.max() ?? 0
        return String(format: "平均 %.0f%% · 峰值 %.0f%%", avg, peak)
    }

    // MARK: Metric tiles

    private var metricTiles: some View {
        let snap = monitor.snapshot
        let diag = monitor.diagnosis
        let memory = snap.memory
        let memRatio = memory.totalBytes > 0
            ? min(Double(memory.usedBytes) / Double(memory.totalBytes), 1) : 0
        let memTint = labelTint(diag.memoryLabel)
        let thermalTint: Color = {
            switch snap.thermal {
            case .nominal: return LoadLevel.calm.tint
            case .fair: return LoadLevel.busy.tint
            default: return LoadLevel.hot.tint
            }
        }()
        let cores = max(snap.cores, 1)
        let loadRatio = min(snap.load1 / Double(cores), 1)
        let days = Int(snap.uptime / 86_400)

        return HStack(spacing: 8) {
            MetricTile(symbol: "memorychip",
                       title: "内存",
                       value: "\(formatGB(memory.usedBytes)) GB",
                       caption: "共 \(formatGB(memory.totalBytes)) GB · \(diag.memoryLabel)",
                       progress: memRatio,
                       tint: memTint)
                .help("交换区 \(formatGB(memory.swapUsedBytes)) GB · 压缩内存 \(formatGB(memory.compressedBytes)) GB")

            MetricTile(symbol: "thermometer.medium",
                       title: "温度",
                       value: diag.thermalLabel,
                       caption: snap.thermal == .nominal ? "散热良好" : "系统可能降频",
                       progress: nil,
                       tint: thermalTint)
                .help("来自系统温度状态，不是具体度数")

            MetricTile(symbol: "gauge.with.dots.needle.50percent",
                       title: "负载",
                       value: String(format: "%.1f", snap.load1),
                       caption: "\(cores) 核 · 已运行 \(days) 天",
                       progress: loadRatio,
                       tint: loadRatio >= 0.9 ? LoadLevel.busy.tint : Color.accentColor)
                .help(String(format: "1 / 5 / 15 分钟负载：%.1f / %.1f / %.1f", snap.load1, snap.load5, snap.load15))
        }
    }

    private func labelTint(_ label: String) -> Color {
        switch label {
        case "紧张": return LoadLevel.hot.tint
        case "偏紧": return LoadLevel.busy.tint
        default: return LoadLevel.calm.tint
        }
    }

    // MARK: Top apps

    private var topAppsCard: some View {
        let apps = Array(monitor.snapshot.apps.prefix(5))
        let scale = max(100, apps.first?.cpu ?? 0)

        return VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "占用排行", trailing: "同一应用的进程已合并")
                .padding(.horizontal, 4)
            if apps.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描进程…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                VStack(spacing: 0) {
                    ForEach(apps) { app in
                        AppRow(app: app, icon: monitor.icon(for: app), scale: scale, monitor: monitor)
                    }
                }
            }
        }
        .card(padding: 8)
    }

    // MARK: Advice

    private var adviceCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title: "诊断建议")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(monitor.diagnosis.advice.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(monitor.diagnosis.level.tint)
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(monitor.diagnosis.level.tint.opacity(0.15)))
                        Text(item)
                            .font(.system(size: 12))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button { openAI(settings: false) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("让 AI 帮我深入分析")
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .buttonStyle(GradientButtonStyle())
            .padding(.top, 2)
            .help("DeepSeek 结合当前实时数据，用大白话解释原因")
        }
        .card()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            LiveDot(tint: monitor.diagnosis.level.tint)
            Text("实时 · 更新于 \(timeString)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            FooterButton(symbol: "doc.on.doc", title: "复制报告") { copyReport() }
            FooterButton(symbol: "waveform.path.ecg", title: "活动监视器") { monitor.openActivityMonitor() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: monitor.snapshot.sampledAt)
    }

    // MARK: Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LoadLevel.calm.tint)
                Text(toast)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .padding(.bottom, 44)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            guard toast == text else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    // MARK: Actions

    private func copyReport() {
        monitor.copyReport()
        showToast("诊断报告已复制，可以直接粘贴发给别人")
    }

    private func openAI(settings: Bool) {
        let anchor = currentPanelFrame()
        AIChatWindowController.shared.show(anchor: anchor,
                                           openSettings: settings,
                                           autoAnalyze: !settings)
    }

    private func currentPanelFrame() -> NSRect? {
        if let key = NSApp.keyWindow, key.className.contains("MenuBarExtra") || key.frame.width <= panelWidth + 2 {
            return key.frame
        }
        return NSApp.windows.first {
            $0.isVisible && $0.className.contains("MenuBarExtra")
        }?.frame
    }
}

// MARK: - Components

struct MetricTile: View {
    let symbol: String
    let title: String
    let value: String
    let caption: String
    let progress: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(tint)
                            .frame(width: max(3, geometry.size.width * progress))
                    }
                }
                .frame(height: 4)
                .animation(.easeOut(duration: 0.4), value: progress)
            } else {
                Capsule().fill(tint.opacity(0.0)).frame(height: 4)
            }
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 10, radius: 11)
    }
}

struct AppRow: View {
    let app: AppUsage
    let icon: NSImage?
    let scale: Double
    let monitor: Monitor
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            iconView
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if !app.subtitle.isEmpty {
                        Text(app.subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule().fill(usageColor(app.cpu).opacity(0.85))
                            .frame(width: max(2, geometry.size.width * min(app.cpu / scale, 1)))
                    }
                }
                .frame(height: 3)
                .animation(.easeOut(duration: 0.4), value: app.cpu)
            }

            ZStack(alignment: .trailing) {
                Text("\(Int(app.cpu.rounded()))%")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(app.cpu >= 25 ? usageColor(app.cpu) : .primary)
                    .opacity(hovering ? 0 : 1)
                if hovering { actionsMenu }
            }
            .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .help(app.isSystem ? "系统服务：\(app.busiestProcess)" : "进程：\(app.busiestProcess)")
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
                Image(systemName: app.isSystem ? symbolForSystemApp(app.name) : "terminal.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 24, height: 24)
            .padding(1)
        }
    }

    private var actionsMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var menuItems: some View {
        if app.bundlePath != nil {
            Button("退出 \(app.name)") { monitor.quit(app) }
            Button("在访达中显示") { monitor.reveal(app) }
            Divider()
        }
        Button("在活动监视器中查看") { monitor.openActivityMonitor() }
        Button("复制名称") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(app.name, forType: .string)
        }
    }
}

struct FooterButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
    }
}

struct LiveDot: View {
    let tint: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.35))
                .frame(width: 10, height: 10)
                .scaleEffect(pulse ? 1 : 0.4)
                .opacity(pulse ? 0 : 1)
            Circle().fill(tint).frame(width: 6, height: 6)
        }
        .frame(width: 10, height: 10)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

struct TrendChart: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let points = chartPoints(width: width, height: height)

            ZStack(alignment: .topLeading) {
                // 50% guide line
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height / 2))
                    path.addLine(to: CGPoint(x: width, y: height / 2))
                }
                .stroke(Color.primary.opacity(0.10), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

                if points.count > 1 {
                    smoothPath(points, closeTo: height)
                        .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.0)],
                                             startPoint: .top, endPoint: .bottom))
                    smoothPath(points, closeTo: nil)
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    if let last = points.last {
                        Circle().fill(tint)
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.2))
                            .position(last)
                    }
                } else {
                    Text("正在收集数据…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .frame(width: width, height: height)
                }
            }
        }
    }

    private func chartPoints(width: CGFloat, height: CGFloat) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let stepX = width / CGFloat(values.count - 1)
        let usable = height - 4
        return values.enumerated().map { index, value in
            let clamped = min(max(value, 0), 100)
            return CGPoint(x: CGFloat(index) * stepX,
                           y: 3 + usable - CGFloat(clamped / 100) * usable)
        }
    }

    private func smoothPath(_ points: [CGPoint], closeTo bottom: CGFloat?) -> Path {
        Path { path in
            if let bottom {
                path.move(to: CGPoint(x: points[0].x, y: bottom))
                path.addLine(to: points[0])
            } else {
                path.move(to: points[0])
            }
            for index in 1..<points.count {
                let previous = points[index - 1]
                let current = points[index]
                let mid = (previous.x + current.x) / 2
                path.addCurve(to: current,
                              control1: CGPoint(x: mid, y: previous.y),
                              control2: CGPoint(x: mid, y: current.y))
            }
            if let bottom, let last = points.last {
                path.addLine(to: CGPoint(x: last.x, y: bottom))
                path.closeSubpath()
            }
        }
    }
}
