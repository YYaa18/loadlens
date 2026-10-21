import SwiftUI
import AppKit

struct AIChatView: View {
    @ObservedObject var chat: AIChat

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if chat.settingsOpen {
                keySetup
            } else {
                conversation
                Divider()
                inputBar
            }
        }
        .frame(minWidth: 440, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { chat.refreshKeyState() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.14)).frame(width: 30, height: 30)
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("AI 分析").font(.system(size: 14, weight: .semibold))
                Text("DeepSeek · 只发送诊断摘要")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !chat.messages.isEmpty {
                Button("清空") { chat.clear() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Button { chat.settingsOpen.toggle() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("API Key 设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var keySetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "key.fill").foregroundStyle(.tint)
                Text(chat.hasKey ? "更换 DeepSeek API Key" : "配置 DeepSeek API Key")
                    .font(.system(size: 13, weight: .semibold))
            }
            Text("Key 只保存在本机系统钥匙串，不会写入配置文件，也不会上传。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            SecureField("sk-...", text: $chat.keyDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { chat.saveKey() }

            HStack(spacing: 8) {
                Button("保存") { chat.saveKey() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("获取 API Key") {
                    if let url = URL(string: "https://platform.deepseek.com/api_keys") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                Spacer()
                if chat.hasKey {
                    Button("删除已保存的 Key", role: .destructive) { chat.removeKey() }
                        .controlSize(.small)
                }
            }

            if let note = chat.keyNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if chat.hasKey {
                Button("返回对话") { chat.settingsOpen = false }
                    .controlSize(.small)
            }

            Spacer()

            Text("分析时会把 CPU、内存、温度、进程名和本机建议发送到 api.deepseek.com，不发送文件内容。")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(chat.messages) { message in
                            bubble(message)
                        }
                    }

                    if chat.isStreaming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("DeepSeek 正在分析…")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: chat.messages.count) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chat.messages.last?.text) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("结合当前 CPU、内存、温度和进程数据，让 DeepSeek 用大白话解释，并回答你的问题。")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            Button { chat.analyzeCurrentState() } label: {
                Label("分析当前状态", systemImage: "sparkles")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)

            VStack(alignment: .leading, spacing: 6) {
                Text("也可以直接问：")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                suggestion("为什么风扇一直在响？")
                suggestion("现在最该关掉哪个应用？")
                suggestion("内存还够用吗？")
            }

            privacyDisclosure
        }
        .padding(.vertical, 6)
    }

    private func suggestion(_ text: String) -> some View {
        Button { chat.send(text) } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.right")
                Text(text)
            }
            .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.tint)
        .disabled(chat.isStreaming)
    }

    private var privacyDisclosure: some View {
        DisclosureGroup("查看将发送的数据") {
            ScrollView {
                Text(chat.lastContext.isEmpty ? chat.contextPreview() : chat.lastContext)
                    .font(.system(size: 9.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 44) }

            Text(rendered(message.text))
                .font(.system(size: 12))
                .lineSpacing(2)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(message.role == .user
                              ? Color.accentColor.opacity(0.14)
                              : Color.primary.opacity(0.055))
                )
                .frame(maxWidth: 360, alignment: .leading)

            if message.role == .assistant { Spacer(minLength: 44) }
        }
    }

    private func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if let error = chat.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { chat.dismissError() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            HStack(spacing: 8) {
                TextField("问点什么，例如：为什么风扇响？", text: $chat.input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { chat.send(chat.input) }

                if chat.isStreaming {
                    Button("停止") { chat.cancel() }
                        .controlSize(.small)
                } else {
                    Button { chat.send(chat.input) } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.borderless)
                    .disabled(chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }
}
