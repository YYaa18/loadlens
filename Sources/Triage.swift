import Foundation

/// Facts about one disk event that already crossed a user's alert threshold.
/// Same shape as the cases in eval/triage-cases.json.
struct DiskEventFacts: Codable {
    struct Writer: Codable {
        let app: String
        let process: String
        let gb: Double
    }

    // fast_drop
    var minutes: Int?
    var drop_gb: Double?
    var writers: [Writer]?
    // folder_growth
    var days: Int?
    var path: String?
    var owner: String?
    var grown_gb: Double?
    var size_gb: Double?
    // both
    var free_gb: Double
    var total_gb: Double

    /// Just the names that identify the cause: the main writer (app and process), or the folder
    /// path and its owner. Small embedding models do better on this than on the full sentence,
    /// where the name is a few tokens among many.
    var names: String {
        if let path {
            return [path, owner].compactMap { $0 }.joined(separator: " ")
        }
        guard let writer = writers?.first else { return "（无写入者）" }
        return writer.app == writer.process ? writer.app : "\(writer.app) \(writer.process)"
    }

    /// Plain Chinese description, which is what the model reads.
    var description: String {
        let disk = "硬盘还剩 \(Self.gb(free_gb))（共 \(Self.gb(total_gb))）。"
        if let path, let grown_gb, let days {
            let ownerText = owner.map { "（属于 \($0)）" } ?? ""
            let size = size_gb.map { "，现在 \(Self.gb($0))" } ?? ""
            return "最近 \(days) 天，文件夹 \(path)\(ownerText) 涨了 \(Self.gb(grown_gb))\(size)。" + disk
        }
        var text = "最近 \(minutes ?? 10) 分钟，硬盘可用空间少了 \(Self.gb(drop_gb ?? 0))。" + disk
        if let writers, !writers.isEmpty {
            let names = writers.map { writer in
                let who = writer.app == writer.process ? writer.app : "\(writer.app) 里的 \(writer.process)"
                return "\(who)（\(Self.gb(writer.gb))）"
            }
            text += "这段时间写入最多的：" + names.joined(separator: "、") + "。"
        } else {
            text += "没找到明显的写入者（可能是系统进程，或已经结束的程序）。"
        }
        return text
    }

    private static func gb(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded())) GB" : String(format: "%.1f GB", value)
    }
}

/// Decides whether a disk event is worth interrupting the user for: a hard rule in code first,
/// then the local model for the judgement call, with an output the code can rely on.
enum Triage {
    /// What the model is asked in category mode: what kind of thing is this? Whether that kind
    /// deserves a notification is decided here in code, from the user's principle.
    enum Category: String, CaseIterable {
        case userFiles = "user_files"
        case userActivity = "user_activity"
        case system
        case devWork = "dev_work"
        case script
        case cache
        case log
        case appData = "app_data"
        case unknown

        /// Shown to the model; general descriptions, never the exam cases.
        var meaning: String {
            switch self {
            case .userFiles: return "用户自己的文件：文稿、影片、照片图库、邮件、下载文件夹、设备备份"
            case .userActivity: return "用户正在进行的操作：浏览器下载文件、拷贝文件、导入照片、下载模型、安装或更新软件"
            case .system: return "系统活动：macOS 系统进程、系统更新、时间机器，或者看不到写入者"
            case .devWork: return "开发工具正在正常工作：编译代码、拉取容器镜像"
            case .script: return "脚本或命令行程序（如 Python、node）在大量写数据"
            case .cache: return "可以再生的数据：缓存、编译产物、模型缓存、容器虚拟磁盘、编辑器工作区存储"
            case .log: return "日志文件"
            case .appData: return "普通应用在后台写它自己的数据（聊天记录、同步数据等）"
            case .unknown: return "不认识的程序或文件夹"
            }
        }

        /// The policy: things the user knowingly does stay quiet; things piling up behind their back speak up.
        var notify: Bool {
            switch self {
            case .userFiles, .userActivity, .system, .devWork: return false
            case .script, .cache, .log, .appData, .unknown: return true
            }
        }
    }

    struct Options {
        enum Mode: String { case direct, category }
        /// direct: the model answers notify yes/no. category: the model names a category and the
        /// code decides.
        var mode: Mode = .category
        enum PromptVersion: String { case v1, v2 }
        var prompt: PromptVersion = .v2
        /// Ask for the reason before the yes/no, so the model "thinks" before it decides.
        var reasonFirst = false
        /// Constrain decoding to the JSON shape (otherwise we only ask for JSON and hope).
        var useGrammar = true
    }

    struct Verdict {
        let notify: Bool
        let reason: String
        /// In category mode, what the model said this is.
        var category: Category? = nil
        /// Decided by the hard rule, without the model.
        let byRule: Bool
        /// The model's raw output (empty when decided by rule).
        let raw: String
        /// False when the model's output could not be read; `notify` then defaults to true.
        let parsed: Bool
        let stats: LocalModel.Stats?
    }

    /// Low space is never a judgement call: always tell the user.
    static func hardRule(_ facts: DiskEventFacts) -> String? {
        let limit = max(20, facts.total_gb * 0.05)
        guard facts.free_gb < limit else { return nil }
        return "硬盘只剩 \(Int(facts.free_gb.rounded())) GB 了，快满了。"
    }

