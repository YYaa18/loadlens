import Foundation
import AppKit

struct TriageSettings: Codable, Equatable {
    /// Judge events with the bundled 25MB model before notifying.
    var useLocal = true
    /// When the local model is unsure, ask the model service set up in "AI 模型设置".
    /// Off by default: it sends process / folder names and sizes to that service.
    var askCloud = false
    /// Below this confidence the local model's answer is not trusted.
    var threshold: Double = 0.7
}

/// One judged event, shown in the settings window whether or not it was notified, and kept on
/// disk (raw event data included) so real events can later become training data.
struct TriageRecord: Identifiable, Codable {
    var id = UUID()
    let date: Date
    let title: String
    let body: String
    let notified: Bool
    /// nil when judging was turned off.
    let source: HybridTriage.Source?
    let category: Triage.Category?
    let confidence: Double?
    /// Memory key; nil when there is no name to remember (then it cannot be corrected).
    let key: String?
    /// The user's correction, if any: true = "notify me about this", false = "don't".
    var corrected: Bool?
    /// What the model read (names and sizes only). nil in records made before it was kept.
    var facts: DiskEventFacts?

    var explanation: String {
        guard let source else { return "未启用智能判断" }
        let why: String
        if source == .rule {
            why = "硬盘快满了"
        } else if let category {
            why = category.plainReason
        } else {
            why = "没有把握，保险起见提醒你"
        }
        let confidenceText = confidence.map { source == .local ? " \(Int(($0 * 100).rounded()))%" : "" } ?? ""
        return "\(why)（\(source.rawValue)\(confidenceText)）"
    }
}

extension HybridTriage.Source: Codable {}
extension Triage.Category: Codable {}

/// The judged events on disk: newest first, at most `limit`. Local only, like the answer memory.
struct TriageLog {
    let url: URL
    var limit = 500

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let suite = ProcessInfo.processInfo.environment["LOADLENS_SETTINGS_SUITE"]
        return base.appendingPathComponent("LoadLens", isDirectory: true)
            .appendingPathComponent(suite.map { "triage-log.\($0).json" } ?? "triage-log.json")
    }

    func load() -> [TriageRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TriageRecord].self, from: data)) ?? []
    }

    func save(_ records: [TriageRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(Array(records.prefix(limit))).write(to: url, options: .atomic)
        } catch {
            NSLog("LoadLens: could not save triage log: %@", error.localizedDescription)
        }
    }
}

/// Runs every disk alert through the five-layer decision before anything reaches the user.
/// The model runs in a helper process that exits after each judgement, so the app stays light.
final class TriageService: ObservableObject {
    static let shared = TriageService()

    @Published var settings: TriageSettings {
        didSet {
            guard settings != oldValue, let data = try? JSONEncoder().encode(settings) else { return }
            Self.store.set(data, forKey: Self.key)
        }
    }
    /// The most recent judgements, for the settings window.
    @Published private(set) var records: [TriageRecord] = []
    /// Everything kept on disk (main thread), newest first.
    private var history: [TriageRecord] = []
    private let log = TriageLog(url: TriageLog.defaultURL)
    private let saveQueue = DispatchQueue(label: "loadlens.triage.log", qos: .utility)

    private static let key = "triage"
    private static let store: UserDefaults =
        ProcessInfo.processInfo.environment["LOADLENS_SETTINGS_SUITE"]
            .flatMap { UserDefaults(suiteName: "local.loadlens.\($0)") } ?? .standard

    // Touched only on `queue`.
    private let queue = DispatchQueue(label: "loadlens.triage", qos: .utility)
    private let memory = AnswerMemory(url: AnswerMemory.defaultURL)

    private init() {
        settings = Self.store.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(TriageSettings.self, from: $0) } ?? TriageSettings()
        history = log.load()
        records = Array(history.prefix(30))
    }

    /// Call on the main thread when an alert rule fires.
    func handle(facts: DiskEventFacts, title: String, body: String) {
        let rules = settings
        let cloudReady = rules.askCloud && AIConfigStore.shared.isReady
        let key = AnswerMemory.key(for: facts)

        guard rules.useLocal || cloudReady else {
            deliver(TriageRecord(date: Date(), title: title, body: body, notified: true, source: nil,
                                 category: nil, confidence: nil, key: key, facts: facts))
            return
        }

        queue.async { [self] in
            let triage = HybridTriage(local: rules.useLocal ? HelperProcessJudge() : nil, memory: memory,
                                      cloud: cloudReady ? LLMCloudJudge() : nil, threshold: rules.threshold)
            let first = triage.decideLocally(facts)
            if let result = first.result {
                deliver(record(result, facts: facts, title: title, body: body, key: key))
                return
            }
            // Only the cloud is slow; ask it outside the queue, then finish on the queue.
            Task {
                let category = try? await LLMCloudJudge().category(for: facts)
                self.queue.async {
                    let result = triage.finish(facts, cloud: category, localConfidence: first.confidence)
                    self.deliver(self.record(result, facts: facts, title: title, body: body, key: key))
                }
            }
        }
    }

    /// The user says this kind of event should (or should not) be notified from now on.
    func correct(_ id: UUID, notify: Bool) {
        guard let index = history.firstIndex(where: { $0.id == id }), let key = history[index].key else { return }
        history[index].corrected = notify
        records = Array(history.prefix(30))
        persist()
        queue.async { [memory] in memory.correct(key: key, notify: notify) }
    }

    /// Everything kept on disk, newest first (for `--triage-log`).
    var savedRecords: [TriageRecord] { log.load() }

    /// Layers 1–3 through the helper process, for the `--triage-check` self-test (no notification, no memory).
    func checkLocally(_ facts: DiskEventFacts) -> HybridTriage.Result? {
        queue.sync {
            let scratch = AnswerMemory(url: FileManager.default.temporaryDirectory.appendingPathComponent("loadlens-check.json"))
            return HybridTriage(local: HelperProcessJudge(), memory: scratch, cloud: nil, threshold: settings.threshold)
                .decideLocally(facts).result
        }
    }

    // MARK: Private

    private func record(_ result: HybridTriage.Result, facts: DiskEventFacts, title: String, body: String,
                        key: String?) -> TriageRecord {
        TriageRecord(date: Date(), title: title, body: body, notified: result.notify, source: result.source,
                     category: result.category, confidence: result.localConfidence, key: key, facts: facts)
    }

    private func persist() {
        let snapshot = history
        saveQueue.async { [log] in log.save(snapshot) }
    }

    private func deliver(_ record: TriageRecord) {
        DispatchQueue.main.async { [self] in
            history.insert(record, at: 0)
            if history.count > log.limit { history.removeLast(history.count - log.limit) }
            records = Array(history.prefix(30))
            persist()
            if record.notified {
                Notifier.shared.send(title: record.title, body: "\(record.body)\n\(record.explanation)",
                                     triageID: record.key == nil ? nil : record.id)
            }
        }
    }

    /// The bundled model, loaded inside the helper process (`--triage-judge`).
    static func loadBundledModel() throws -> DecisionModel {
        guard let probe = Bundle.main.path(forResource: "probe", ofType: "json", inDirectory: "triage"),
              let gguf = Bundle.main.path(forResource: "bge-small-zh-q8_0", ofType: "gguf", inDirectory: "triage") else {
            throw LocalModel.LocalModelError.loadFailed("triage")
        }
        // CPU is as fast as the GPU for a model this small, and leaves the GPU alone.
        return try DecisionModel(probePath: probe, modelPath: gguf, useGPU: false, maxTokens: 128)
    }
}
