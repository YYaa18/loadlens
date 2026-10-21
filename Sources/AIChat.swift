import Foundation

struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    /// What is sent to the model.
    var text: String
    /// Optional friendlier text shown in the bubble instead of `text`.
    var display: String? = nil
    let date = Date()

    var shownText: String { display ?? text }
}

final class AIChat: ObservableObject {
    static let shared = AIChat()

    @Published private(set) var messages: [ChatMessage] = []
    @Published var input = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorNeedsKey = false
    @Published private(set) var canRetry = false
    @Published private(set) var hasKey = false
    @Published var settingsOpen = false
    @Published var keyDraft = ""
    @Published private(set) var keyNote: String?
    @Published private(set) var lastContext = ""

    private let client = DeepSeekClient.shared
    private var cachedKey: String?
    private var task: Task<Void, Never>?
    private var pending = ""
    private var flushScheduled = false
    private var currentAssistantID: UUID?
    private var lastRequest: (prompt: String, display: String?)?
    private let mockMode = ProcessInfo.processInfo.environment["LOADLENS_AI_MOCK"] == "1"
    private let envKey = ProcessInfo.processInfo.environment["LOADLENS_AI_KEY"]

    private let systemPrompt = """
    你是一个 macOS 性能诊断助手，服务对象是不懂技术的普通用户。你会收到本机实时快照。
    要求：
    1. 先给结论，再给原因和建议；
    2. 用中文，少用术语；必须用术语时解释一句；
    3. 只根据快照和用户问题回答，不要编造快照中没有的数据；
    4. 建议要具体、可执行，最多 3 条；
    5. 不要建议危险命令、安装来源不明的软件或关闭系统安全功能；
    6. 除非用户要求展开，回答控制在 250 字以内；
    7. 可以用简短的 Markdown：**加粗**关键结论，用 "- " 或 "1. " 列出建议，不要用表格和标题。
    """

    private init() {}

    // MARK: - Keys

    func refreshKeyState() {
        if mockMode || envKey?.isEmpty == false {
            hasKey = true
            if mockMode { settingsOpen = false }
            return
        }
        if cachedKey == nil {
            cachedKey = Keychain.load()
        }
        hasKey = cachedKey != nil
        if !hasKey { settingsOpen = true }
    }

    private func currentKey() -> String? {
        if mockMode { return "mock" }
        if let envKey, !envKey.isEmpty { return envKey }
        if let cachedKey { return cachedKey }
        cachedKey = Keychain.load()
        return cachedKey
    }