    static func judge(_ facts: DiskEventFacts, model: LocalModel, options: Options = Options()) throws -> Verdict {
        if let reason = hardRule(facts) {
            return Verdict(notify: true, reason: reason, byRule: true, raw: "", parsed: true, stats: nil)
        }

        if options.mode == .category { return try judgeByCategory(facts, model: model, options: options) }

        let prompt = try model.chatPrompt([("system", systemPrompt(options)), ("user", facts.description)])
        var sampling = LocalModel.Sampling.greedy
        if options.useGrammar { sampling.grammar = grammar(reasonFirst: options.reasonFirst) }
        let result = try model.generate(prompt: prompt, maxTokens: 120, sampling: sampling)

        if let answer = parse(result.text) {
            return Verdict(notify: answer.notify, reason: answer.reason, byRule: false,
                           raw: result.text, parsed: true, stats: result.stats)
        }
        // Unreadable answer: better one notification too many than a missed problem.
        return Verdict(notify: true, reason: "", byRule: false, raw: result.text, parsed: false, stats: result.stats)
    }

    private static func judgeByCategory(_ facts: DiskEventFacts, model: LocalModel, options: Options) throws -> Verdict {
        let prompt = try model.chatPrompt([("system", categoryPrompt), ("user", facts.description)])
        var sampling = LocalModel.Sampling.greedy
        if options.useGrammar { sampling.grammar = categoryGrammar }
        let result = try model.generate(prompt: prompt, maxTokens: 120, sampling: sampling)

        struct Answer: Decodable { let category: String; let reason: String }
        if let start = result.text.firstIndex(of: "{"), let end = result.text.lastIndex(of: "}"), start < end,
           let answer = try? JSONDecoder().decode(Answer.self, from: Data(result.text[start...end].utf8)),
           let category = Category(rawValue: answer.category) {
            return Verdict(notify: category.notify, reason: answer.reason, category: category, byRule: false,
                           raw: result.text, parsed: true, stats: result.stats)
        }
        return Verdict(notify: true, reason: "", byRule: false, raw: result.text, parsed: false, stats: result.stats)
    }

    static var categoryPrompt: String {
        // LOADLENS_TRIAGE_REVERSE=1 lists the categories backwards (to test position bias).
        let ordered = ProcessInfo.processInfo.environment["LOADLENS_TRIAGE_REVERSE"] == "1"
            ? Array(Category.allCases.reversed()) : Category.allCases
        let list = ordered.map { "- \($0.rawValue)：\($0.meaning)" }.joined(separator: "\n")
        return """
        你是 Mac 上的硬盘助手。用户会描述一次硬盘事件（空间快速减少，或某个文件夹持续变大）。
        你只需要判断：主要原因属于下面哪一类。看写入者或文件夹的名字和所属应用来判断。
        \(list)
        只输出一行 JSON：{"category": "类别英文名", "reason": "一句不超过 30 字的中文说明，写给普通用户看"}
        """
    }

    static var categoryGrammar: String {
        let names = Category.allCases.map { "\"\\\"\($0.rawValue)\\\"\"" }.joined(separator: " | ")
        return """
        root ::= "{" ws "\\"category\\"" ws ":" ws category ws "," ws "\\"reason\\"" ws ":" ws "\\"" char{1,60} "\\"" ws "}"
        category ::= \(names)
        char ::= [^"\\\\\\n]
        ws ::= [ ]?
        """
    }

    // MARK: Prompt

    static func systemPrompt(_ options: Options) -> String {
        let principle = """
        你是 Mac 上的硬盘助手。下面的硬盘事件已经超过了用户设定的提醒门槛，你要判断：值不值得发通知打扰用户。
        原则：用户自己知道正在做的事（下载、拷贝、导入、安装更新等）不打扰；在背后悄悄堆积、可以清理、或者明显异常的才提醒。
        """
        let knowledge = """
        常识：
        - 编译、下载、拷贝文件、导入照片、系统或应用更新、拉取容器镜像，短时间写入大量数据是正常的。
        - 看不到写入者通常是系统进程（如时间机器、系统更新），空间充足时一般不用担心。
        - 不认识的后台程序大量写入，或者脚本持续高速写入，值得提醒。
        - 缓存、编译产物、模型缓存、容器虚拟磁盘会悄悄变大且可以清理，持续变大值得提醒。
        - 日志文件夹几天涨几 GB 属于异常，值得提醒。
        - 用户自己的文稿、影片、照片、邮件变大属于正常使用，不打扰。
        """
        let format = options.reasonFirst
            ? #"只输出一行 JSON：{"reason": "一句不超过 30 字的中文理由", "notify": true 或 false}"#
            : #"只输出一行 JSON：{"notify": true 或 false, "reason": "一句不超过 30 字的中文理由"}"#
        return [principle, options.prompt == .v2 ? knowledge : nil, format]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    /// GBNF for exactly `{"notify": <bool>, "reason": "<text>"}` (or reason first).
    static func grammar(reasonFirst: Bool) -> String {
        let notify = #""\"notify\"" ws ":" ws ("true" | "false")"#
        let reason = #""\"reason\"" ws ":" ws "\"" char{1,60} "\"""#
        let fields = reasonFirst ? "\(reason) ws \",\" ws \(notify)" : "\(notify) ws \",\" ws \(reason)"
        return """
        root ::= "{" ws \(fields) ws "}"
        char ::= [^"\\\\\\n]
        ws ::= [ ]?
        """
    }

    private struct Answer: Decodable {
        let notify: Bool
        let reason: String
    }

    /// Reads the first {...} in the output; tolerant of text around it (for the no-grammar case).
    static func parse(_ text: String) -> (notify: Bool, reason: String)? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(text[start...end].utf8)) else { return nil }
        return (answer.notify, answer.reason)
    }
}
