import Foundation
import llama

/// A small language model running inside the app through llama.cpp (Metal on Apple silicon).
///
/// The three ideas worth reading this file for:
/// 1. **KV cache prefix reuse** (`generate`): the model keeps the attention keys/values of every
///    token it has read. When the next prompt starts with the same tokens (same system prompt,
///    same conversation so far), only the new tail is computed. This is prefix caching, the
///    single-conversation version of what vLLM / SGLang do across users.
/// 2. **Prefill vs decode**: reading the prompt processes many tokens per call (compute-bound);
///    writing the answer produces one token per call (memory-bound). `Stats` times them apart.
/// 3. **Sampling** (`makeSampler`): the model only outputs scores for every token in its
///    vocabulary; a chain of filters turns those scores into one chosen token.
///
/// Not thread-safe: use one instance from one serial queue.
final class LocalModel {
    struct Sampling {
        /// 0 = always take the most likely token (greedy, fully repeatable).
        var temperature: Float = 0.7
        /// Keep only the k most likely tokens...
        var topK: Int32 = 40
        /// ...then the smallest set whose probabilities add up to p...
        var topP: Float = 0.9
        /// ...then drop tokens less likely than minP × the best token.
        var minP: Float = 0.05
        /// > 1 makes recently used tokens less likely, to avoid loops.
        var repeatPenalty: Float = 1.1
        var seed: UInt32 = 42
        /// A GBNF grammar (rule `root`). Tokens that would break it are removed before choosing,
        /// so the output is guaranteed to match: constrained decoding instead of asking nicely.
        var grammar: String?

        static let greedy = Sampling(temperature: 0)
    }

    struct Stats {
        /// Tokens in the full prompt.
        var promptTokens = 0
        /// Of those, how many were already in the KV cache and were not computed again.
        var reusedTokens = 0
        var generatedTokens = 0
        var prefillSeconds: Double = 0
        var decodeSeconds: Double = 0

        var prefillTokensPerSecond: Double {
            prefillSeconds > 0 ? Double(promptTokens - reusedTokens) / prefillSeconds : 0
        }
        var decodeTokensPerSecond: Double {
            decodeSeconds > 0 ? Double(generatedTokens) / decodeSeconds : 0
        }
    }

    enum LocalModelError: LocalizedError {
        case loadFailed(String)
        case contextFailed
        case tokenizeFailed
        case promptTooLong(tokens: Int, limit: Int)
        case decodeFailed(Int32)
        case templateFailed

        var errorDescription: String? {
            switch self {
            case .loadFailed(let path): return "无法加载本地模型：\(path)"
            case .contextFailed: return "本地模型初始化失败（内存不足？）"
            case .tokenizeFailed: return "无法把文字转换成模型的词元"
            case .promptTooLong(let tokens, let limit): return "内容太长：\(tokens) 个词元，上限 \(limit)"
            case .decodeFailed(let code): return "本地模型计算失败（代码 \(code)）"
            case .templateFailed: return "无法套用这个模型的对话格式"
            }
        }
    }

    let path: String
    let contextLength: Int
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let batchSize: Int
    /// Exactly the tokens whose keys/values are in the KV cache right now, in order.
    private var cachedTokens: [llama_token] = []

    static let backend: Void = {
        // llama.cpp is chatty on stderr; keep the app's output clean.
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }()

