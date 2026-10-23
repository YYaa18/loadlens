import Foundation
import llama

/// Turns a piece of text into one vector: the model reads the text once (prefill only, nothing is
/// generated) and its hidden states are pooled into a single list of numbers that captures meaning.
final class EmbeddingModel {
    enum Pooling: String, Codable {
        /// Average over all tokens.
        case mean
        /// The last token's state (for a left-to-right model, the one that has "seen" everything).
        case last
        /// The first, special [CLS] token (how BERT-style embedding models such as bge are trained).
        case cls

        var llama: llama_pooling_type {
            switch self {
            case .mean: return LLAMA_POOLING_TYPE_MEAN
            case .last: return LLAMA_POOLING_TYPE_LAST
            case .cls: return LLAMA_POOLING_TYPE_CLS
            }
        }
    }

    let path: String
    let pooling: Pooling
    let dimensions: Int
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let maxTokens: Int

    /// - Parameter maxTokens: longest text it accepts. The work buffer grows with it, so keep it
    ///   small for short inputs (an event's names are ~20 tokens).
    /// - Parameter useGPU: false keeps everything on the CPU. A tiny model like bge-small is just
    ///   as fast there, and the process never pays the ~40MB the GPU runtime keeps after first use.
    init(path: String, pooling: Pooling = .mean, useGPU: Bool = true, maxTokens: Int = 512) throws {
        _ = LocalModel.backend
        self.path = path
        self.pooling = pooling
        self.maxTokens = maxTokens

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = useGPU ? -1 : 0
        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw LocalModel.LocalModelError.loadFailed(path)
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(maxTokens)
        // Pooling needs the whole text in one micro-batch.
        contextParams.n_batch = UInt32(maxTokens)
        contextParams.n_ubatch = UInt32(maxTokens)
        contextParams.embeddings = true
        contextParams.pooling_type = pooling.llama
        contextParams.no_perf = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LocalModel.LocalModelError.contextFailed
        }
        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.dimensions = Int(llama_model_n_embd(model))
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// The text's vector, scaled to length 1 so only its direction (its meaning) matters.
    func embed(_ text: String) throws -> [Float] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 8)
        let count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        guard count > 0 else { throw LocalModel.LocalModelError.tokenizeFailed }
        guard Int(count) <= maxTokens else {
            throw LocalModel.LocalModelError.promptTooLong(tokens: Int(count), limit: maxTokens)
        }
        tokens = Array(tokens.prefix(Int(count)))

        // Every text is independent: start from an empty cache.
        llama_memory_clear(llama_get_memory(context), true)
        let result = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard result == 0 else { throw LocalModel.LocalModelError.decodeFailed(result) }
        llama_synchronize(context)
        guard let pointer = llama_get_embeddings_seq(context, 0) else {
            throw LocalModel.LocalModelError.decodeFailed(-1)
        }
        let vector = Array(UnsafeBufferPointer(start: pointer, count: dimensions))
        let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        return length > 0 ? vector.map { $0 / length } : vector
    }
}

/// A small, Jev-style decision function: a fixed set of answers declared in advance, each
/// returned with a probability, so the caller can trust confident answers and fall back on the rest.
///
/// It is a linear classifier ("probe") on top of the embedding: score = W·x + b per category,
/// softmax turns the scores into probabilities. Trained by train/train_probe.py.
final class DecisionModel {
    struct Probe: Codable {
        let labels: [String]
        let pooling: EmbeddingModel.Pooling
        /// Per-dimension standardisation learned from the training set.
        let mean: [Float]
        let scale: [Float]
        /// One row of weights per label.
        let weights: [[Float]]
        let bias: [Float]
        /// File name of the embedding model it was trained on (a probe only fits that model).
        let embeddingModel: String
        /// Text put before every event when embedding (the task, in words). Must match training.
        let instruction: String?
        /// Lowercase the text first. bge-small-zh's vocabulary has no capital letters: "Docker"
        /// would become [UNK] (unknown) while "docker" is a known word.
        let lowercase: Bool?
        /// "names": embed only the identifying names; otherwise the full description.
        let inputMode: String?

        /// The exact text the embedding model reads for an event.
        func input(for facts: DiskEventFacts) -> String {
            let text = (instruction ?? "") + (inputMode == "names" ? facts.names : facts.description)
            return lowercase == true ? text.lowercased() : text
        }
    }

    /// Jev's "Choice" plus "Noul" in one answer.
    struct Decision {
        let category: Triage.Category
        /// Probability of the chosen category: how sure the model is.
        let confidence: Double
        let probabilities: [(category: Triage.Category, probability: Double)]
        /// Sum of probabilities of the categories the policy says to notify about.
        let notifyProbability: Double
    }

    let probe: Probe
    let embedder: EmbeddingModel
    private let categories: [Triage.Category]

    init(probePath: String, modelPath: String, useGPU: Bool = true, maxTokens: Int = 512) throws {
        guard let data = FileManager.default.contents(atPath: probePath),
              let probe = try? JSONDecoder().decode(Probe.self, from: data) else {
            throw LocalModel.LocalModelError.loadFailed(probePath)
        }
        let categories = probe.labels.compactMap(Triage.Category.init(rawValue:))
        guard categories.count == probe.labels.count, probe.weights.count == categories.count else {
            throw LocalModel.LocalModelError.loadFailed(probePath)
        }
        let embedder = try EmbeddingModel(path: modelPath, pooling: probe.pooling, useGPU: useGPU, maxTokens: maxTokens)
        guard probe.mean.count == embedder.dimensions else {
            // A probe trained on another model's vectors would give nonsense.
            throw LocalModel.LocalModelError.loadFailed("\(probePath)（与模型 \((modelPath as NSString).lastPathComponent) 不匹配）")
        }
        self.probe = probe
        self.embedder = embedder
        self.categories = categories
    }

    func decide(_ facts: DiskEventFacts) throws -> Decision {
        let x = try embedder.embed(probe.input(for: facts))
        let standardised = zip(zip(x, probe.mean), probe.scale).map { ($0.0 - $0.1) / $1 }
        let scores = zip(probe.weights, probe.bias).map { row, b in
            zip(row, standardised).reduce(b) { $0 + $1.0 * $1.1 }
        }
        // Softmax (shifted by the max for numerical safety).
        let top = scores.max() ?? 0
        let exps = scores.map { Double(exp($0 - top)) }
        let total = exps.reduce(0, +)
        let probabilities = zip(categories, exps).map { ($0, $1 / total) }.sorted { $0.1 > $1.1 }
        let best = probabilities[0]
        let notify = probabilities.filter { $0.0.notify }.reduce(0) { $0 + $1.1 }
        return Decision(category: best.0, confidence: best.1,
                        probabilities: probabilities.map { (category: $0.0, probability: $0.1) },
                        notifyProbability: notify)
    }
}
