import Foundation

/// Answers learned from the cloud model (or, later, from the user), keyed by the names that
/// identify an event. One Mac sees the same apps and folders again and again, so the more it is
/// used, the more events are answered locally: the "变易 becomes 不易" idea, as a lookup table.
final class AnswerMemory {
    struct Entry: Codable {
        let category: String
        /// "cloud" or "user".
        let source: String
        let learnedAt: Date
        var hits: Int
    }

    let url: URL
    private(set) var entries: [String: Entry] = [:]

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let suite = ProcessInfo.processInfo.environment["LOADLENS_SETTINGS_SUITE"]
        return base.appendingPathComponent("LoadLens", isDirectory: true)
            .appendingPathComponent(suite.map { "answer-memory.\($0).json" } ?? "answer-memory.json")
    }

    /// Events without a named writer have nothing to remember them by.
    static func key(for facts: DiskEventFacts) -> String? {
        if facts.path == nil, facts.writers?.first == nil { return nil }
        return facts.names.lowercased()
    }

    func lookup(_ facts: DiskEventFacts) -> Triage.Category? {
        guard let key = Self.key(for: facts), var entry = entries[key],
              let category = Triage.Category(rawValue: entry.category) else { return nil }
        entry.hits += 1
        entries[key] = entry
        return category
    }

    func remember(_ facts: DiskEventFacts, category: Triage.Category, source: String) {
        guard let key = Self.key(for: facts) else { return }
        entries[key] = Entry(category: category.rawValue, source: source, learnedAt: Date(), hits: 0)
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            NSLog("LoadLens: could not save answer memory: %@", error.localizedDescription)
        }
    }
}

/// Something bigger to ask when the local model is unsure.
protocol CloudJudge {
    func category(for facts: DiskEventFacts) async throws -> Triage.Category
}

/// Asks the model service configured in "AI 模型设置". It receives the event description only
/// (process / folder names and sizes), never file contents.
struct LLMCloudJudge: CloudJudge {
    enum Failure: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            if case .unreadable(let text) = self { return "云端模型的回答读不懂：\(text.prefix(80))" }
            return nil
        }
    }

    func category(for facts: DiskEventFacts) async throws -> Triage.Category {
        var reply = ""
        try await LLMClient.shared.stream(system: Triage.categoryPrompt,
                                          messages: [LLMMessage(role: "user", content: facts.description)],
                                          endpoint: AIConfigStore.shared.endpoint(),
                                          // Generous: models that "think" first spend part of this before answering.
                                          maxTokens: 1024) { reply += $0 }
        // Accept the JSON answer; failing that, the first category name mentioned.
        if let category = Triage.parseCategory(reply) { return category }
        throw Failure.unreadable(reply)
    }
}

/// The five layers, cheapest first; the first one that can decide, decides.
final class HybridTriage {
    enum Source: String {
        case rule = "规则"
        case memory = "记忆"
        case local = "本地模型"
        case cloud = "云端"
        case fallback = "兜底"
    }

    struct Result {
        let notify: Bool
        let category: Triage.Category?
        let source: Source
        /// The local model's confidence, when it was consulted.
        let localConfidence: Double?
    }

    let local: DecisionModel?
    let memory: AnswerMemory
    let cloud: CloudJudge?
    /// Below this confidence the local model's answer is not trusted.
    let threshold: Double

    init(local: DecisionModel?, memory: AnswerMemory, cloud: CloudJudge?, threshold: Double = 0.7) {
        self.local = local
        self.memory = memory
        self.cloud = cloud
        self.threshold = threshold
    }

    func decide(_ facts: DiskEventFacts) async -> Result {
        // 1. Low space is never a judgement call.
        if Triage.hardRule(facts) != nil {
            return Result(notify: true, category: nil, source: .rule, localConfidence: nil)
        }
        // 2. Asked before.
        if let category = memory.lookup(facts) {
            return Result(notify: category.notify, category: category, source: .memory, localConfidence: nil)
        }
        // 3. The small local model, when it is sure.
        var confidence: Double?
        if let local, let decision = try? local.decide(facts) {
            confidence = decision.confidence
            if decision.confidence >= threshold {
                return Result(notify: decision.category.notify, category: decision.category, source: .local,
                              localConfidence: decision.confidence)
            }
        }
        // 4. Ask the cloud, and remember the answer.
        if let cloud, let category = try? await cloud.category(for: facts) {
            memory.remember(facts, category: category, source: "cloud")
            return Result(notify: category.notify, category: category, source: .cloud, localConfidence: confidence)
        }
        // 5. Offline or not configured: better one notification too many than a missed problem.
        return Result(notify: true, category: nil, source: .fallback, localConfidence: confidence)
    }
}

extension Triage {
    /// Reads {"category": "..."} from a model's reply, or failing that the first category name in it.
    static func parseCategory(_ text: String) -> Category? {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
           let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
           let name = object["category"] as? String, let category = Category(rawValue: name) {
            return category
        }
        let lowered = text.lowercased()
        return Category.allCases
            .compactMap { category in lowered.range(of: category.rawValue).map { (category, $0.lowerBound) } }
            .min { $0.1 < $1.1 }?.0
    }
}
