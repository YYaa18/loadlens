import Foundation

enum LoadLevel {
    case calm
    case busy
    case hot
}

struct Diagnosis {
    var level: LoadLevel
    var headline: String
    var detail: String
    var advice: [String]
    var memoryLabel: String
    var thermalLabel: String
    var diskLabel: String = "—"

    static let initial = Diagnosis(level: .calm,
                                   headline: "正在采样…",
                                   detail: "第一次采样需要一秒左右",
                                   advice: [],
                                   memoryLabel: "—",
                                   thermalLabel: "—")
}

enum Diagnoser {
    static let browserNames: Set<String> = [
        "Google Chrome", "Chromium", "Microsoft Edge", "Brave Browser",
        "Arc", "Vivaldi", "Opera", "Firefox", "Safari", "Safari 网页"
    ]

    static func evaluate(_ snapshot: Snapshot) -> Diagnosis {
        let cores = max(snapshot.cores, 1)
        let loadPerCore = snapshot.load1 / Double(cores)

        let level: LoadLevel
        if snapshot.thermal == .serious || snapshot.thermal == .critical {
            level = .hot
        } else if snapshot.cpu >= 70 || loadPerCore >= 1.8 {
            level = .hot
        } else if snapshot.cpu >= 30 || loadPerCore >= 0.9 {
            level = .busy
        } else {
            level = .calm
        }

        let headline: String
        if snapshot.thermal == .critical {
            headline = "严重过热，性能被大幅限制"
        } else if snapshot.thermal == .serious {
            headline = "机器过热，系统正在降频"
        } else if snapshot.cpu >= 70 {
            headline = "CPU 快被占满了"
        } else if loadPerCore >= 1.8 {
            headline = "任务排起了长队"
        } else if level == .busy {
            headline = "有点忙，但还撑得住"
        } else {
            headline = "运行正常"
        }

        let detail = String(format: "CPU %.0f%% · 负载 %.1f（%d 核）· 内存 %@/%@ GB",
                            snapshot.cpu, snapshot.load1, cores,
                            formatGB(snapshot.memory.usedBytes),
                            formatGB(snapshot.memory.totalBytes))

        let swapGB = Double(snapshot.memory.swapUsedBytes) / 1_073_741_824
        let memoryRatio = snapshot.memory.totalBytes > 0
            ? Double(snapshot.memory.usedBytes) / Double(snapshot.memory.totalBytes)
            : 0

        let memoryLabel: String
        if memoryRatio >= 0.92 || swapGB >= 6 {
            memoryLabel = "紧张"
        } else if memoryRatio >= 0.82 || swapGB >= 1.5 {
            memoryLabel = "偏紧"
        } else {
            memoryLabel = "正常"
        }

        let thermalLabel: String
        switch snapshot.thermal {
        case .nominal: thermalLabel = "正常"
        case .fair: thermalLabel = "偏热"
        case .serious: thermalLabel = "过热"
        case .critical: thermalLabel = "严重过热"
        @unknown default: thermalLabel = "未知"
        }

        var advice: [String] = []
        let top = snapshot.apps.first

        // 0. 硬盘：健康异常最优先
        let disk = snapshot.disk
        let diskLabel = Self.diskLabel(disk)
        if disk.health?.isFailing == true {
            advice.append("启动盘的 SMART 自检报告异常，硬盘可能快坏了。请马上用 Time Machine 或拷贝的方式备份重要文件，然后联系 Apple 售后检测。")
        }

        // 1. 温度相关
        if snapshot.thermal == .serious || snapshot.thermal == .critical {
            advice.append("温度已经很高，系统在主动限制性能。先关掉下面占用最高的应用，等几分钟再继续，别把机器放在被子或软面上。")
        } else if let kernel = snapshot.apps.first(where: { $0.busiestProcess == "kernel_task" }), kernel.cpu >= 12 {
            advice.append("系统内核（kernel_task）占用高，通常不是它有问题，而是系统在主动降温、限制性能，说明机器已经比较热了。")
        }

        // 2. 最大占用者
        if let top, top.cpu >= 12 {
            advice.append(adviceForTopApp(top))
        }

        // 3. 内存
        if swapGB >= 1.5 || memoryRatio >= 0.88 {
            advice.append(String(format: "内存偏紧：交换区已用 %.1f GB，系统会把部分数据临时放到硬盘上，容易发热变卡。关掉暂时不用的应用，或重启一次。", swapGB))
        }

        // 4. 显卡着色器编译（常见于网页 3D/动画）
        if let shader = snapshot.apps.first(where: { $0.busiestProcess == "MTLCompilerService" }),
           shader.cpu >= 15,
           top?.busiestProcess != "MTLCompilerService" {
            advice.append("显卡一直在编译着色器（常见于网页 3D、动画、视频剪辑或游戏）。通常几十秒会结束；如果持续很久，关掉正在播放动画的网页或正在渲染的应用。")
        }

        // 5. 窗口合成
        if let window = snapshot.apps.first(where: { $0.busiestProcess == "WindowServer" }),
           window.cpu >= 25,
           top?.busiestProcess != "WindowServer" {
            advice.append("系统在窗口合成上比较吃力，通常是因为同时开了很多窗口或有持续动画。关掉一些窗口或浏览器标签，重启一次也能明显缓解。")
        }

        // 6. 后台索引
        if let indexing = snapshot.apps.first(where: { $0.name == "Spotlight 文件索引" }),
           indexing.cpu >= 10,
           top?.name != "Spotlight 文件索引" {
            advice.append("Spotlight 正在给硬盘建立索引，通常会自己跑完；如果长期占用很高，可以在系统设置 → Spotlight 里排除大的文件夹。")
        }

        // 6.5 硬盘空间与读写
        if let root = disk.root {
            let availableGB = Double(root.availableBytes) / 1_000_000_000
            if root.freeRatio < 0.08 || availableGB < 12 {
                advice.append(String(format: "启动盘只剩约 %.0f GB 可用。空间太少会让系统没地方放交换文件，导致卡顿、更新失败。到「硬盘」页看看哪些地方可以清理。", availableGB))
            } else if (root.freeRatio < 0.15 || availableGB < 30) && swapGB >= 1 {
                advice.append(String(format: "启动盘可用约 %.0f GB，同时在用交换区。建议清理出更多空间，避免内存不够时变卡。", availableGB))
            }
        }
        let ioTotal = disk.readRate + disk.writeRate
        if ioTotal >= 80 * 1_048_576,
           let heavy = snapshot.apps.max(by: { $0.diskTotal < $1.diskTotal }), heavy.diskTotal >= 20 * 1_048_576 {
            advice.append("\(heavy.name) 正在大量读写硬盘（约 \(formatRate(heavy.diskTotal))），可能在下载、同步或索引。这时候其他应用打开文件会变慢，等它完成即可。")
        }

        // 7. 长期未重启
        let days = Int(snapshot.uptime / 86_400)
        if days >= 21 && swapGB >= 1 {
            advice.append("这台电脑已经连续运行 \(days) 天，建议找时间重启一次，可以清掉累积的内存和显卡状态。")
        }

        // 8. 没有单一元凶
        if level != .calm && (top?.cpu ?? 0) < 25 && advice.count <= 1 {
            advice.append("没有单个特别突出的进程，是多个应用一起占用。关掉暂时不用的应用即可。")
        }

        if advice.isEmpty {
            advice.append("现在没有明显异常，不用特别处理。")
        }

        return Diagnosis(level: level,
                         headline: headline,
                         detail: detail,
                         advice: Array(advice.prefix(4)),
                         memoryLabel: memoryLabel,
                         thermalLabel: thermalLabel,
                         diskLabel: diskLabel)
    }

