import SwiftUI
import AppKit

// MARK: - Brand

enum Brand {
    /// Warm gradient taken from the app icon's bars.
    static let amber = Color(red: 1.00, green: 0.78, blue: 0.34)
    static let orange = Color(red: 1.00, green: 0.54, blue: 0.24)
    static let coral = Color(red: 1.00, green: 0.36, blue: 0.31)

    static let gradient = LinearGradient(colors: [amber, orange, coral],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing)
    static let softGradient = LinearGradient(colors: [amber.opacity(0.18), coral.opacity(0.14)],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing)
}

extension LoadLevel {
    var tint: Color {
        switch self {
        case .calm: return Color(red: 0.20, green: 0.74, blue: 0.42)
        case .busy: return Color(red: 0.98, green: 0.62, blue: 0.10)
        case .hot: return Color(red: 0.96, green: 0.30, blue: 0.27)
        }
    }

    var symbol: String {
        switch self {
        case .calm: return "checkmark.seal.fill"
        case .busy: return "bolt.fill"
        case .hot: return "flame.fill"
        }
    }

    var badge: String {
        switch self {
        case .calm: return "平稳"
        case .busy: return "繁忙"
        case .hot: return "高负荷"
        }
    }
}

func usageColor(_ cpu: Double) -> Color {
    if cpu >= 60 { return LoadLevel.hot.tint }
    if cpu >= 25 { return LoadLevel.busy.tint }
    return Color.accentColor
}

// MARK: - Card

struct CardBackground: ViewModifier {
    var padding: CGFloat = 12
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

extension View {
    func card(padding: CGFloat = 12, radius: CGFloat = 12) -> some View {
        modifier(CardBackground(padding: padding, radius: radius))
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Small square icon button with a hover state, used in headers and footers.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Full-width button filled with the brand gradient.
struct GradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Brand.gradient)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            )
            .shadow(color: Brand.coral.opacity(0.25), radius: 6, y: 2)
            .contentShape(Rectangle())
    }
}

/// Rounded pill used for suggestions and quick prompts.
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 11.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color.primary.opacity(hovering && enabled ? 0.09 : 0.05))
                )
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

/// Brand mark: gradient rounded square with the bar-chart glyph from the app icon.
struct BrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color(red: 0.11, green: 0.14, blue: 0.20))
            HStack(alignment: .bottom, spacing: size * 0.07) {
                Capsule().fill(Brand.amber).frame(width: size * 0.14, height: size * 0.26)
                Capsule().fill(Brand.orange).frame(width: size * 0.14, height: size * 0.38)
                Capsule().fill(Brand.coral).frame(width: size * 0.14, height: size * 0.50)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Gradient circle with sparkles, used as the AI avatar.
struct AIAvatar: View {
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle().fill(Brand.gradient)
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.48, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - System process icons

func symbolForSystemApp(_ name: String) -> String {
    switch name {
    case let n where n.contains("窗口合成"): return "macwindow.on.rectangle"
    case let n where n.contains("内核"): return "cpu"
    case let n where n.contains("Spotlight"): return "magnifyingglass"
    case let n where n.contains("Time Machine"): return "clock.arrow.circlepath"
    case let n where n.contains("着色器") || n.contains("图形"): return "cube.transparent"
    case let n where n.contains("音频"): return "speaker.wave.2.fill"
    case let n where n.contains("iCloud"): return "icloud.fill"
    case let n where n.contains("Wi-Fi"): return "wifi"
    case let n where n.contains("蓝牙"): return "dot.radiowaves.left.and.right"
    case let n where n.contains("Siri"): return "waveform"
    case let n where n.contains("定位"): return "location.fill"
    case let n where n.contains("网络") || n.contains("下载"): return "network"
    case let n where n.contains("Safari"): return "safari.fill"
    case let n where n.contains("电源") || n.contains("亮度"): return "bolt.fill"
    case let n where n.contains("安全") || n.contains("证书") || n.contains("XProtect"): return "lock.shield.fill"
    case let n where n.contains("诊断") || n.contains("监控") || n.contains("日志"): return "stethoscope"
    case let n where n.contains("照片") || n.contains("媒体"): return "photo.fill"
    case let n where n.contains("更新"): return "arrow.down.circle.fill"
    default: return "gearshape.fill"
    }
}

// MARK: - Menu bar icon

enum MenuBarIcon {
    /// A small ring gauge filled to the current CPU level.
    /// Template image for normal states so it follows the menu bar colour; red when overloaded.
    static func gauge(cpu: Double, hot: Bool) -> NSImage {
        let size = NSSize(width: 15, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 1.6, dy: 1.6)
            let center = NSPoint(x: inset.midX, y: inset.midY)
            let radius = inset.width / 2

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2.2
            (hot ? NSColor.systemRed.withAlphaComponent(0.3) : NSColor.black.withAlphaComponent(0.28)).setStroke()
            track.stroke()

            let fraction = min(max(cpu / 100, 0.04), 1)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
            arc.lineWidth = 2.2
            arc.lineCapStyle = .round
            (hot ? NSColor.systemRed : NSColor.black).setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = !hot
        return image
    }
}