    func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyNote = "请输入 API Key"
            return
        }
        if Keychain.save(trimmed) {
            cachedKey = trimmed
            hasKey = true
            settingsOpen = false
            keyDraft = ""
            keyNote = "已保存到系统钥匙串"
            errorMessage = nil
        } else {
            keyNote = "保存失败，请检查钥匙串权限"
        }
    }

    func removeKey() {
        Keychain.delete()
        cachedKey = nil
        hasKey = false
        settingsOpen = true
        keyNote = "已删除保存的 Key"
        messages = []
    }

    func dismissError() {
        errorMessage = nil
        errorNeedsKey = false
        canRetry = false
    }

    func retry() {
        guard let lastRequest else { return }
        dismissError()
        send(lastRequest.prompt, display: lastRequest.display)
    }

    /// Drops the last answer and asks the same question again.
    func regenerate() {
        guard !isStreaming,
              let userIndex = messages.lastIndex(where: { $0.role == .user }) else { return }
        let question = messages[userIndex]
        messages.removeSubrange(userIndex...)
        send(question.text, display: question.display)
    }

    /// Runs the overview analysis when the conversation is empty and a key is ready.
    func startIfEmpty() {
        refreshKeyState()
        guard hasKey, messages.isEmpty, !isStreaming else { return }
        analyzeCurrentState()
    }

    // MARK: - Conversation

    func analyzeCurrentState() {
        send("请根据当前快照，用 3 句话说明电脑现在的状态，并给出最值得做的一件事。",
             display: "帮我看看电脑现在的状态")
    }

    func contextPreview() -> String {
        buildContext()
    }

    func send(_ raw: String, display: String? = nil) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return }
        guard let key = currentKey() else {
            hasKey = false
            settingsOpen = true
            return
        }

        dismissError()
        keyNote = nil
        if display == nil { input = "" }
        lastRequest = (question, display)
        let context = buildContext()
        lastContext = context

        messages.append(ChatMessage(role: .user, text: question, display: display))
        let assistant = ChatMessage(role: .assistant, text: "")
        currentAssistantID = assistant.id
        messages.append(assistant)
        pending = ""
        isStreaming = true

        let history = messages
            .filter { !$0.text.isEmpty }
            .suffix(10)
            .map { DeepSeekMessage(role: $0.role == .user ? "user" : "assistant", content: $0.text) }
        let apiMessages = [DeepSeekMessage(role: "system",
                                           content: systemPrompt + "\n\n本机快照：\n" + context)] + history

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.stream(messages: apiMessages, apiKey: key) { delta in
                    DispatchQueue.main.async { [weak self] in
                        self?.appendDelta(delta)
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.finishStreaming()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.failStreaming(error)
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if let id = currentAssistantID,
           let index = messages.firstIndex(where: { $0.id == id }),
           messages[index].text.isEmpty {
            messages.remove(at: index)
        }
        isStreaming = false
        currentAssistantID = nil
        pending = ""
        flushScheduled = false
    }

    func clear() {
        cancel()
        messages = []
        dismissError()
        lastContext = ""
    }

    // MARK: - Streaming

    private func appendDelta(_ delta: String) {
        pending += delta
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.flushPending()
        }
    }

    private func flushPending() {
        flushScheduled = false
        guard !pending.isEmpty,
              let id = currentAssistantID,
              let index = messages.firstIndex(where: { $0.id == id }) else {
            pending = ""
            return
        }
        messages[index].text += pending
        pending = ""
    }

    private func finishStreaming() {
        flushPending()
        if let id = currentAssistantID,
           let index = messages.firstIndex(where: { $0.id == id }),
           messages[index].text.isEmpty {
            messages[index].text = "没有收到内容，请稍后重试。"
        }
        isStreaming = false
        currentAssistantID = nil
    }

    private func failStreaming(_ error: Error) {
        guard isStreaming else { return }
        flushPending()
        if let id = currentAssistantID,
           let index = messages.firstIndex(where: { $0.id == id }),
           messages[index].text.isEmpty {
            messages.remove(at: index)
        }
        isStreaming = false
        currentAssistantID = nil
        if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
        // Drop the unanswered question so a retry doesn't duplicate it.
        if let last = messages.last, last.role == .user {
            messages.removeLast()
        }
        errorMessage = error.localizedDescription
        if case DeepSeekError.http(let code, _)? = error as? DeepSeekError, code == 401 {
            errorNeedsKey = true
        }
        canRetry = !errorNeedsKey
    }

    // MARK: - Context

    private func buildContext() -> String {
        let snap = Monitor.shared.snapshot
        let diag = Monitor.shared.diagnosis
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var lines: [String] = []
        lines.append("时间：\(formatter.string(from: snap.sampledAt))")
        lines.append(String(format: "整机 CPU：%.0f%%，负载：%.1f / %.1f / %.1f，共 %d 核",
                            snap.cpu, snap.load1, snap.load5, snap.load15, snap.cores))
        lines.append("内存：\(formatGB(snap.memory.usedBytes)) / \(formatGB(snap.memory.totalBytes)) GB；交换区 \(formatGB(snap.memory.swapUsedBytes)) GB；压缩内存 \(formatGB(snap.memory.compressedBytes)) GB")
        lines.append("温度状态：\(diag.thermalLabel)；已连续运行 \(Int(snap.uptime / 86_400)) 天")
        lines.append("占用最高的应用：")
        for app in snap.apps.prefix(6) {
            var line = "- \(app.name)：\(Int(app.cpu.rounded()))%"
            if !app.subtitle.isEmpty {
                line += "（\(app.subtitle)）"
            }
            lines.append(line)
        }
        lines.append("本机规则引擎结论：\(diag.headline)")
        lines.append("本机规则引擎建议：")
        for item in diag.advice {
            lines.append("- \(item)")
        }
        return lines.joined(separator: "\n")
    }
}
