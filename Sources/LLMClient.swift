import Foundation

struct LLMMessage {
    let role: String   // "user" or "assistant"
    let content: String
}

enum LLMError: LocalizedError {
    case notConfigured
    case badURL(String)
    case http(Int, String)
    case stream(String)
    case invalidResponse
    case refusal

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没有配置 AI 模型"
        case .badURL(let url):
            return "接口地址不正确：\(url)"
        case .http(let code, let message):
            let detail = message.isEmpty ? "" : "：\(message.prefix(140))"
            switch code {
            case 401, 403: return "API Key 无效或没有权限（\(code)）"
            case 402: return "账户余额不足（402）"
            case 404: return "接口地址或模型名不存在（404）\(detail)"
            case 429: return "请求太频繁或额度已用完（429）"
            case 400...499: return "请求被拒绝（\(code)）\(detail)"
            case 500...599: return "服务暂时不可用（\(code)），稍后再试"
            default: return "请求失败（\(code)）\(detail)"
            }
        case .stream(let message):
            return "服务返回错误：\(message.prefix(160))"
        case .invalidResponse:
            return "返回的数据格式无法解析"
        case .refusal:
            return "模型拒绝回答这个问题，换个问法或换个模型试试"
        }
    }

    var isAuthError: Bool {
        if case .http(let code, _) = self { return code == 401 || code == 403 }
        return false
    }
}

/// One client for every provider: OpenAI-compatible Chat Completions and Anthropic Messages.
final class LLMClient {
    static let shared = LLMClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    // MARK: Chat

    func stream(system: String,
                messages: [LLMMessage],
                endpoint: LLMEndpoint,
                maxTokens: Int = 1500,
                onDelta: @escaping (String) -> Void) async throws {
        if ProcessInfo.processInfo.environment["LOADLENS_AI_MOCK"] == "1" {
            try await mockStream(onDelta: onDelta)
            return
        }
        if endpoint.preset.requiresKey && (endpoint.apiKey ?? "").isEmpty
            && endpoint.preset.id != ProviderPreset.custom {
            throw LLMError.notConfigured
        }

        switch endpoint.style {
        case .openAI:
            try await streamOpenAI(system: system, messages: messages, endpoint: endpoint,
                                   maxTokens: maxTokens, onDelta: onDelta)
        case .anthropic:
            try await streamAnthropic(system: system, messages: messages, endpoint: endpoint,
                                      maxTokens: maxTokens, onDelta: onDelta)
        }
    }

    /// Sends a tiny request and returns the reply, for the settings page.
    func test(endpoint: LLMEndpoint) async throws -> String {
        var reply = ""
        try await stream(system: "你是连通性测试助手。",
                         messages: [LLMMessage(role: "user", content: "请只回复：连接成功")],
                         endpoint: endpoint,
                         maxTokens: 1024) { reply += $0 }
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Models

    func listModels(endpoint: LLMEndpoint) async throws -> [String] {
        let url: URL
        switch endpoint.style {
        case .openAI: url = try join(endpoint.baseURL, "models")
        case .anthropic: url = try anthropicURL(endpoint.baseURL, "models?limit=100")
        }
        var request = URLRequest(url: url)
        applyAuth(&request, endpoint: endpoint)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, errorMessage(from: data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse
        }
        // OpenAI / Anthropic: {"data":[{"id":...}]}; Ollama native style: {"models":[{"name":...}]}
        let items = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) ?? []
        return items.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
    }

    // MARK: OpenAI-compatible

