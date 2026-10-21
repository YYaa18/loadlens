import SwiftUI
import AppKit

private let readTint = Color(red: 0.25, green: 0.56, blue: 0.98)
private let writeTint = Color(red: 0.98, green: 0.55, blue: 0.20)

func diskTint(_ label: String) -> Color {
    switch label {
    case "异常", "紧张": return LoadLevel.hot.tint
    case "偏紧": return LoadLevel.busy.tint
    default: return LoadLevel.calm.tint
    }
}

struct DiskPageView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var scanner = SpaceScanner.shared

    var body: some View {
        VStack(spacing: 10) {
            startupCard
            activityCard
            if !externalVolumes.isEmpty { volumesCard }
            spaceCard
        }
    }

    private var disk: DiskSnapshot { monitor.snapshot.disk }
    private var externalVolumes: [VolumeInfo] { disk.volumes.filter { !$0.isRoot } }

    // MARK: Startup disk

    @ViewBuilder
    private var startupCard: some View {
        if let root = disk.root {
            let label = monitor.diagnosis.diskLabel
            let tint = diskTint(label)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tint.opacity(0.15))
                        Image(systemName: "internaldrive.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(root.name)
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(driveDescription(root))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    healthBadge
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(formatSize(root.availableBytes))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("可用")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("共 \(formatSize(root.totalBytes)) · 空间\(label)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                CapacityBar(volume: root, tint: tint)
                    .frame(height: 10)

                HStack(spacing: 12) {
                    legend(tint, "已用 \(formatSize(root.usedBytes))")
                    if root.purgeableBytes > 500_000_000 {
                        legend(tint.opacity(0.35), "可自动清除 \(formatSize(root.purgeableBytes))")
                            .help("缓存、本地快照等，空间不够时系统会自动释放")
                    }
                    legend(Color.primary.opacity(0.12), "空闲 \(formatSize(root.freeBytes))")
                    Spacer(minLength: 0)
                }

                if let snapshots = disk.health?.localSnapshots, snapshots > 0 {
                    Label("有 \(snapshots) 个本地 Time Machine 快照，空间不足时会被自动删除", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .card()
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在读取磁盘信息…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .card()
        }
    }

    private func driveDescription(_ volume: VolumeInfo) -> String {
        var parts: [String] = [volume.isInternal ? "内置" : "外接"]
        if let health = disk.health { parts.append(health.solidState ? "固态硬盘" : "机械硬盘") }
        if !volume.fileSystem.isEmpty { parts.append(volume.fileSystem) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var healthBadge: some View {
        if let health = disk.health {
            let tint: Color = health.isFailing ? LoadLevel.hot.tint
                : (health.label == "正常" ? LoadLevel.calm.tint : Color.secondary)
            HStack(spacing: 3) {
                Image(systemName: health.isFailing ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                Text("健康 \(health.label)")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.13)))
            .help("SMART 自检状态：\(health.smartStatus)")
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    // MARK: Activity

    private var activityCard: some View {
        let busy = monitor.snapshot.apps
            .filter { $0.diskTotal >= 100 * 1024 }
            .sorted { $0.diskTotal > $1.diskTotal }
            .prefix(3)

        return VStack(alignment: .leading, spacing: 9) {
            SectionHeader(title: "读写活动", trailing: "每 5 秒刷新")
            HStack(spacing: 10) {
                rateBlock("读取", disk.readRate, readTint, "arrow.down")
                rateBlock("写入", disk.writeRate, writeTint, "arrow.up")
            }
            DualTrendChart(read: monitor.diskHistory.map(\.read),
                           write: monitor.diskHistory.map(\.write))
                .frame(height: 40)

            Divider().opacity(0.5)
            // Fixed height so the cards below don't jump as apps come and go.
            Group {
                if busy.isEmpty {
                    Text("目前没有应用在明显读写硬盘")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxHeight: .infinity, alignment: .center)
                } else {
                VStack(spacing: 6) {
                    ForEach(Array(busy)) { app in
                        HStack(spacing: 8) {
                            appIcon(app)
                            Text(app.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("↓\(formatRate(app.diskRead))")
                                .foregroundStyle(readTint)
                            Text("↑\(formatRate(app.diskWrite))")
                                .foregroundStyle(writeTint)
                        }
                        .font(.system(size: 11, design: .rounded))
                        .monospacedDigit()
                    }
                }
                }
            }
            .frame(height: 66, alignment: .top)
        }
        .card()
    }

    private func rateBlock(_ title: String, _ rate: Double, _ tint: Color, _ symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(Circle().fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 0) {
                Text(formatRate(rate))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func appIcon(_ app: AppUsage) -> some View {
        if let icon = monitor.icon(for: app) {
            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: app.isSystem ? symbolForSystemApp(app.name) : "terminal.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.14)))
        }
    }

    // MARK: Other volumes

    private var volumesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "其他磁盘")
            ForEach(externalVolumes) { volume in
                VolumeRow(volume: volume) { eject(volume) }
            }
        }
        .card()
    }

    private func askAI(about item: SpaceItem) {
        AIDock.shared.ask("帮我详细分析「\(item.title)」（\(formatSize(item.bytes))）里具体是哪些应用或文件占用的。请调用 analyze_folder 查看明细，告诉我每一大项是什么、哪些可以放心清理、哪些要谨慎、怎么清理。",
                          display: "分析「\(item.title)」里都有什么")
    }

    private func eject(_ volume: VolumeInfo) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume.path))
        } catch {
            NSSound.beep()
        }
        monitor.refreshVolumes()
    }

    // MARK: Space analysis

    private var spaceCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("可清理空间")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if scanner.isScanning {
                    ProgressView().controlSize(.small)
                    Button("停止") { scanner.cancel() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                } else {
                    Button(scanner.scannedAt == nil ? "开始分析" : "重新分析") { scanner.scan() }
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .medium))
                }
            }

            if scanner.scannedAt == nil && !scanner.isScanning {
                Text("统计下载、废纸篓、缓存、Xcode 等常见占空间的位置。只读取大小，不会删除任何文件。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(scanner.items.filter { $0.state != .missing }) { item in
                        SpaceRow(item: item,
                                 onReveal: { scanner.reveal(item) },
                                 onAsk: { askAI(about: item) })
                    }
                }
                if !scanner.isScanning {
                    Text("合计约 \(formatSize(scanner.total))。点 ✨ 让 AI 分析某一项，点文件夹图标在访达中查看")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                    Button {
                        AIDock.shared.ask("请先查看可清理空间总览，再对占用最大的两三项查看明细，告诉我：分别是哪些应用或文件占的、哪些可以放心清理、哪些要谨慎，以及具体怎么清理。按能释放的空间从大到小排列。",
                                          display: "根据可清理空间给我清理建议")
                    } label: {
                        Label("让 AI 给出清理建议", systemImage: "sparkles")
                    }
                    .buttonStyle(GradientButtonStyle())
                }
            }

            Button {
                SpaceScanner.openStorageSettings()
            } label: {
                Label("打开系统「储存空间」设置", systemImage: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
        }
        .card()
    }
}

