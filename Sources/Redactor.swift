import Foundation

/// Hides personal information before anything goes to a cloud model, and puts it back in the
/// answer: the cloud sees 【文件3.dmg】, the user still sees "MuMuPlayer_1.9.2.dmg".
///
/// Hidden: the user's account name, full name and computer name; names of files and folders the
/// user made (Desktop, Documents, Downloads, Movies, Music, Pictures, Trash, iCloud Drive, other
/// folders in the home folder); email addresses, phone numbers, IP addresses.
/// Kept: app names and bundle IDs, cache / log / developer folders under ~/Library, sizes, dates,
/// file extensions — what the model needs to give useful advice.
///
/// One instance per conversation, so the same name gets the same code every time.
final class Redactor {
    /// Distinct things hidden so far.
    var hiddenCount: Int { lock.lock(); defer { lock.unlock() }; return forward.count }

    // Tool calls run in the background while answers stream on the main thread.
    private let lock = NSRecursiveLock()

    private var forward: [String: String] = [:]     // real → code
    private var backward: [String: String] = [:]    // code → real
    private var counters: [String: Int] = [:]

    private let home = NSHomeDirectory()
    private let identities: [(String, String)]      // (real, code), longest first

    /// Top folders whose children are the user's own things (the folder name itself is generic).
    private static let personalRoots: Set<String> = ["Desktop", "Documents", "Downloads", "Movies", "Music",
                                                      "Pictures", "Public", ".Trash"]
    /// Under ~/Library, these hold the user's own files too.
    private static let personalLibraryRoots = ["Library/Mobile Documents/com~apple~CloudDocs", "Library/CloudStorage"]

    init() {
        var ids: [(String, String)] = []
        let user = NSUserName(), full = NSFullUserName()
        if let host = Host.current().localizedName, host.count >= 3 { ids.append((host, "【这台电脑】")) }
        if full.count >= 2, full != user { ids.append((full, "【用户】")) }
        if user.count >= 3 { ids.append((user, "【用户】")) }
        identities = ids.sorted { $0.0.count > $1.0.count }
    }

    // MARK: Hiding

