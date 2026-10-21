import Foundation
import AppKit

/// One place that commonly grows large and can usually be cleaned up.
struct SpaceItem: Identifiable {
    enum State: Equatable {
        case pending
        /// Still walking the folder; the running total so far.
        case counting(UInt64)
        case done(UInt64)
        case missing
        case denied
    }

    let id: String
    let title: String
    let hint: String
    let symbol: String
    let paths: [String]
    var state: State = .pending

    var bytes: UInt64 {
        if case .done(let value) = state { return value }
        return 0
    }
}

/// Measures well-known, usually cleanable folders. Only reads file sizes (metadata), never contents,
/// and never deletes anything.
final class SpaceScanner: ObservableObject {
    static let shared = SpaceScanner()

    @Published private(set) var items: [SpaceItem] = SpaceScanner.catalog()
    @Published private(set) var isScanning = false
    @Published private(set) var scannedAt: Date?

    private var cancelled = false
    private let queue = DispatchQueue(label: "loadlens.space", qos: .utility)

    var total: UInt64 { items.reduce(0) { $0 + $1.bytes } }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        cancelled = false
        items = Self.catalog()

        let jobs = items.map { ($0.id, $0.paths) }
        queue.async { [weak self] in
            guard let self else { return }
            // A few folders at a time, so small ones finish quickly while big caches keep counting.
            let limit = DispatchSemaphore(value: 3)
            let group = DispatchGroup()
            for (id, paths) in jobs {
                limit.wait()
                if self.cancelled { limit.signal(); break }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let state = Self.measure(paths,
                                             progress: { partial in self.update(id, .counting(partial)) },
                                             cancelled: { self.cancelled })
                    self.update(id, state)
                    limit.signal()
                    group.leave()
                }
            }
            group.wait()
            DispatchQueue.main.async {
                self.isScanning = false
                self.scannedAt = Date()
                // Biggest first, places we couldn't read at the end.
                self.items.sort { lhs, rhs in
                    if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                    return lhs.title < rhs.title
                }
            }
        }
    }

    func cancel() {
        cancelled = true
    }

    private func update(_ id: String, _ state: SpaceItem.State) {
        DispatchQueue.main.async {
            guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            // Never let a late progress update overwrite a final result.
            if case .done = self.items[index].state, case .counting = state { return }
            self.items[index].state = state
        }
    }

    func reveal(_ item: SpaceItem) {
        let existing = item.paths.filter { FileManager.default.fileExists(atPath: $0) }
        if existing.isEmpty, let first = item.paths.first {
            NSWorkspace.shared.open(URL(fileURLWithPath: (first as NSString).deletingLastPathComponent))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing.map { URL(fileURLWithPath: $0) })
        }
    }

    static func openStorageSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.Storage",
            "x-apple.systempreferences:com.apple.preference.storage"
        ]
        for link in candidates {
            if let url = URL(string: link), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: Measuring

    private static func measure(_ paths: [String],
                                progress: (UInt64) -> Void,
                                cancelled: () -> Bool) -> SpaceItem.State {
        let fm = FileManager.default
        var total: UInt64 = 0
        var found = false
        var denied = false

        for path in paths {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            found = true
            guard isDirectory.boolValue else {
                total += allocatedSize(URL(fileURLWithPath: path))
                continue
            }
            // Folders protected by privacy settings can't be listed without permission.
            if (try? fm.contentsOfDirectory(atPath: path)) == nil {
                denied = true
                continue
            }
            let base = total
            total = base + walk(path, progress: { progress(base + $0) }, cancelled: cancelled)
            if cancelled() { return .done(total) }
        }
        if !found { return .missing }
        if denied && total == 0 { return .denied }
        return .done(total)
    }

    /// Allocated bytes under a folder, using fts like `du` (much lighter than URL enumeration).
    private static func walk(_ path: String, progress: (UInt64) -> Void, cancelled: () -> Bool) -> UInt64 {
        guard let cPath = strdup(path) else { return 0 }
        defer { free(cPath) }
        var roots: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }

        var total: UInt64 = 0
        var visited = 0
        while let entry = fts_read(fts) {
            if Int32(entry.pointee.fts_info) == FTS_F, let stat = entry.pointee.fts_statp {
                total += UInt64(max(stat.pointee.st_blocks, 0)) * 512
            }
            visited += 1
            if visited % 20_000 == 0 {
                if cancelled() { break }
                progress(total)
            }
        }
        return total
    }

    private static func allocatedSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    // MARK: Catalog

    private static func catalog() -> [SpaceItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func h(_ relative: String) -> String { home + "/" + relative }

        return [
            SpaceItem(id: "downloads", title: "下载", hint: "下载过的安装包、压缩包，装完通常可以删掉",
                      symbol: "arrow.down.circle", paths: [h("Downloads")]),
            SpaceItem(id: "trash", title: "废纸篓", hint: "删除的文件仍占用空间，清倒后才会释放",
                      symbol: "trash", paths: [h(".Trash")]),
            SpaceItem(id: "caches", title: "应用缓存", hint: "应用临时数据，删除后会自动重建；先退出对应应用",
                      symbol: "archivebox", paths: [h("Library/Caches")]),
            SpaceItem(id: "logs", title: "日志", hint: "应用和系统写下的运行记录，一般可以删除",
                      symbol: "doc.text", paths: [h("Library/Logs")]),
            SpaceItem(id: "xcode", title: "Xcode 编译缓存", hint: "DerivedData 和旧的归档，删除后下次编译会重建",
                      symbol: "hammer", paths: [h("Library/Developer/Xcode/DerivedData"),
                                               h("Library/Developer/Xcode/Archives")]),
            SpaceItem(id: "simulators", title: "iOS 模拟器", hint: "不用的模拟器可在 Xcode → Devices 里删除",
                      symbol: "iphone", paths: [h("Library/Developer/CoreSimulator/Devices")]),
            SpaceItem(id: "devcache", title: "开发工具缓存", hint: "npm、pip 等包管理器的下载缓存",
                      symbol: "shippingbox", paths: [h(".npm"), h(".cache"), h(".gradle/caches")]),
            SpaceItem(id: "backups", title: "iPhone / iPad 备份", hint: "旧设备的本地备份，可在访达的设备页管理",
                      symbol: "externaldrive.badge.timemachine",
                      paths: [h("Library/Application Support/MobileSync/Backup")])
        ]
    }
}
