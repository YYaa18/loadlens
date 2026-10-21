import SwiftUI
import AppKit

extension LoadLevel {
    var tint: Color {
        switch self {
        case .calm: return .green
        case .busy: return .orange
        case .hot: return .red
        }
    }

    var symbol: String {
        switch self {
        case .calm: return "checkmark.circle"
        case .busy: return "exclamationmark.triangle"
        case .hot: return "flame.fill"
        }
    }
}

struct PanelView: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 16) {
                trendSection
                topSection
                memorySection
                thermalSection
                adviceSection
                settingsSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 400)
        .onAppear { monitor.panelDidOpen() }
        .onDisappear { monitor.panelDidClose() }
    }

    private var header: some View {
        let diag = monitor.diagnosis
        return HStack(alignment: .center, spacing: 11) {
            ZStack {
                Circle().fill(diag.level.tint.opacity(0.14)).frame(width: 34, height: 34)
                Image(systemName: diag.level.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(diag.level.tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(diag.headline)
                    .font(.system(size: 15, weight: .semibold))
                Text(diag.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("CPU 趋势")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(historySpan)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Sparkline(values: monitor.cpuHistory.map(\.cpu), color: monitor.diagnosis.level.tint)
                .frame(height: 30)
        }
    }

    private var historySpan: String {
        guard let first = monitor.cpuHistory.first?.date,
              let last = monitor.cpuHistory.last?.date else { return "" }
        let minutes = Int(last.timeIntervalSince(first) / 60)
        return minutes >= 1 ? "最近 \(minutes) 分钟" : "最近不到 1 分钟"
    }

    private var topSection: some View {
        section("谁在占用 CPU") {
            let apps = Array(monitor.snapshot.apps.prefix(4))
            if apps.isEmpty {
                Text("暂时没有明显占用")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(apps) { app in
                        appRow(app)
                    }
                }
            }
        }
    }

    private func appRow(_ app: AppUsage) -> some View {
        HStack(spacing: 9) {
            if let icon = monitor.icon(for: app) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: 22, height: 22)
                    Image(systemName: app.isSystem ? "gearshape.fill" : "app.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(app.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text("\(Int(app.cpu.rounded()))%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(cpuColor(app.cpu))
        }
    }

    private func cpuColor(_ cpu: Double) -> Color {
        if cpu >= 60 { return .red }
        if cpu >= 25 { return .orange }
        return .secondary
    }

    private var memorySection: some View {
        let memory = monitor.snapshot.memory
        let ratio = memory.totalBytes > 0
            ? min(Double(memory.usedBytes) / Double(memory.totalBytes), 1)
            : 0
        let label = monitor.diagnosis.memoryLabel
        let tint: Color = label == "紧张" ? .red : (label == "偏紧" ? .orange : .green)

        return section("内存") {
            VStack(spacing: 6) {
                HStack {
                    Text("\(formatGB(memory.usedBytes)) / \(formatGB(memory.totalBytes)) GB")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(tint)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule()
                            .fill(tint)
                            .frame(width: max(2, geometry.size.width * ratio))
                    }
                }
                .frame(height: 6)
                HStack {
                    Text("交换区 \(formatGB(memory.swapUsedBytes)) GB")
                    Spacer()
                    Text("压缩内存 \(formatGB(memory.compressedBytes)) GB")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var thermalSection: some View {
        let snap = monitor.snapshot
        let days = Int(snap.uptime / 86_400)
        return section("温度与负载") {
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(monitor.diagnosis.thermalLabel)
                    .font(.system(size: 12))
                Spacer()
                Text(String(format: "负载 %.1f · %d 核 · 已运行 %d 天", snap.load1, snap.cores, days))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var adviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("建议")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button { AIChatWindowController.shared.show() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                        Text("AI 深入分析")
                    }
                    .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help("用 DeepSeek 结合当前数据分析")
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(monitor.diagnosis.advice.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tint)
                            .padding(.top, 2)
                        Text(item)
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var settingsSection: some View {
        section("选项") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 18) {
                    Toggle("开机自启", isOn: $monitor.launchAtLogin)
                    Toggle("高负载提醒", isOn: $monitor.notificationsEnabled)
                    Spacer(minLength: 0)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 11.5))

                if let message = monitor.settingsMessage {
                    Text(message)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("更新于 \(timeString)")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Button { monitor.refreshNow() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("立即刷新")

            Button { monitor.copyReport() } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("复制诊断信息")

            Button { monitor.openActivityMonitor() } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .help("打开活动监视器")

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .help("退出负载侦探")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: monitor.snapshot.sampledAt)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let denominator = max(values.count - 1, 1)
            let stepX = width / CGFloat(denominator)
            let points = values.enumerated().map { index, value -> CGPoint in
                let clamped = min(max(value, 0), 100)
                return CGPoint(x: CGFloat(index) * stepX,
                               y: height - CGFloat(clamped / 100) * height)
            }

            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.30), color.opacity(0.02)],
                                         startPoint: .top,
                                         endPoint: .bottom))

                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}