    /// Free text: the snapshot, questions, earlier answers.
    func redactText(_ text: String) -> String {
        lock.lock(); defer { lock.unlock() }
        var out = text.replacingOccurrences(of: home, with: "~")
        // Paths in prose: stop at whitespace, quotes and Chinese punctuation.
        out = replaceMatches(in: out, pattern: #"~/[^\s"'，。、；：！？（）()【】\[\]{}<>]+"#) { redactPath($0) }
        out = replaceMatches(in: out, pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#) { code($0, kind: "邮箱") }
        out = replaceMatches(in: out, pattern: #"(?<!\d)1[3-9]\d{9}(?!\d)"#) { code($0, kind: "电话") }
        out = replaceMatches(in: out, pattern: #"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#) { code($0, kind: "IP") }
        for (real, replacement) in identities { out = out.replacingOccurrences(of: real, with: replacement) }
        // Names already coded once (a file name mentioned on its own) stay coded everywhere.
        for (real, code) in forward.sorted(by: { $0.key.count > $1.key.count }) where real.count >= 4 {
            out = out.replacingOccurrences(of: real, with: code)
        }
        return out
    }

    /// A path such as ~/Downloads/foo/bar.dmg → ~/Downloads/【文件夹1】/【文件2.dmg】.
    func redactPath(_ raw: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let path = raw.hasPrefix(home) ? "~" + raw.dropFirst(home.count) : raw
        guard path.hasPrefix("~/") else { return path }
        let rel = String(path.dropFirst(2))
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let start = Self.personalStart(rel) else { return path }
        let keep = min(start, parts.count)
        let coded = parts.enumerated().map { index, part -> String in
            guard index >= keep, !part.isEmpty else { return part }
            return code(part, kind: index == parts.count - 1 && part.contains(".") ? "文件" : "文件夹")
        }
        return "~/" + coded.joined(separator: "/")
    }

    /// A tool result (JSON): every string goes through `redactText`; in the user's own folders,
    /// item names (which carry no path) are coded too.
    func redactToolResult(name: String, arguments: [String: Any], result: String) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return redactText(result) }
        let personalItems = name == "analyze_folder" && isPersonalFolder(arguments)
        let cleaned = walk(object, personalItems: personalItems)
        guard let out = try? JSONSerialization.data(withJSONObject: cleaned, options: [.withoutEscapingSlashes]) else {
            return redactText(result)
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func isPersonalFolder(_ arguments: [String: Any]) -> Bool {
        if let target = arguments["target"] as? String { return ["downloads", "trash"].contains(target) }
        guard var path = (arguments["path"] as? String).map(restore) else { return false }
        if path.hasPrefix(home) { path = "~" + path.dropFirst(home.count) }
        guard path.hasPrefix("~/") || path == "~" else { return false }
        // The folder's children are personal when a child path would be coded.
        let rel = path == "~" ? "" : String(path.dropFirst(2))
        let depth = rel.isEmpty ? 0 : rel.split(separator: "/").count
        return Self.personalStart(rel.isEmpty ? "x" : rel + "/x").map { $0 <= depth } ?? false
    }

    /// For a path relative to the home folder: from which component on names are personal, or
    /// nil when nothing in it is (app data, caches, dev tools). Creates no codes.
    private static func personalStart(_ rel: String) -> Int? {
        guard let first = rel.split(separator: "/").first.map(String.init) else { return nil }
        if let root = personalLibraryRoots.first(where: { rel == $0 || rel.hasPrefix($0 + "/") }) {
            return root.split(separator: "/").count
        }
        if first == "Library" || (first.hasPrefix(".") && first != ".Trash") || first == "Applications" { return nil }
        return personalRoots.contains(first) ? 1 : 0
    }

    private func walk(_ value: Any, personalItems: Bool, key: String? = nil) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.reduce(into: [String: Any]()) { $0[$1.key] = walk($1.value, personalItems: personalItems, key: $1.key) }
        case let array as [Any]:
            return array.map { walk($0, personalItems: personalItems, key: key) }
        case let string as String:
            if personalItems, key == "name" {
                return code(string, kind: string.contains(".") ? "文件" : "文件夹")
            }
            return redactText(string)
        default:
            return value
        }
    }

    // MARK: Restoring

    /// Puts real names back into text from the model.
    func restore(_ text: String) -> String {
        guard text.contains("【") else { return text }
        lock.lock(); defer { lock.unlock() }
        // The brackets acted as separators ("【文件1.dmg】638 MB"); the real name needs a space where
        // it would otherwise run into a letter or digit ("Claude.dmg 638 MB").
        func joins(_ c: Character?) -> Bool { c.map { $0.isLetter && $0.isASCII || $0.isNumber } ?? false }
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "【"), let close = rest[open...].firstIndex(of: "】") {
            let token = String(rest[open...close])
            out += rest[..<open]
            guard let real = backward[token] else { out += token; rest = rest[rest.index(after: close)...]; continue }
            if joins(out.last), joins(real.first) { out += " " }
            out += real
            rest = rest[rest.index(after: close)...]
            if joins(rest.first), joins(real.last) { out += " " }
        }
        return out + rest
    }

    /// Tool arguments from the model may contain codes ("~/Documents/【文件夹1】"); run the tool on the real thing.
    func restoreArguments(_ arguments: [String: Any]) -> [String: Any] {
        arguments.mapValues { ($0 as? String).map(restore) ?? $0 }
    }

    // MARK: Private

    private func code(_ real: String, kind: String) -> String {
        if let existing = forward[real] { return existing }
        counters[kind, default: 0] += 1
        var label = "\(kind)\(counters[kind]!)"
        // Keep the extension: ".dmg" tells the model it is an installer, which is not personal.
        if kind == "文件", let dot = real.lastIndex(of: "."), real.distance(from: dot, to: real.endIndex) <= 6 {
            label += String(real[dot...])
        }
        let token = "【\(label)】"
        forward[real] = token
        backward[token] = real
        return token
    }

    private func replaceMatches(in text: String, pattern: String, _ transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += transform(ns.substring(with: match.range))
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }
}

/// Restores codes in streamed text without showing half a code: holds back from an unclosed "【".
struct StreamRestorer {
    private var held = ""

    mutating func push(_ delta: String, with redactor: Redactor) -> String {
        held += delta
        // A code at the very end: wait for the next character to know whether a space is needed.
        if held.hasSuffix("】"), let open = held.lastIndex(of: "【") {
            let ready = String(held[..<open])
            held = String(held[open...])
            return redactor.restore(ready)
        }
        if let open = held.lastIndex(of: "【"), !held[open...].contains("】"), held.distance(from: open, to: held.endIndex) < 40 {
            let ready = String(held[..<open])
            held = String(held[open...])
            return redactor.restore(ready)
        }
        let ready = held
        held = ""
        return redactor.restore(ready)
    }

    mutating func flush(with redactor: Redactor) -> String {
        defer { held = "" }
        return redactor.restore(held)
    }
}