// MARK: - Components

struct CapacityBar: View {
    let volume: VolumeInfo
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let total = max(Double(volume.totalBytes), 1)
            let used = geometry.size.width * Double(volume.usedBytes) / total
            let purgeable = geometry.size.width * Double(volume.purgeableBytes) / total
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                HStack(spacing: 0) {
                    Rectangle().fill(tint).frame(width: max(used, 2))
                    Rectangle().fill(tint.opacity(0.35)).frame(width: purgeable)
                }
                .clipShape(Capsule())
            }
        }
        .animation(.easeOut(duration: 0.4), value: volume.availableBytes)
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo
    let onEject: () -> Void

    var body: some View {
        let tint = volume.freeRatio < 0.1 ? LoadLevel.hot.tint : Color.accentColor
        HStack(spacing: 9) {
            Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(volume.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text("可用 \(formatSize(volume.availableBytes)) / \(formatSize(volume.totalBytes))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                CapacityBar(volume: volume, tint: tint).frame(height: 5)
            }
            if volume.isEjectable {
                Button(action: onEject) {
                    Image(systemName: "eject.fill").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("推出 \(volume.name)")
            }
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: volume.path))
            } label: {
                Image(systemName: "folder").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("在访达中打开")
        }
    }
}

private struct SpaceRow: View {
    let item: SpaceItem
    let onReveal: () -> Void
    let onAsk: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.system(size: 11.5))
                .foregroundStyle(Brand.orange)
                .frame(width: 20)
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 4)
            switch item.state {
            case .pending:
                ProgressView().controlSize(.mini)
            case .counting(let bytes):
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(formatSize(bytes) + "…")
                        .font(.system(size: 11.5, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            case .done(let bytes):
                Text(formatSize(bytes))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(bytes >= 5_000_000_000 ? LoadLevel.busy.tint : .primary)
            case .denied:
                Text("需要完全磁盘访问权限")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            case .missing:
                EmptyView()
            }
            if case .done(let bytes) = item.state, bytes > 0 {
                Button(action: onAsk) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(Brand.orange)
                }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0.45)
                .help("让 AI 分析这里面都有什么、能不能清理")
            }
            Button(action: onReveal) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0.45)
            .help("在访达中显示")
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.hint)
    }
}

/// Read and write throughput on a shared, auto-scaled axis.
struct DualTrendChart: View {
    let read: [Double]
    let write: [Double]

    var body: some View {
        GeometryReader { geometry in
            let peak = max((read + write).max() ?? 0, 1_048_576)
            ZStack {
                line(read, peak: peak, size: geometry.size, tint: readTint)
                line(write, peak: peak, size: geometry.size, tint: writeTint)
                if read.count < 2 {
                    Text("正在收集数据…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func line(_ values: [Double], peak: Double, size: CGSize, tint: Color) -> some View {
        if values.count > 1 {
            let step = size.width / CGFloat(values.count - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * step,
                        y: size.height - 2 - CGFloat(min(value / peak, 1)) * (size.height - 4))
            }
            Path { path in
                path.move(to: CGPoint(x: 0, y: size.height))
                points.forEach { path.addLine(to: $0) }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
            }
            .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
            Path { path in
                path.move(to: points[0])
                points.dropFirst().forEach { path.addLine(to: $0) }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}
