import Foundation

/// Answers learned from the cloud model (or, later, from the user), keyed by the names that
/// identify an event. One Mac sees the same apps and folders again and again, so the more it is
/// used, the more events are answered locally: the "变易 becomes 不易" idea, as a lookup table.
final class AnswerMemory {
    struct Entry: Codable {
        /// What the cloud said this is (nil for a pure user correction).
        let category: String?
        /// "cloud" or "user".
        let source: String
        let learnedAt: Date
        var hits: Int
        /// The user's own call ("notify me" / "don't"), which beats any category.
        var notify: Bool?
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

    func lookup(_ facts: DiskEventFacts) -> Entry? {
        guard let key = Self.key(for: facts), var entry = entries[key] else { return nil }
        entry.hits += 1
        entries[key] = entry
        return entry
    }

    func remember(_ facts: DiskEventFacts, category: Triage.Category, source: String) {
        guard let key = Self.key(for: facts) else { return }
        // Never let a cloud answer overwrite the user's correction.
        if entries[key]?.source == "user" { return }
        entries[key] = Entry(category: category.rawValue, source: source, learnedAt: Date(), hits: 0)
        save()
    }

    /// The user said whether this kind of event deserves a notification.
    func correct(key: String, notify: Bool) {
        let previous = entries[key]
        entries[key] = Entry(category: previous?.category, source: "user", learnedAt: Date(), hits: previous?.hits ?? 0,
                             notify: notify)
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

/// The local model: answers "which category, how sure".
protocol LocalJudge {
    func judge(_ facts: DiskEventFacts) throws -> (category: Triage.Category, confidence: Double)
}

extension DecisionModel: LocalJudge {
    func judge(_ facts: DiskEventFacts) throws -> (category: Triage.Category, confidence: Double) {
        let decision = try decide(facts)
        return (decision.category, decision.confidence)
    }
}

/// Runs the bundled model in a short-lived helper process (this same app, `--triage-judge`).
/// Initialising llama.cpp alone costs ~94MB that is never given back while the process lives;
/// a helper that exits after answering returns all of it, so the menu bar app stays small.
final class HelperProcessJudge: LocalJudge {
    enum Failure: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let why) = self { return why }; return nil }
    }

    func judge(_ facts: DiskEventFacts) throws -> (category: Triage.Category, confidence: Double) {
        guard let executable = Bundle.main.executableURL else { throw Failure.failed("找不到程序") }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--triage-judge"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(try JSONEncoder().encode(facts))
        try input.fileHandleForWriting.close()

        // A stuck helper must not hold up alerts forever.
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw Failure.failed("判断超时") }

        struct Answer: Decodable { let category: String; let confidence: Double }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let answer = try? JSONDecoder().decode(Answer.self, from: data),
              let category = Triage.Category(rawValue: answer.category) else {
            throw Failure.failed("判断失败：\(String(decoding: data.prefix(120), as: UTF8.self))")
        }
        return (category, answer.confidence)
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

    let local: LocalJudge?
    let memory: AnswerMemory
    let cloud: CloudJudge?
    /// Below this confidence the local model's answer is not trusted.
    let threshold: Double

    init(local: LocalJudge?, memory: AnswerMemory, cloud: CloudJudge?, threshold: Double = 0.7) {
        self.local = local
        self.memory = memory
        self.cloud = cloud
        self.threshold = threshold
    }

    func decide(_ facts: DiskEventFacts) async -> Result {
        let first = decideLocally(facts)
        if let result = first.result { return result }
        let category = try? await cloud?.category(for: facts)
        return finish(facts, cloud: category, localConfidence: first.confidence)
    }

    /// Layers 1–3, all local and quick. `result` is nil when the cloud should be asked.
    func decideLocally(_ facts: DiskEventFacts) -> (result: Result?, confidence: Double?) {
        // 1. Low space is never a judgement call.
        if Triage.hardRule(facts) != nil {
            return (Result(notify: true, category: nil, source: .rule, localConfidence: nil), nil)
        }
        // 2. Corrected by the user, or asked before.
        if let entry = memory.lookup(facts) {
            let category = entry.category.flatMap(Triage.Category.init(rawValue:))
            if let notify = entry.notify ?? category?.notify {
                return (Result(notify: notify, category: category, source: .memory, localConfidence: nil), nil)
            }
        }
        // 3. The small local model, when it is sure.
        var confidence: Double?
        if let local, let decision = try? local.judge(facts) {
            confidence = decision.confidence
            if decision.confidence >= threshold {
                return (Result(notify: decision.category.notify, category: decision.category, source: .local,
                               localConfidence: decision.confidence), confidence)
            }
        }
        return (cloud == nil ? finish(facts, cloud: nil, localConfidence: confidence) : nil, confidence)
    }

    /// Layers 4–5: use (and remember) the cloud's answer, or fall back to notifying.
    func finish(_ facts: DiskEventFacts, cloud category: Triage.Category?, localConfidence: Double?) -> Result {
        if let category {
            memory.remember(facts, category: category, source: "cloud")
            return Result(notify: category.notify, category: category, source: .cloud, localConfidence: localConfidence)
        }
        // Offline or not configured: better one notification too many than a missed problem.
        return Result(notify: true, category: nil, source: .fallback, localConfidence: localConfidence)
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