    static func diskLabel(_ disk: DiskSnapshot) -> String {
        if disk.health?.isFailing == true { return "异常" }
        guard let root = disk.root else { return "—" }
        let availableGB = Double(root.availableBytes) / 1_000_000_000
        if root.freeRatio < 0.08 || availableGB < 12 { return "紧张" }
        if root.freeRatio < 0.15 || availableGB < 30 { return "偏紧" }
        return "充足"
    }

    private static func adviceForTopApp(_ app: AppUsage) -> String {
        let cores = app.cpu / 100
        let coreText = cores >= 1 ? String(format: "%.1f 个核心", cores) : String(format: "%.0f%% 的一个核心", app.cpu)

        if browserNames.contains(app.name) &&
            (app.busiestProcess.lowercased().contains("render") ||
             app.busiestProcess.lowercased().contains("webcontent")) {
            return "\(app.name) 里有网页在持续运行（动画、视频或脚本），占了约 \(coreText)。打开浏览器自带的任务管理器（Chrome / Edge / Arc 按 Shift + Esc），结束占用最高的标签页。"
        }

        switch app.busiestProcess {
        case "MTLCompilerService":
            return "显卡正在编译着色器（常见于网页 3D、动画、视频剪辑），占了约 \(coreText)。通常会自己结束；如果持续很久，关掉正在播放动画的网页或正在渲染的应用。"
        case "WindowServer":
            return "系统窗口合成占了约 \(coreText)，通常是同时开了很多窗口或有持续动画。关掉一些窗口或浏览器标签。"
        case "kernel_task":
            return "内核占用不是它本身的问题，而是系统在为降温限制性能。先减少负载，等温度降下来。"
        case "backupd":
            return "Time Machine 正在备份，备份完成后会自动降下来。急用电脑可以暂时暂停备份。"
        case "coreaudiod":
            return "音频服务占用偏高，可能有网页或应用在播放声音，或音频设备状态异常。检查一下正在播放声音的应用。"
        case "mds", "mds_stores", "mdworker", "mdworker_shared":
            return "Spotlight 正在给硬盘建立索引，通常会自己结束；如果长期如此，可以在系统设置 → Spotlight 里排除大的文件夹。"
        default:
            if app.isSystem {
                return "\(app.name) 占了约 \(coreText)，属于系统服务；如果持续偏高，重启一次通常能恢复。"
            }
            return "\(app.name) 是当前最大占用，约 \(coreText)。关掉不用的窗口，或重启这个应用，通常能立刻降温。"
        }
    }
}
