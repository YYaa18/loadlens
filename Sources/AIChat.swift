import Foundation

struct ToolStep: Identifiable, Equatable {
    let id: String
    let title: String
    var done = false
}

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
    /// Lookups the assistant ran while answering.
    var steps: [ToolStep] = []
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
    @Published private(set) var lastContext = ""
    /// The provider/model that answered most recently, shown under replies.
    @Published private(set) var lastModelLabel = ""

    let config = AIConfigStore.shared
    private let client = LLMClient.shared
    private var task: Task<Void, Never>?
    private var pending = ""
    private var flushScheduled = false
    private var currentAssistantID: UUID?
    private var lastRequest: (prompt: String, display: String?)?

    private let systemPrompt = """
    你是一个 macOS 性能诊断助手，服务对象是不懂技术的普通用户。你会收到本机实时快照（摘要）。
    你还可以调用只读工具获取更细的数据：应用和进程明细、内存、硬盘、可清理空间、任意目录里每个子文件夹的大小和所属应用、历史趋势、系统信息。
    要求：
    1. 用户问到快照里没有的细节时（例如“缓存里都是哪些应用”“这个应用为什么占内存”），先调用工具查清楚再回答，不要说做不到；
    2. 先给结论，再给原因和建议；用中文，少用术语，必须用术语时解释一句；
    3. 只根据快照、工具结果和用户问题回答，不要编造数据；
    4. 建议要具体、可执行。涉及清理时说清楚：哪些可以放心删（缓存会自动重建、已卸载应用的残留）、哪些要谨慎（正在运行的应用先退出、下载里的文件要先确认），以及在哪里操作；
    5. 你不能删除文件或结束进程，只能告诉用户怎么做；不要建议危险命令、安装来源不明的软件或关闭系统安全功能；
    6. 普通问题 250 字以内；做明细分析时可以更长，按占用从大到小列出要点；
    7. 可以用简短的 Markdown：**加粗**关键结论，用 "- " 或 "1. " 列出要点，不要用表格和标题。
    """

    private init() {}

    var isReady: Bool { config.isReady }

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

    /// Runs the overview analysis when the conversation is empty and a model is ready.
    func startIfEmpty() {
        guard isReady, messages.isEmpty, !isStreaming else { return }
        analyzeCurrentState()
    }

    // MARK: - Conversation

    func analyzeCurrentState() {
        send("请根据当前快照，用 3 句话说明电脑现在的状态，并给出最值得做的一件事。",
             display: "帮我看看电脑现在的状态")
    }

    func analyzeDisk() {
        send("请查看硬盘详情和可清理空间总览，告诉我硬盘现在的情况（容量、健康、读写），以及最值得做的清理：哪些可以放心删、哪些要谨慎、怎么操作，按能释放的空间从大到小排列。",
             display: "帮我看看硬盘空间")
    }

    func contextPreview() -> String {
        buildContext()
    }

    func send(_ raw: String, display: String? = nil) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isStreaming else { return }
        guard isReady else {
            AISettingsWindowController.shared.show()
            return
        }
        let endpoint = config.endpoint()
        lastModelLabel = "\(endpoint.preset.name) · \(endpoint.model)"

        dismissError()
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

        // Last few turns, starting from a user message (required by some APIs).
        var history = Array(messages.filter { !$0.text.isEmpty }.suffix(10))
        while history.first?.role == .assistant { history.removeFirst() }
        let apiMessages = history.map {
            LLMMessage(role: $0.role == .user ? "user" : "assistant", content: $0.text)
        }
        let system = systemPrompt + "\n\n本机快照：\n" + context

        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.runAgent(system: system,
                                          messages: apiMessages,
                                          endpoint: endpoint,
                                          tools: AITools.specs,
                                          execute: { name, arguments in await AITools.execute(name, arguments) },
                                          onEvent: { event in
                    DispatchQueue.main.async { [weak self] in
                        self?.handle(event)
                    }
                })
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

    private func handle(_ event: LLMClient.AgentEvent) {
        switch event {
        case .text(let delta):
            appendDelta(delta)
        case .toolStarted(let id, let name, let arguments):
            flushPending()
            guard let index = currentIndex else { return }
            // Text written before a lookup ("我先查一下") gets separated from the final answer.
            if !messages[index].text.isEmpty, !messages[index].text.hasSuffix("\n") {
                messages[index].text += "\n\n"
            }
            messages[index].steps.append(ToolStep(id: id, title: AITools.label(name, arguments)))
        case .toolFinished(let id):
            guard let index = currentIndex,
                  let step = messages[index].steps.firstIndex(where: { $0.id == id }) else { return }
            messages[index].steps[step].done = true
        }
    }

    private var currentIndex: Int? {
        guard let id = currentAssistantID else { return nil }
        return messages.firstIndex { $0.id == id }
    }

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
        if let llmError = error as? LLMError {
            if llmError.isAuthError { errorNeedsKey = true }
            if case .notConfigured = llmError { errorNeedsKey = true }
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
        lines.append(contentsOf: diskContextLines(snap.disk, apps: snap.apps))
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
