import SwiftUI
import AppKit

struct AIChatView: View {
    @ObservedObject var chat: AIChat
    /// Shown inside the menu bar panel instead of its own window.
    var embedded = false
    var onClose: (() -> Void)? = nil
    var onPopOut: (() -> Void)? = nil
    @ObservedObject private var monitor = Monitor.shared
    @ObservedObject private var store = AIConfigStore.shared
    @FocusState private var inputFocused: Bool
    @State private var showContext = false

    private let starters: [(icon: String, text: String)] = [
        ("fan", "为什么风扇一直在响？"),
        ("xmark.app", "现在最该关掉哪个应用？"),
        ("memorychip", "内存还够用吗？要不要加内存？"),
        ("battery.75", "怎么让电池更耐用？")
    ]

    private let followUps = ["具体该怎么操作？", "还有其他可能的原因吗？", "需要重启电脑吗？"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            if !store.isReady && chat.messages.isEmpty {
                setupPrompt
            } else {
                contextStrip
                conversation
                composer
            }
        }
        .frame(minWidth: embedded ? 0 : 380, minHeight: embedded ? 0 : 460)
        .background(embedded ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: embedded ? [] : .top)
        .onAppear { inputFocused = true }
        .onChange(of: store.isReady) { ready in
            if ready { chat.startIfEmpty() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            AIAvatar(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(embedded ? "AI 助手" : "AI 诊断助手")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                modelSwitcher
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            IconButton(symbol: "square.and.pencil", help: "新对话") { chat.clear() }
                .disabled(chat.messages.isEmpty && !chat.isStreaming)
                .opacity(chat.messages.isEmpty ? 0.4 : 1)
            IconButton(symbol: "gearshape", help: "AI 模型设置") {
                AISettingsWindowController.shared.show()
            }
            if let onPopOut {
                IconButton(symbol: "macwindow.on.rectangle", help: "在独立窗口中打开", action: onPopOut)
            }
            if let onClose {
                IconButton(symbol: "xmark", help: "收起 AI 助手", action: onClose)
            }
        }
        .padding(.leading, embedded ? 12 : 90)   // window mode: clear the traffic lights
        .padding(.trailing, embedded ? 8 : 12)
        .frame(height: embedded ? 48 : 52)
    }

    private var modelSwitcher: some View {
        Menu {
            ForEach(store.configuredProviders) { preset in
                Section(preset.name) {
                    ForEach(store.models(for: preset.id), id: \.self) { model in
                        Button {
                            store.activate(preset.id, model: model)
                        } label: {
                            if store.settings.activeProvider == preset.id && store.config(for: preset.id).model == model {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("管理模型服务…") { AISettingsWindowController.shared.show() }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(store.isReady ? LoadLevel.calm.tint : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(store.isReady ? store.displayName : "未配置模型")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("切换模型")
    }

    // MARK: Setup prompt

    private var setupPrompt: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                Circle().fill(Brand.gradient)
                Image(systemName: "cpu")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 50, height: 50)
            Text("先选一个 AI 模型")
                .font(.system(size: 16, weight: .semibold))
            Text("支持 DeepSeek、OpenAI、Claude、Gemini、Kimi、通义千问、智谱等，也可以连接本地 Ollama 或任意 OpenAI 兼容接口。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)
            Button { AISettingsWindowController.shared.show() } label: {
                Label("打开 AI 模型设置", systemImage: "gearshape")
            }
            .buttonStyle(GradientButtonStyle())
            .frame(maxWidth: 220)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Context strip

    private var contextStrip: some View {
        let snap = monitor.snapshot
        let diag = monitor.diagnosis
        return HStack(spacing: 6) {
            LiveDot(tint: diag.level.tint)
                .help("面板每 5 秒刷新一次，每次提问都会带上最新数据")
            Text("AI 实时读取")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    contextChip("CPU \(Int(snap.cpu.rounded()))%", tint: diag.level.tint)
                    contextChip("内存 \(formatGB(snap.memory.usedBytes))/\(formatGB(snap.memory.totalBytes)) GB", tint: nil)
                    contextChip("温度 \(diag.thermalLabel)", tint: nil)
                }
            }
            Button("详情") { showContext.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tint)
                .popover(isPresented: $showContext, arrowEdge: .bottom) {
                    contextPopover
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func contextChip(_ text: String, tint: Color?) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint ?? .primary.opacity(0.75))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill((tint ?? .primary).opacity(0.08)))
    }

    private var contextPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("每次提问会附带这份实时快照", systemImage: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
            Text("只包含系统指标和应用名，不包含任何文件内容。发送到 \(store.endpoint().host)（\(store.activePreset.name)）。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(chat.contextPreview())
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if chat.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(chat.messages) { message in
                            messageView(message)
                                .id(message.id)
                        }
                        if !chat.isStreaming, chat.errorMessage == nil,
                           chat.messages.last?.role == .assistant {
                            followUpChips
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .onChange(of: chat.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.messages.last?.text) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat.isStreaming) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            AIAvatar(size: 46)
                .shadow(color: Brand.coral.opacity(0.3), radius: 10, y: 4)
                .padding(.top, 18)
            VStack(spacing: 5) {
                Text("你好，我来帮你看看这台 Mac")
                    .font(.system(size: 16, weight: .semibold))
                Text("我会结合实时的 CPU、内存、温度和进程数据，用大白话解释原因，给出能马上做的建议。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }

            Button { chat.analyzeCurrentState() } label: {
                Label("一键分析当前状态", systemImage: "sparkles")
            }
            .buttonStyle(GradientButtonStyle())
            .frame(maxWidth: 240)
            .disabled(chat.isStreaming)

            VStack(alignment: .leading, spacing: 6) {
                Text("或者直接问")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 2)
                ForEach(starters, id: \.text) { starter in
                    StarterRow(icon: starter.icon, text: starter.text) { chat.send(starter.text) }
                        .disabled(chat.isStreaming)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func messageView(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(message.shownText)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        UnevenBubble()
                            .fill(Color.accentColor)
                    )
            }
        case .assistant:
            AssistantMessage(message: message,
                             isStreaming: chat.isStreaming && message.id == chat.messages.last?.id,
                             isLast: message.id == chat.messages.last?.id,
                             onRegenerate: { chat.regenerate() })
        }
    }

    private var followUpChips: some View {
        FlowLayout(spacing: 6) {
            ForEach(followUps, id: \.self) { text in
                Button(text) { chat.send(text) }
                    .buttonStyle(ChipButtonStyle())
            }
        }
        .padding(.leading, 34)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if let error = chat.errorMessage {
                errorBanner(error)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("问点什么，例如：为什么风扇一直响？", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { submit() }
                    .onChange(of: chat.input) { value in
                        // Return sends; Option/Shift+Return keeps the newline.
                        guard value.hasSuffix("\n") else { return }
                        let flags = NSEvent.modifierFlags
                        if flags.contains(.option) || flags.contains(.shift) { return }
                        chat.input = String(value.dropLast())
                        submit()
                    }
                    .padding(.vertical, 5)

                if chat.isStreaming {
                    Button { chat.cancel() } label: {
                        ZStack {
                            Circle().fill(Color.primary.opacity(0.85))
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: .windowBackgroundColor))
                                .frame(width: 9, height: 9)
                        }
                        .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("停止生成")
                } else {
                    Button { submit() } label: {
                        ZStack {
                            Circle().fill(canSend ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.12)))
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("发送（Return）")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(inputFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12),
                                  lineWidth: inputFocused ? 1.2 : 0.8)
            )
            .shadow(color: .black.opacity(0.04), radius: 4, y: 1)

            Text("Return 发送 · ⇧Return 换行 · AI 回答仅供参考")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var canSend: Bool {
        !chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend, !chat.isStreaming else { return }
        chat.send(chat.input)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LoadLevel.busy.tint)
            Text(error)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if chat.errorNeedsKey {
                Button("打开设置") { AISettingsWindowController.shared.show() }
                    .controlSize(.small)
            } else if chat.canRetry {
                Button("重试") { chat.retry() }
                    .controlSize(.small)
            }
            Button { chat.dismissError() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LoadLevel.busy.tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LoadLevel.busy.tint.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Assistant message

private struct AssistantMessage: View {
    let message: ChatMessage
    let isStreaming: Bool
    let isLast: Bool
    let onRegenerate: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AIAvatar(size: 24)
            VStack(alignment: .leading, spacing: 8) {
                if message.text.isEmpty {
                    TypingIndicator()
                        .padding(.top, 6)
                } else {
                    MarkdownText(text: message.text)
                }

                if !isStreaming && !message.text.isEmpty {
                    HStack(spacing: 2) {
                        smallAction(copied ? "checkmark" : "doc.on.doc",
                                    copied ? "已复制" : "复制") { copy() }
                        if isLast {
                            smallAction("arrow.clockwise", "重新生成", action: onRegenerate)
                        }
                    }
                    .opacity(hovering || isLast ? 1 : 0)
                }
            }
            .padding(.top, 2)
            Spacer(minLength: 20)
        }
        .onHover { hovering = $0 }
    }

    private func smallAction(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 10.5))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

private struct StarterRow: View {
    let icon: String
    let text: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Brand.orange)
                    .frame(width: 18)
                Text(text)
                    .font(.system(size: 12.5))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }
}

/// Chat bubble with a tighter bottom-right corner, pointing at the sender.
private struct UnevenBubble: Shape {
    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 14
        let small: CGFloat = 4
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + big, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - big, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + big), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - small))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - small, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + big, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - big), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + big))
        path.addQuadCurve(to: CGPoint(x: rect.minX + big, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct TypingIndicator: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Brand.orange)
                    .frame(width: 6, height: 6)
                    .opacity(phase ? 1 : 0.25)
                    .scaleEffect(phase ? 1 : 0.7)
                    .animation(.easeInOut(duration: 0.55)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.18),
                               value: phase)
            }
            Text("正在结合实时数据分析…")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
        .onAppear {
            // Start after layout settles so the repeat doesn't replay the bubble's insertion.
            DispatchQueue.main.async { phase = true }
        }
    }
}

/// Wraps children onto new lines when they run out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