    /// - Parameters:
    ///   - contextLength: how many tokens the KV cache can hold (prompt + answer).
    ///   - gpuLayers: layers to run on the GPU; -1 = all of them.
    init(path: String, contextLength: Int = 4096, gpuLayers: Int32 = -1) throws {
        _ = Self.backend
        self.path = path

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = gpuLayers
        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw LocalModelError.loadFailed(path)
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextLength)
        contextParams.n_batch = 512
        contextParams.no_perf = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LocalModelError.contextFailed
        }

        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.contextLength = Int(llama_n_ctx(context))
        self.batchSize = Int(contextParams.n_batch)
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// e.g. "qwen2 1.5B Q4_K - Medium", plus its size on disk.
    var description: String {
        var buffer = [CChar](repeating: 0, count: 256)
        _ = llama_model_desc(model, &buffer, buffer.count)
        return "\(String(cString: buffer))，\(formatSize(llama_model_size(model)))"
    }

    // MARK: Chat

    /// Turns chat messages into the exact prompt text this model was trained on
    /// (each model family marks "system / user / assistant" turns with its own special tokens).
    func chatPrompt(_ messages: [(role: String, content: String)]) throws -> String {
        let template = llama_model_chat_template(model, nil)
        let roles = messages.map { strdup($0.role) }
        let contents = messages.map { strdup($0.content) }
        defer { (roles + contents).forEach { free($0) } }
        var chat = zip(roles, contents).map { llama_chat_message(role: UnsafePointer($0), content: UnsafePointer($1)) }

        var capacity = max(messages.reduce(0) { $0 + $1.content.utf8.count } * 2, 256)
        for _ in 0..<2 {
            var buffer = [CChar](repeating: 0, count: capacity)
            let length = llama_chat_apply_template(template, &chat, chat.count, true, &buffer, Int32(capacity))
            guard length >= 0 else { throw LocalModelError.templateFailed }
            if Int(length) <= capacity {
                return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            capacity = Int(length)
        }
        throw LocalModelError.templateFailed
    }

    // MARK: Generating

    /// Generates a reply to `prompt` (already formatted with `chatPrompt`).
    /// `onText` receives the answer piece by piece; return false from it to stop early.
    @discardableResult
    func generate(prompt: String,
                  maxTokens: Int = 256,
                  sampling: Sampling = Sampling(),
                  onText: (String) -> Bool = { _ in true }) throws -> (text: String, stats: Stats) {
        var stats = Stats()
        let tokens = try tokenize(prompt)
        guard !tokens.isEmpty else { throw LocalModelError.tokenizeFailed }
        stats.promptTokens = tokens.count
        guard tokens.count + maxTokens <= contextLength else {
            throw LocalModelError.promptTooLong(tokens: tokens.count + maxTokens, limit: contextLength)
        }

        // 1. Prefix reuse: keep the part of the KV cache that matches the new prompt.
        var reuse = zip(cachedTokens, tokens).prefix { $0 == $1 }.count
        // We need the model's scores after the last prompt token, so compute at least that one.
        if reuse == tokens.count { reuse -= 1 }
        let memory = llama_get_memory(context)
        // Forget everything after the shared prefix (sequence 0, positions reuse..end).
        llama_memory_seq_rm(memory, 0, llama_pos(reuse), -1)
        cachedTokens.removeSubrange(reuse...)
        stats.reusedTokens = reuse

        // 2. Prefill: feed the new part of the prompt, up to `batchSize` tokens per call.
        let prefillStart = Date()
        var position = reuse
        while position < tokens.count {
            let end = min(position + batchSize, tokens.count)
            try decode(Array(tokens[position..<end]))
            position = end
        }
        // llama_decode only queues the work on the GPU and returns at once (the CPU runs ahead,
        // the GPU keeps working). Wait for it, or the clock measures queueing, not computing.
        llama_synchronize(context)
        stats.prefillSeconds = Date().timeIntervalSince(prefillStart)

        // 3. Decode: one token at a time. Each new token is fed back so the next one can see it.
        let sampler = makeSampler(sampling)
        defer { llama_sampler_free(sampler) }
        var text = ""
        var pendingBytes: [UInt8] = []
        let decodeStart = Date()

        for _ in 0..<maxTokens {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            stats.generatedTokens += 1

            // One Chinese character is often split across two or three tokens, so a single
            // token's bytes may not be valid UTF-8 yet. Only emit what decodes cleanly.
            pendingBytes += piece(token)
            let ready = Self.takeValidUTF8(&pendingBytes)
            text += ready
            if !ready.isEmpty, !onText(ready) { break }

            try decode([token])
        }
        stats.decodeSeconds = Date().timeIntervalSince(decodeStart)
        return (text, stats)
    }

    /// Forget the whole KV cache (e.g. before comparing timings from a cold start).
    func clearCache() {
        llama_memory_clear(llama_get_memory(context), true)
        cachedTokens.removeAll()
    }

    /// The filter chain applied to the model's scores for every generated token.
    private func makeSampler(_ s: Sampling) -> UnsafeMutablePointer<llama_sampler> {
        var params = llama_sampler_chain_default_params()
        params.no_perf = true
        let chain = llama_sampler_chain_init(params)!
        if let grammar = s.grammar, let constraint = llama_sampler_init_grammar(vocab, grammar, "root") {
            llama_sampler_chain_add(chain, constraint)
        }
        if s.repeatPenalty != 1 {
            // Look back over the last 64 tokens.
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, s.repeatPenalty, 0, 0))
        }
        if s.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_top_k(s.topK))
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(s.topP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(s.minP, 1))
            // Temperature reshapes what is left: < 1 sharpens toward the top choice, > 1 flattens.
            llama_sampler_chain_add(chain, llama_sampler_init_temp(s.temperature))
            // Finally draw one token at random according to the remaining probabilities.
            llama_sampler_chain_add(chain, llama_sampler_init_dist(s.seed))
        }
        return chain
    }

    // MARK: Low level

    func tokenize(_ text: String) throws -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 8)
        var count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        }
        guard count >= 0 else { throw LocalModelError.tokenizeFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private func decode(_ tokens: [llama_token]) throws {
        var tokens = tokens
        let result = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard result == 0 else { throw LocalModelError.decodeFailed(result) }
        cachedTokens += tokens
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(length, 0))).map { UInt8(bitPattern: $0) }
    }

    /// Removes and returns the longest valid UTF-8 prefix; an incomplete character at the end stays.
    static func takeValidUTF8(_ bytes: inout [UInt8]) -> String {
        for drop in 0...min(3, bytes.count) {
            let candidate = bytes.prefix(bytes.count - drop)
            if let text = String(bytes: candidate, encoding: .utf8) {
                bytes.removeFirst(candidate.count)
                return text
            }
        }
        return ""
    }
}
