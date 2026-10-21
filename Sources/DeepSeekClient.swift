import Foundation

struct DeepSeekMessage: Codable {
    let role: String
    let content: String
}

enum DeepSeekError: LocalizedError {
    case missingKey
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "还没有配置 DeepSeek API Key"
        case .http(let code, let message):
            switch code {
            case 401: return "API Key 无效或已过期"
            case 402: return "DeepSeek 账户余额不足"
            case 429: return "请求太频繁，请稍后再试"
            case 400...499: return "请求被拒绝（\(code)）"
            case 500...599: return "DeepSeek 服务暂时不可用（\(code)）"
            default: return message.isEmpty ? "请求失败（\(code)）" : message
            }
        case .invalidResponse:
            return "返回数据格式无法解析"
        }
    }
}

final class DeepSeekClient {
    static let shared = DeepSeekClient()
    private let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    func stream(messages: [DeepSeekMessage],
                apiKey: String,
                onDelta: @escaping (String) -> Void) async throws {
        if ProcessInfo.processInfo.environment["LOADLENS_AI_MOCK"] == "1" {
            try await mockStream(onDelta: onDelta)
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90

        let body = RequestBody(model: "deepseek-chat",
                               messages: messages,
                               stream: true,
                               temperature: 0.3,
                               maxTokens: 700)
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekError.invalidResponse
        }

        if http.statusCode != 200 {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            if let data = raw.data(using: .utf8),
               let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw DeepSeekError.http(http.statusCode, envelope.error.message)
            }
            throw DeepSeekError.http(http.statusCode, raw)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let delta = chunk.choices.first?.delta.content,
                  !delta.isEmpty else { continue }
            onDelta(delta)
        }
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

    private struct RequestBody: Encodable {
        let model: String
        let messages: [DeepSeekMessage]
        let stream: Bool
        let temperature: Double
        let maxTokens: Int

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, temperature
            case maxTokens = "max_tokens"
        }
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta
        }
        let choices: [Choice]
    }

    private struct ErrorEnvelope: Decodable {
        struct APIError: Decodable {
            let message: String
        }
        let error: APIError
    }
}
