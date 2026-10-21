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
