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

/// One judged event, shown in the settings window whether or not it was notified.
struct TriageRecord: Identifiable {
    let id = UUID()
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
    @Published private(set) var records: [TriageRecord] = []

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
    }

    /// Call on the main thread when an alert rule fires.
    func handle(facts: DiskEventFacts, title: String, body: String) {
        let rules = settings
        let cloudReady = rules.askCloud && AIConfigStore.shared.isReady
        let key = AnswerMemory.key(for: facts)

        guard rules.useLocal || cloudReady else {
            deliver(TriageRecord(date: Date(), title: title, body: body, notified: true, source: nil,
                                 category: nil, confidence: nil, key: key))
            return
        }

        queue.async { [self] in
            let triage = HybridTriage(local: rules.useLocal ? HelperProcessJudge() : nil, memory: memory,
                                      cloud: cloudReady ? LLMCloudJudge() : nil, threshold: rules.threshold)
            let first = triage.decideLocally(facts)
            if let result = first.result {
                deliver(record(result, title: title, body: body, key: key))
                return
            }
            // Only the cloud is slow; ask it outside the queue, then finish on the queue.
            Task {
                let category = try? await LLMCloudJudge().category(for: facts)
                self.queue.async {
                    let result = triage.finish(facts, cloud: category, localConfidence: first.confidence)
                    self.deliver(self.record(result, title: title, body: body, key: key))
                }
            }
        }
    }

    /// The user says this kind of event should (or should not) be notified from now on.
    func correct(_ id: UUID, notify: Bool) {
        guard let index = records.firstIndex(where: { $0.id == id }), let key = records[index].key else { return }
        records[index].corrected = notify
        queue.async { [memory] in memory.correct(key: key, notify: notify) }
    }

    /// Layers 1–3 through the helper process, for the `--triage-check` self-test (no notification, no memory).
    func checkLocally(_ facts: DiskEventFacts) -> HybridTriage.Result? {
        queue.sync {
            let scratch = AnswerMemory(url: FileManager.default.temporaryDirectory.appendingPathComponent("loadlens-check.json"))
            return HybridTriage(local: HelperProcessJudge(), memory: scratch, cloud: nil, threshold: settings.threshold)
                .decideLocally(facts).result
        }
    }

    // MARK: Private

    private func record(_ result: HybridTriage.Result, title: String, body: String, key: String?) -> TriageRecord {
        TriageRecord(date: Date(), title: title, body: body, notified: result.notify, source: result.source,
                     category: result.category, confidence: result.localConfidence, key: key)
    }

    private func deliver(_ record: TriageRecord) {
        DispatchQueue.main.async { [self] in
            records.insert(record, at: 0)
            if records.count > 30 { records.removeLast() }
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
