import Foundation
import SwiftUI

// MARK: - Presets

enum APIStyle: String, Codable, CaseIterable, Identifiable {
    /// `POST {base}/chat/completions`, used by most vendors and local runtimes.
    case openAI
    /// Anthropic Messages API, `POST {base}/v1/messages`.
    case anthropic

    var id: String { rawValue }
    var label: String {
        switch self {
        case .openAI: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        }
    }
}

struct ProviderPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let style: APIStyle
    let baseURL: String
    let models: [String]
    let keyURL: String?
    var requiresKey = true
    var note = ""
    /// OpenAI's newer models want `max_completion_tokens` and reject custom temperature.
    var openAIReasoningParams = false
    var tint: Color = .accentColor
    var monogram: String { String(name.prefix(1)) }

    static let custom = "custom"

    static let all: [ProviderPreset] = [
        ProviderPreset(id: "deepseek", name: "DeepSeek", style: .openAI,
                       baseURL: "https://api.deepseek.com",
                       models: ["deepseek-flash", "deepseek-v4-pro"],
                       keyURL: "https://platform.deepseek.com/api_keys",
                       note: "国内直连，价格便宜，中文表现好。",
                       tint: Color(red: 0.30, green: 0.42, blue: 0.99)),
        ProviderPreset(id: "openai", name: "OpenAI", style: .openAI,
                       baseURL: "https://api.openai.com/v1",
                       models: ["gpt-5-mini", "gpt-5", "gpt-4.1-mini"],
                       keyURL: "https://platform.openai.com/api-keys",
                       note: "需要可以访问 OpenAI 的网络环境。",
                       openAIReasoningParams: true,
                       tint: Color(red: 0.06, green: 0.64, blue: 0.50)),
        ProviderPreset(id: "anthropic", name: "Anthropic Claude", style: .anthropic,
                       baseURL: "https://api.anthropic.com",
                       models: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
                       keyURL: "https://platform.claude.com/settings/keys",
                       note: "使用 Anthropic 原生 Messages 接口。Haiku 响应最快、最便宜。",
                       tint: Color(red: 0.85, green: 0.47, blue: 0.34)),
        ProviderPreset(id: "gemini", name: "Google Gemini", style: .openAI,
                       baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                       models: ["gemini-2.5-flash", "gemini-2.5-pro"],
                       keyURL: "https://aistudio.google.com/apikey",
                       note: "通过 Gemini 的 OpenAI 兼容接口调用。",
                       tint: Color(red: 0.26, green: 0.52, blue: 0.96)),
        ProviderPreset(id: "moonshot", name: "Kimi（月之暗面）", style: .openAI,
                       baseURL: "https://api.moonshot.cn/v1",
                       models: ["kimi-k2-turbo-preview", "moonshot-v1-8k"],
                       keyURL: "https://platform.moonshot.cn/console/api-keys",
                       tint: Color(red: 0.12, green: 0.12, blue: 0.14)),
        ProviderPreset(id: "qwen", name: "通义千问", style: .openAI,
                       baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                       models: ["qwen-plus", "qwen-turbo", "qwen-max"],
                       keyURL: "https://bailian.console.aliyun.com/?apiKey=1",
                       note: "阿里云百炼的 OpenAI 兼容模式。",
                       tint: Color(red: 0.38, green: 0.30, blue: 0.95)),
        ProviderPreset(id: "zhipu", name: "智谱 GLM", style: .openAI,
                       baseURL: "https://open.bigmodel.cn/api/paas/v4",
                       models: ["glm-4.5", "glm-4-flash"],
                       keyURL: "https://open.bigmodel.cn/usercenter/apikeys",
                       tint: Color(red: 0.16, green: 0.36, blue: 0.85)),
        ProviderPreset(id: "siliconflow", name: "硅基流动", style: .openAI,
                       baseURL: "https://api.siliconflow.cn/v1",
                       models: ["deepseek-ai/DeepSeek-V3", "Qwen/Qwen2.5-72B-Instruct"],
                       keyURL: "https://cloud.siliconflow.cn/account/ak",
                       note: "聚合了多家开源模型，可用「获取模型列表」查看全部。",
                       tint: Color(red: 0.49, green: 0.33, blue: 0.93)),
        ProviderPreset(id: "openrouter", name: "OpenRouter", style: .openAI,
                       baseURL: "https://openrouter.ai/api/v1",
                       models: ["openrouter/auto"],
                       keyURL: "https://openrouter.ai/keys",
                       note: "一个 Key 调用几百种模型，模型名形如 vendor/model。",
                       tint: Color(red: 0.40, green: 0.42, blue: 0.48)),
        ProviderPreset(id: "ollama", name: "Ollama（本地）", style: .openAI,
                       baseURL: "http://localhost:11434/v1",
                       models: ["qwen2.5:7b", "llama3.1:8b"],
                       keyURL: "https://ollama.com/download",
                       requiresKey: false,
                       note: "在本机运行模型，数据不出电脑。先用 ollama pull 下载模型。",
                       tint: Color(red: 0.20, green: 0.20, blue: 0.22)),
        ProviderPreset(id: custom, name: "自定义", style: .openAI,
                       baseURL: "",
                       models: [],
                       keyURL: nil,
                       note: "任何 OpenAI 兼容或 Anthropic 兼容的接口，例如公司内部网关、LM Studio、vLLM。",
                       tint: .gray)
    ]

    static func find(_ id: String) -> ProviderPreset {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - Stored config

struct ProviderConfig: Codable, Equatable {
    var baseURL: String
    var model: String
    var style: APIStyle
    /// Models returned by the provider's /models endpoint.
    var fetchedModels: [String] = []
    /// Models the user typed in.
    var customModels: [String] = []
    /// Whether a key has been saved to the keychain (so we never have to read it just to show status).
    var hasKey = false
}

struct AISettings: Codable, Equatable {
    var activeProvider: String
    var providers: [String: ProviderConfig]
}

/// Resolved, ready-to-call endpoint.
struct LLMEndpoint {
    let preset: ProviderPreset
    let style: APIStyle
    let baseURL: String
    let model: String
    let apiKey: String?

    var host: String { URL(string: baseURL)?.host ?? baseURL }
}

// MARK: - Store

final class AIConfigStore: ObservableObject {
    static let shared = AIConfigStore()

    @Published private(set) var settings: AISettings
    private var keyCache: [String: String] = [:]
    private let defaultsKey = "aiSettings.v1"
    private let mockMode = ProcessInfo.processInfo.environment["LOADLENS_AI_MOCK"] == "1"
    private let testSuite = ProcessInfo.processInfo.environment["LOADLENS_SETTINGS_SUITE"]
    private var defaults: UserDefaults {
        testSuite.flatMap { UserDefaults(suiteName: "local.loadlens.\($0)") } ?? .standard
    }

    private init() {
        let store = ProcessInfo.processInfo.environment["LOADLENS_SETTINGS_SUITE"]
            .flatMap { UserDefaults(suiteName: "local.loadlens.\($0)") } ?? .standard
        if let data = store.data(forKey: "aiSettings.v1"),
           let decoded = try? JSONDecoder().decode(AISettings.self, from: data) {
            settings = decoded
        } else {
            settings = AISettings(activeProvider: "deepseek", providers: [:])
            migrateLegacyKey()
        }
    }

    // MARK: Reading

    var activePreset: ProviderPreset { ProviderPreset.find(settings.activeProvider) }
    var activeConfig: ProviderConfig { config(for: settings.activeProvider) }

    func config(for id: String) -> ProviderConfig {
        if let stored = settings.providers[id] { return stored }
        let preset = ProviderPreset.find(id)
        return ProviderConfig(baseURL: preset.baseURL,
                              model: preset.models.first ?? "",
                              style: preset.style)
    }

    func isConfigured(_ id: String) -> Bool {
        if mockMode { return true }
        let preset = ProviderPreset.find(id)
        let config = config(for: id)
        guard !config.baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
              !config.model.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if preset.requiresKey && id != ProviderPreset.custom { return config.hasKey }
        // Keyless services (Ollama, custom gateways) count once the user has saved settings for them.
        return settings.providers[id] != nil
    }

    var isReady: Bool { isConfigured(settings.activeProvider) }

    /// Every model we know for a provider: the selected one, presets, fetched, and custom ones.
    func models(for id: String) -> [String] {
        let config = config(for: id)
        var seen = Set<String>()
        return ([config.model] + ProviderPreset.find(id).models + config.customModels + config.fetchedModels)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var configuredProviders: [ProviderPreset] {
        ProviderPreset.all.filter { isConfigured($0.id) }
    }

    func endpoint(for id: String? = nil) -> LLMEndpoint {
        let id = id ?? settings.activeProvider
        let config = config(for: id)
        let preset = ProviderPreset.find(id)
        return LLMEndpoint(preset: preset,
                           style: id == ProviderPreset.custom ? config.style : preset.style,
                           baseURL: config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                           model: config.model.trimmingCharacters(in: .whitespacesAndNewlines),
                           apiKey: key(for: id))
    }

    var displayName: String {
        "\(activePreset.name) · \(activeConfig.model)"
    }

    // MARK: Writing

    func update(_ id: String, _ change: (inout ProviderConfig) -> Void) {
        var config = config(for: id)
        change(&config)
        settings.providers[id] = config
        persist()
    }

    func activate(_ id: String, model: String? = nil) {
        if let model { update(id) { $0.model = model } }
        settings.activeProvider = id
        persist()
    }

    @discardableResult
    func saveKey(_ value: String, for id: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Keychain.save(trimmed, account: id) else { return false }
        keyCache[id] = trimmed
        update(id) { $0.hasKey = true }
        return true
    }

    func removeKey(for id: String) {
        Keychain.delete(account: id)
        keyCache[id] = nil
        update(id) { $0.hasKey = false }
    }

    func key(for id: String) -> String? {
        if mockMode { return "mock" }
        if let env = ProcessInfo.processInfo.environment["LOADLENS_AI_KEY"], !env.isEmpty,
           id == settings.activeProvider {
            return env
        }
        if let cached = keyCache[id] { return cached }
        guard config(for: id).hasKey, let loaded = Keychain.load(account: id) else { return nil }
        keyCache[id] = loaded
        return loaded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    /// The single-provider version stored a DeepSeek key elsewhere; move it over once.
    private func migrateLegacyKey() {
        guard testSuite == nil,
              let legacy = Keychain.load(account: Keychain.legacyAccount, service: Keychain.legacyService) else {
            persist()
            return
        }
        if Keychain.save(legacy, account: "deepseek") {
            keyCache["deepseek"] = legacy
            update("deepseek") { $0.hasKey = true }
            Keychain.delete(account: Keychain.legacyAccount, service: Keychain.legacyService)
        }
        persist()
    }
}