    private func streamOpenAI(system: String, messages: [LLMMessage], endpoint: LLMEndpoint,
                              maxTokens: Int, onDelta: @escaping (String) -> Void) async throws {
        var request = URLRequest(url: try join(endpoint.baseURL, "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, endpoint: endpoint)

        var body: [String: Any] = [
            "model": endpoint.model,
            "stream": true,
            "messages": [["role": "system", "content": system]]
                + messages.map { ["role": $0.role, "content": $0.content] }
        ]
        if endpoint.preset.openAIReasoningParams {
            body["max_completion_tokens"] = maxTokens * 3
        } else {
            body["max_tokens"] = maxTokens
            body["temperature"] = 0.3
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await consumeSSE(request) { json in
            if let error = json["error"] as? [String: Any] {
                throw LLMError.stream(error["message"] as? String ?? "未知错误")
            }
            guard let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let text = delta["content"] as? String, !text.isEmpty else { return }
            onDelta(text)
        }
    }

    // MARK: Anthropic

    private func streamAnthropic(system: String, messages: [LLMMessage], endpoint: LLMEndpoint,
                                 maxTokens: Int, onDelta: @escaping (String) -> Void) async throws {
        var request = URLRequest(url: try anthropicURL(endpoint.baseURL, "messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, endpoint: endpoint)

        // Thinking tokens count toward max_tokens on current Claude models, so leave headroom.
        var body: [String: Any] = [
            "model": endpoint.model,
            "max_tokens": max(maxTokens * 4, 8000),
            "stream": true,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        // On Anthropic's own API, let a declined request be retried on another model server-side.
        if endpoint.host == "api.anthropic.com", Self.fallbackModels.contains(endpoint.model) {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await consumeSSE(request) { json in
            switch json["type"] as? String {
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    onDelta(text)
                }
            case "message_delta":
                if let delta = json["delta"] as? [String: Any],
                   delta["stop_reason"] as? String == "refusal" {
                    throw LLMError.refusal
                }
            case "error":
                let error = json["error"] as? [String: Any]
                throw LLMError.stream(error?["message"] as? String ?? "未知错误")
            default:
                break
            }
        }
    }

    private static let fallbackModels: Set<String> = [
        "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"
    ]

    // MARK: Agent (tool calling)

    enum AgentEvent {
        case text(String)
        case toolStarted(id: String, name: String, arguments: [String: Any])
        case toolFinished(id: String)
    }

    /// Chat with tools: the model may call read-only lookups, we run them and feed results back,
    /// until it answers in text. Falls back to plain chat if the model doesn't support tools.
    func runAgent(system: String,
                  messages: [LLMMessage],
                  endpoint: LLMEndpoint,
                  tools: [ToolSpec],
                  maxRounds: Int = 6,
                  execute: @escaping (String, [String: Any]) async -> String,
                  onEvent: @escaping (AgentEvent) -> Void) async throws {
        if ProcessInfo.processInfo.environment["LOADLENS_AI_MOCK"] == "1" {
            try await mockStream { onEvent(.text($0)) }
            return
        }
        if endpoint.preset.requiresKey && (endpoint.apiKey ?? "").isEmpty
            && endpoint.preset.id != ProviderPreset.custom {
            throw LLMError.notConfigured
        }
        let key = "\(endpoint.baseURL)|\(endpoint.model)"
        if tools.isEmpty || noToolSupport.contains(key) {
            try await stream(system: system, messages: messages, endpoint: endpoint, maxTokens: 2000) { onEvent(.text($0)) }
            return
        }
        do {
            switch endpoint.style {
            case .openAI:
                try await agentOpenAI(system: system, history: messages, endpoint: endpoint, tools: tools,
                                      maxRounds: maxRounds, execute: execute, onEvent: onEvent)
            case .anthropic:
                try await agentAnthropic(system: system, history: messages, endpoint: endpoint, tools: tools,
                                         maxRounds: maxRounds, execute: execute, onEvent: onEvent)
            }
        } catch LLMError.http(let code, let message) where code == 400 || code == 422 {
            // Some models / gateways reject the tools parameter; remember and answer without tools.
            let lowered = message.lowercased()
            guard lowered.contains("tool") || lowered.contains("function") else {
                throw LLMError.http(code, message)
            }
            noToolSupport.insert(key)
            try await stream(system: system, messages: messages, endpoint: endpoint, maxTokens: 2000) { onEvent(.text($0)) }
        }
    }

    private var noToolSupport = Set<String>()

    // OpenAI-compatible: tools / tool_calls / role "tool"

    private func agentOpenAI(system: String, history: [LLMMessage], endpoint: LLMEndpoint, tools: [ToolSpec],
                             maxRounds: Int,
                             execute: @escaping (String, [String: Any]) async -> String,
                             onEvent: @escaping (AgentEvent) -> Void) async throws {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
            + history.map { ["role": $0.role, "content": $0.content] }
        let toolDefs: [[String: Any]] = tools.map {
            ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters]]
        }

        for round in 0..<maxRounds {
            let lastRound = round == maxRounds - 1
            var request = URLRequest(url: try join(endpoint.baseURL, "chat/completions"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyAuth(&request, endpoint: endpoint)
            var body: [String: Any] = ["model": endpoint.model, "stream": true, "messages": messages,
                                       "tools": toolDefs, "tool_choice": lastRound ? "none" : "auto"]
            if endpoint.preset.openAIReasoningParams {
                body["max_completion_tokens"] = 8000
            } else {
                body["max_tokens"] = 2000
                body["temperature"] = 0.3
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            var text = ""
            var reasoning = ""
            var calls: [Int: (id: String, name: String, arguments: String)] = [:]
            try await consumeSSE(request) { json in
                if let error = json["error"] as? [String: Any] {
                    throw LLMError.stream(error["message"] as? String ?? "未知错误")
                }
                guard let choice = (json["choices"] as? [[String: Any]])?.first,
                      let delta = choice["delta"] as? [String: Any] else { return }
                if let piece = delta["content"] as? String, !piece.isEmpty {
                    text += piece
                    onEvent(.text(piece))
                }
                if let piece = delta["reasoning_content"] as? String { reasoning += piece }
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = call["index"] as? Int ?? 0
                    var entry = calls[index] ?? ("", "", "")
                    if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
                    if let function = call["function"] as? [String: Any] {
                        if let name = function["name"] as? String { entry.name += name }
                        if let arguments = function["arguments"] as? String { entry.arguments += arguments }
                    }
                    calls[index] = entry
                }
            }

            let ordered = calls.sorted { $0.key < $1.key }.map(\.value).filter { !$0.name.isEmpty }
            if ordered.isEmpty { return }

            var assistant: [String: Any] = [
                "role": "assistant",
                "content": text.isEmpty ? NSNull() : text,
                "tool_calls": ordered.enumerated().map { index, call in
                    ["id": call.id.isEmpty ? "call_\(round)_\(index)" : call.id, "type": "function",
                     "function": ["name": call.name, "arguments": call.arguments.isEmpty ? "{}" : call.arguments]]
                }
            ]
            // Reasoning models (e.g. DeepSeek thinking mode) expect their reasoning back during tool calls.
            if !reasoning.isEmpty { assistant["reasoning_content"] = reasoning }
            messages.append(assistant)

            for (index, call) in ordered.enumerated() {
                let id = call.id.isEmpty ? "call_\(round)_\(index)" : call.id
                let output: String
                if let arguments = Self.parseArguments(call.arguments) {
                    onEvent(.toolStarted(id: id, name: call.name, arguments: arguments))
                    output = await execute(call.name, arguments)
                    onEvent(.toolFinished(id: id))
                } else {
                    output = #"{"error":"INVALID_JSON：参数不是合法的 JSON，请重新调用"}"#
                }
                messages.append(["role": "tool", "tool_call_id": id, "content": output])
            }
        }
    }

    // Anthropic Messages: tool_use / tool_result, thinking blocks passed back unchanged

    private func agentAnthropic(system: String, history: [LLMMessage], endpoint: LLMEndpoint, tools: [ToolSpec],
                                maxRounds: Int,
                                execute: @escaping (String, [String: Any]) async -> String,
                                onEvent: @escaping (AgentEvent) -> Void) async throws {
        var messages: [[String: Any]] = history.map { ["role": $0.role, "content": $0.content] }
        let official = endpoint.host == "api.anthropic.com"
        let toolDefs: [[String: Any]] = tools.map { tool in
            var def: [String: Any] = ["name": tool.name, "description": tool.description, "input_schema": tool.parameters]
            // Stream tool arguments as they are generated (official API only; gateways may reject it).
            if official { def["eager_input_streaming"] = true }
            return def
        }

        for round in 0..<maxRounds {
            let lastRound = round == maxRounds - 1
            var request = URLRequest(url: try anthropicURL(endpoint.baseURL, "messages"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            applyAuth(&request, endpoint: endpoint)
            var body: [String: Any] = ["model": endpoint.model, "max_tokens": 16000, "stream": true,
                                       "system": system, "messages": messages, "tools": toolDefs]
            if lastRound { body["tool_choice"] = ["type": "none"] }
            if official, Self.fallbackModels.contains(endpoint.model) {
                body["fallbacks"] = "default"
                request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            // Rebuild every content block (thinking, text, tool_use…) so the turn can be sent back as-is.
            var blocks: [Int: [String: Any]] = [:]
            var partialJSON: [Int: String] = [:]
            var stopReason = ""
            try await consumeSSE(request) { json in
                let index = json["index"] as? Int ?? 0
                switch json["type"] as? String {
                case "content_block_start":
                    blocks[index] = json["content_block"] as? [String: Any] ?? [:]
                case "content_block_delta":
                    guard let delta = json["delta"] as? [String: Any] else { return }
                    var block = blocks[index] ?? [:]
                    switch delta["type"] as? String {
                    case "text_delta":
                        let piece = delta["text"] as? String ?? ""
                        block["text"] = (block["text"] as? String ?? "") + piece
                        onEvent(.text(piece))
                    case "thinking_delta":
                        block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                    case "signature_delta":
                        block["signature"] = delta["signature"] as? String ?? ""
                    case "input_json_delta":
                        partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                    default:
                        break
                    }
                    blocks[index] = block
                case "content_block_stop":
                    if var block = blocks[index], block["type"] as? String == "tool_use" {
                        let raw = partialJSON[index] ?? ""
                        if raw.isEmpty {
                            if block["input"] == nil { block["input"] = [String: Any]() }
                        } else if let parsed = Self.parseArguments(raw) {
                            block["input"] = parsed
                        } else {
                            block["input"] = [String: Any]()
                            block["_invalid"] = true
                        }
                        blocks[index] = block
                    }
                case "message_delta":
                    if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                        stopReason = reason
                    }
                case "error":
                    let error = json["error"] as? [String: Any]
                    throw LLMError.stream(error?["message"] as? String ?? "未知错误")
                default:
                    break
                }
            }

            if stopReason == "refusal" { throw LLMError.refusal }
            let content = blocks.sorted { $0.key < $1.key }.map(\.value)
            let toolUses = content.filter { $0["type"] as? String == "tool_use" }
            // Only run tools when the turn actually ended to call them (not cut off by max_tokens).
            guard stopReason == "tool_use", !toolUses.isEmpty else { return }

            messages.append(["role": "assistant",
                             "content": content.map { block in block.filter { $0.key != "_invalid" } }])
            var results: [[String: Any]] = []
            for use in toolUses {
                let id = use["id"] as? String ?? ""
                let name = use["name"] as? String ?? ""
                if use["_invalid"] as? Bool == true {
                    results.append(["type": "tool_result", "tool_use_id": id, "is_error": true,
                                    "content": "INVALID_JSON：参数不是合法的 JSON，请重新调用"])
                    continue
                }
                let arguments = use["input"] as? [String: Any] ?? [:]
                onEvent(.toolStarted(id: id, name: name, arguments: arguments))
                let output = await execute(name, arguments)
                onEvent(.toolFinished(id: id))
                results.append(["type": "tool_result", "tool_use_id": id, "content": output])
            }
            messages.append(["role": "user", "content": results])
        }
    }

    private static func parseArguments(_ raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    // MARK: Plumbing

    private func applyAuth(_ request: inout URLRequest, endpoint: LLMEndpoint) {
        guard let key = endpoint.apiKey, !key.isEmpty else {
            if endpoint.style == .anthropic {
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            }
            return
        }
        switch endpoint.style {
        case .openAI:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if endpoint.preset.id == "openrouter" {
                request.setValue("LoadLens", forHTTPHeaderField: "X-Title")
            }
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
    }

    /// Reads `data:` lines from a Server-Sent Events response and hands each JSON object to `handle`.
    private func consumeSSE(_ request: URLRequest, handle: ([String: Any]) throws -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }

        if http.statusCode != 200 {
            var raw = Data()
            for try await byte in bytes {
                raw.append(byte)
                if raw.count > 8_000 { break }
            }
            throw LLMError.http(http.statusCode, errorMessage(from: raw))
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            try handle(json)
        }
    }

    private func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = json["error"] as? String { return message }
            if let message = json["message"] as? String { return message }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func join(_ base: String, _ path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        // Accept a full endpoint pasted by mistake.
        for suffix in ["/chat/completions", "/models"] where trimmed.hasSuffix(suffix) {
            trimmed.removeLast(suffix.count)
        }
        guard let url = URL(string: trimmed + "/" + path), url.scheme?.hasPrefix("http") == true else {
            throw LLMError.badURL(base)
        }
        return url
    }

    /// Anthropic paths live under /v1; accept the base URL with or without it.
    private func anthropicURL(_ base: String, _ path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/messages") { trimmed.removeLast("/messages".count) }
        if !trimmed.hasSuffix("/v1") { trimmed += "/v1" }
        return try join(trimmed, path)
    }

    private func mockStream(onDelta: @escaping (String) -> Void) async throws {
        let text = """
        **结论：电脑有点忙，但不危险。** 最明显的占用来自 ZCode（约 55% 的一个核心）和窗口合成（约 30%），内存交换区 3.6 GB，属于偏紧。

        建议：
        1. 关掉暂时不用的对话窗口，尤其是开着但没在用的 AI 客户端；
        2. 少开几个浏览器标签，减轻窗口合成的压力；
        3. 如果还觉得热，**重启一次**能同时清掉交换区和显卡的累积状态。
        """
        for character in text {
            try Task.checkCancellation()
            onDelta(String(character))
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}
