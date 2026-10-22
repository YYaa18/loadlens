"""Generates labelled disk events for fine-tuning the triage model.

Output (facts + category only; the prompt text is produced by the app's own Swift code, so
training and the app see exactly the same words):
  train/data/facts-train.jsonl, facts-valid.jsonl   training / validation
  eval/triage-test.json                             held-out test set, names never seen in training

Names come from three disjoint pools: TRAIN, TEST, and the names used in eval/triage-cases.json
(the dev exam), which are never used for training. `check_overlap()` enforces this.

Standard library only. Run:  python3 train/make_data.py
"""
import json
import os
import random
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --------------------------------------------------------------------------------------------
# Writers for "free space dropped fast" events: (app, process) per category.
# --------------------------------------------------------------------------------------------
WRITERS = {
    "user_activity": {
        "train": [("Firefox", "firefox"), ("Microsoft Edge", "Microsoft Edge"), ("Arc", "Arc"),
                  ("Brave Browser", "Brave Browser"), ("Vivaldi", "Vivaldi"), ("Motrix", "Motrix"),
                  ("FileZilla", "filezilla"), ("Cyberduck", "Cyberduck"), ("Steam", "steam_osx"),
                  ("Epic Games Launcher", "EpicGamesLauncher"), ("App Store", "storedownloadd"),
                  ("安装器", "Installer"), ("Keka", "Keka"), ("归档实用工具", "Archive Utility"),
                  ("图像捕捉", "Image Capture"), ("Adobe Lightroom Classic", "Adobe Lightroom Classic"),
                  ("DaVinci Resolve", "Resolve"), ("Logic Pro", "Logic Pro"), ("HandBrake", "HandBrake"),
                  ("Final Cut Pro", "Final Cut Pro"), ("百度网盘", "BaiduNetdisk_mac"), ("Ollama", "ollama"),
                  ("GPT4All", "gpt4all"), ("iMovie", "iMovie")],
        "test": [("Opera", "Opera"), ("迅雷", "Thunder"), ("Transmit", "Transmit"), ("Adobe Premiere Pro", "Adobe Premiere Pro"),
                 ("The Unarchiver", "The Unarchiver"), ("Jan", "Jan"), ("GarageBand", "GarageBand")],
    },
    "system": {
        "train": [("Spotlight", "mds_stores"), ("时间机器", "backupd"), ("系统下载服务", "nsurlsessiond"),
                  ("iCloud", "bird"), ("系统更新", "softwareupdated"), ("Spotlight", "mdworker_shared"),
                  ("媒体库分析", "photoanalysisd"), ("系统资源下载", "mobileassetd"), ("fseventsd", "fseventsd")],
        "test": [("云同步服务", "cloudd"), ("媒体分析", "mediaanalysisd"), ("系统升级助手", "UpdateBrainService")],
    },
    "dev_work": {
        "train": [("Android Studio", "studio"), ("IntelliJ IDEA", "idea"), ("Gradle", "java"),
                  ("cargo", "cargo"), ("rustc", "rustc"), ("go", "go"), ("clang", "clang"),
                  ("OrbStack", "OrbStack Helper"), ("Podman", "podman"), ("Unity", "Unity"),
                  ("flutter", "dart"), ("Simulator", "Simulator")],
        "test": [("CLion", "clion"), ("Rancher Desktop", "rancher-desktop"), ("Unreal Editor", "UnrealEditor"),
                 ("Colima", "limactl")],
    },
    "script": {
        "train": [("node", "node"), ("ruby", "ruby"), ("perl", "perl"), ("php", "php"), ("bash", "bash"),
                  ("zsh", "zsh"), ("sh", "sh"), ("sqlite3", "sqlite3"), ("dotnet", "dotnet")],
        "test": [("deno", "deno"), ("bun", "bun"), ("julia", "julia"), ("Rscript", "Rscript")],
    },
    "app_data": {
        "train": [("Telegram", "Telegram"), ("QQ", "QQ"), ("钉钉", "DingTalk"), ("飞书", "Feishu"),
                  ("Slack", "Slack"), ("Discord", "Discord"), ("WhatsApp", "WhatsApp"), ("Signal", "Signal"),
                  ("Notion", "Notion"), ("Evernote", "Evernote"), ("Dropbox", "Dropbox"),
                  ("Google Drive", "Google Drive"), ("OneDrive", "OneDrive")],
        "test": [("企业微信", "WeWorkMac"), ("LINE", "LINE"), ("Microsoft Teams", "MSTeams"), ("Skype", "Skype")],
    },
}

# --------------------------------------------------------------------------------------------
# Folders for "a folder keeps growing" events: (path, owner or None) per category.
# --------------------------------------------------------------------------------------------
FOLDERS = {
    "user_files": {
        "train": [("~/Documents", None), ("~/Pictures", None), ("~/Music", None), ("~/Desktop", None),
                  ("~/Documents/项目资料", None), ("~/Pictures/Photos Library.photoslibrary", None),
                  ("~/Dropbox", "Dropbox"), ("~/Library/CloudStorage/OneDrive-Personal", "OneDrive"),
                  ("~/Documents/录屏", None)],
        "test": [("~/Library/Mobile Documents/com~apple~CloudDocs", "iCloud 云盘"), ("~/Sites", None),
                 ("~/Library/CloudStorage/Box-Box", "Box")],
    },
    "cache": {
        "train": [("~/Library/Caches/org.mozilla.firefox", "Firefox"), ("~/Library/Caches/com.spotify.client", "Spotify"),
                  ("~/Library/Caches/com.microsoft.edgemac", "Microsoft Edge"), ("~/Library/Caches/com.brave.Browser", "Brave Browser"),
                  ("~/Library/Caches/Homebrew", "Homebrew（命令行包管理器）"), ("~/Library/Caches/pip", "pip"),
                  ("~/Library/Caches/Yarn", "Yarn（Node.js）"), ("~/Library/pnpm/store", "pnpm（Node.js）"),
                  ("~/.npm/_cacache", None), ("~/.gradle/caches", None), ("~/.m2/repository", None),
                  ("~/.cargo/registry", None), ("~/go/pkg/mod", None), ("~/Library/Developer/CoreSimulator/Caches", None),
                  ("~/.ollama/models", None), ("~/Library/Containers/dev.orbstack.OrbStack/Data", "OrbStack"),
                  ("~/Library/Caches/com.tinyspeck.slackmacgap", "Slack"),
                  ("~/Library/Application Support/Slack/Cache", "Slack")],
        "test": [("~/.cache/torch", "PyTorch"), ("~/Library/Caches/com.operasoftware.Opera", "Opera"),
                 ("~/.bun/install/cache", "Bun"), ("~/Library/Caches/com.getpostman.Postman", "Postman"),
                 ("~/.conda/pkgs", None), ("~/Library/Containers/com.utmapp.UTM/Data", "UTM")],
    },
    "log": {
        "train": [("~/Library/Logs/JetBrains", "JetBrains IDE"), ("~/Library/Logs/zoom.us", "zoom.us"),
                  ("~/Library/Logs/Adobe", "Adobe 应用"), ("~/Library/Logs/Steam", "Steam"),
                  ("~/Library/Application Support/Telegram/logs", "Telegram"), ("~/Library/Logs/OBS", "OBS"),
                  ("~/Library/Logs/DingTalk", "钉钉")],
        "test": [("~/Library/Logs/ClashX", "ClashX"), ("~/Library/Logs/Parallels", "Parallels Desktop"), ("~/.pm2/logs", None)],
    },
    "app_data": {
        "train": [("~/Library/Application Support/Telegram Desktop", "Telegram"), ("~/Library/Application Support/Discord", "Discord"),
                  ("~/Library/Application Support/Notion", "Notion"), ("~/Library/Containers/com.tencent.qq/Data", "QQ"),
                  ("~/Library/Application Support/DingTalkMac", "钉钉"), ("~/Library/Application Support/LarkShell", "飞书"),
                  ("~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared", "WhatsApp"),
                  ("~/Library/Application Support/Signal", "Signal"), ("~/Library/Application Support/Evernote", "Evernote")],
        "test": [("~/Library/Containers/com.tencent.WeWorkMac/Data", "企业微信"), ("~/Library/Application Support/Webex", "Webex"),
                 ("~/Library/Application Support/Microsoft/Teams", "Microsoft Teams")],
    },
    "system": {
        "train": [("~/Library/Biome", None), ("~/Library/Metadata/CoreSpotlight", None),
                  ("~/Library/Application Support/com.apple.mediaanalysisd", "Apple 系统组件")],
        "test": [("~/Library/Application Support/com.apple.wallpaper", None)],
    },
}

# More training names: diversity matters more than count for recognising names never seen.
EXTRA_WRITERS = {
    "user_activity": [("qBittorrent", "qbittorrent"), ("Transmission", "Transmission"), ("Downie", "Downie"),
                      ("Adobe Photoshop", "Adobe Photoshop"), ("Blender", "Blender"), ("Audacity", "Audacity"),
                      ("Pixelmator Pro", "Pixelmator Pro"), ("Capture One", "CaptureOne"), ("CleanShot X", "CleanShot X"),
                      ("Battle.net", "Battle.net"), ("网易云音乐", "NeteaseMusic"), ("阿里云盘", "aDrive"),
                      ("Compressor", "Compressor"), ("Keynote", "Keynote"), ("夸克网盘", "QuarkCloudDrive")],
    "system": [("Spotlight", "mds"), ("系统日志", "logd"), ("内核", "kernel_task"), ("Siri", "siriknowledged"),
               ("通知中心", "usernoted"), ("空间回收", "deleted"), ("Spotlight", "corespotlightd")],
    "dev_work": [("WebStorm", "webstorm"), ("PyCharm", "pycharm"), ("GoLand", "goland"), ("Rider", "rider"),
                 ("Zed", "zed"), ("cmake", "cmake"), ("ninja", "ninja"), ("bazel", "bazel"), ("esbuild", "esbuild"),
                 ("minikube", "minikube"), ("buildkitd", "buildkitd"), ("Tart", "tart"), ("swift-build", "swift-build")],
    "script": [("lua", "lua"), ("tclsh", "tclsh"), ("raku", "raku"), ("ocaml", "ocaml"), ("gawk", "gawk"),
               ("jq", "jq"), ("ffmpeg", "ffmpeg"), ("dd", "dd"), ("pwsh", "pwsh"), ("fish", "fish"),
               ("elixir", "beam.smp"), ("node", "npm"), ("ruby", "bundle")],
    "app_data": [("Zalo", "Zalo"), ("Viber", "Viber"), ("Messenger", "Messenger"), ("Element", "Element"),
                 ("Obsidian", "Obsidian"), ("Logseq", "Logseq"), ("腾讯会议", "TencentMeeting"), ("Spotify", "Spotify"),
                 ("Bear", "Bear"), ("Craft", "Craft")],
}
EXTRA_FOLDERS = {
    "user_files": [("~/Documents/论文", None), ("~/Pictures/截图", None), ("~/Desktop/素材", None),
                   ("~/Documents/Zoom", "zoom.us"), ("~/Pictures/Lightroom", None), ("~/Music/Logic", None),
                   ("~/Library/CloudStorage/Dropbox", "Dropbox")],
    "cache": [("~/Library/Caches/com.figma.Desktop", "Figma"), ("~/Library/Caches/ms-playwright", "Playwright 浏览器"),
              ("~/Library/Caches/node-gyp", "Node.js 编译工具"), ("~/.cache/pre-commit", None), ("~/.cache/uv", "uv"),
              ("~/.cache/whisper", None), ("~/.rustup/toolchains", None), ("~/Library/Caches/CocoaPods", "CocoaPods"),
              ("~/Library/Caches/com.netease.163music", "网易云音乐"), ("~/Library/Application Support/Spotify/PersistentCache", "Spotify"),
              ("~/.gradle/wrapper/dists", None), ("~/.vagrant.d/boxes", None)],
    "log": [("~/Library/Logs/Microsoft", "Microsoft 应用"), ("~/Library/Logs/Unity", "Unity"),
            ("~/Library/Logs/Homebrew", "Homebrew（命令行包管理器）"), ("~/Library/Logs/Tunnelblick", "Tunnelblick"),
            ("~/Library/Logs/Figma", "Figma"), ("~/.npm/_logs", None), ("~/Library/Application Support/Slack/logs", "Slack")],
    "app_data": [("~/Library/Application Support/Obsidian", "Obsidian"), ("~/Library/Containers/com.tencent.meeting/Data", "腾讯会议"),
                 ("~/Library/Application Support/Element", "Element"), ("~/Library/Application Support/Logseq", "Logseq"),
                 ("~/Library/Application Support/Spotify/Users", "Spotify"), ("~/Library/Application Support/ViberPC", "Viber")],
    "system": [("~/Library/Assistant/SiriVocabulary", None), ("~/Library/Suggestions", None),
               ("~/Library/Application Support/CrashReporter", None)],
}
# Round 3: "system activity" was the weakest class (system folders without an obvious owner were
# taken for caches). Many more macOS daemons and system folders, plus Apple-owned folders that
# really are caches, so the boundary is "under Caches = cache", not "Apple = system".
EXTRA_WRITERS["system"] += [
    ("syspolicyd", "syspolicyd"), ("trustd", "trustd"), ("apsd", "apsd"), ("routined", "routined"),
    ("biomed", "biomed"), ("knowledge-agent", "knowledge-agent"), ("suggestd", "suggestd"), ("parsecd", "parsecd"),
    ("searchpartyd", "searchpartyd"), ("coreduetd", "coreduetd"), ("dasd", "dasd"), ("symptomsd", "symptomsd"),
    ("analyticsd", "analyticsd"), ("崩溃报告", "ReportCrash"), ("spindump", "spindump"), ("系统诊断", "sysdiagnose"),
    ("WindowServer", "WindowServer"), ("lsd", "lsd"), ("cfprefsd", "cfprefsd"), ("secd", "secd"), ("akd", "akd"),
    ("sharingd", "sharingd"), ("rapportd", "rapportd"), ("installd", "installd"), ("geod", "geod"),
    ("triald", "triald"), ("bluetoothd", "bluetoothd"), ("coreaudiod", "coreaudiod"), ("corespeechd", "corespeechd"),
    ("translationd", "translationd"), ("intelligenceplatformd", "intelligenceplatformd"),
    ("generativeexperiencesd", "generativeexperiencesd"), ("UserEventAgent", "UserEventAgent"),
]
EXTRA_FOLDERS["system"] += [
    ("~/Library/Application Support/Knowledge", None), ("~/Library/DuetExpertCenter", None),
    ("~/Library/Application Support/com.apple.siri.inference", "Apple 系统组件"),
    ("~/Library/Application Support/FileProvider", None), ("~/Library/Application Support/com.apple.ProtectedCloudStorage", "Apple 系统组件"),
    ("~/Library/Application Support/com.apple.spotlight", "Apple 系统组件"), ("~/Library/Application Support/DifferentialPrivacy", None),
    ("~/Library/HomeKit", None), ("~/Library/Application Support/com.apple.avfoundation", "Apple 系统组件"),
    ("~/Library/Application Support/com.apple.backgroundtaskmanagementagent", "Apple 系统组件"),
    ("~/Library/Application Support/CloudDocs", None), ("~/Library/Application Support/com.apple.sharedfilelist", "Apple 系统组件"),
    ("~/Library/Application Support/com.apple.TCC", "Apple 系统组件"), ("~/Library/Group Containers/group.com.apple.secure-control-center-preferences", None),
    ("~/Library/Application Support/com.apple.mlhost", "Apple 系统组件"),
]
EXTRA_FOLDERS["cache"] += [
    ("~/Library/Caches/com.apple.Music", "Apple 系统组件"), ("~/Library/Caches/com.apple.Maps", "Apple 系统组件"),
    ("~/Library/Caches/com.apple.podcasts", "Apple 系统组件"), ("~/Library/Caches/com.apple.helpd", "Apple 系统组件"),
]

# A second, fresh test set (test2): names used nowhere else, made after round 3, so the final
# score is not influenced by what we learned from test set 1.
TEST2_WRITERS = {
    "user_activity": [("Free Download Manager", "fdm"), ("Folx", "Folx"), ("Photomator", "Photomator"),
                      ("Affinity Photo 2", "Affinity Photo 2"), ("ScreenFlow", "ScreenFlow"), ("Shotcut", "shotcut")],
    "system": [("Spotlight 知识", "spotlightknowledged"), ("位置服务", "locationd"), ("诊断服务", "diagnosticd"),
               ("系统安装服务", "system_installd"), ("模型管理", "modelmanagerd")],
    "dev_work": [("Nova", "Nova"), ("Fleet", "fleet"), ("Earthly", "earthly"), ("Android Emulator", "qemu-system-aarch64")],
    "script": [("guile", "guile"), ("racket", "racket"), ("tcsh", "tcsh"), ("Nushell", "nu")],
    "app_data": [("Mattermost", "Mattermost"), ("Rocket.Chat", "Rocket.Chat"), ("Threema", "Threema"),
                 ("Joplin", "Joplin"), ("Anytype", "Anytype")],
}
TEST2_FOLDERS = {
    "user_files": [("~/Documents/Scans", None), ("~/Music/Audio Music Apps", None), ("~/Library/CloudStorage/pCloud", "pCloud")],
    "cache": [("~/.cache/selenium", None), ("~/.cache/puppeteer", None), ("~/Library/Caches/org.videolan.vlc", "VLC"),
              ("~/.cache/prisma", None)],
    "log": [("~/Library/Logs/Viscosity", "Viscosity"), ("~/Library/Logs/WireGuard", "WireGuard"),
            ("~/Library/Application Support/Mattermost/logs", "Mattermost")],
    "app_data": [("~/Library/Application Support/Joplin", "Joplin"), ("~/Library/Application Support/Threema", "Threema")],
    "system": [("~/Library/IntelligencePlatform", None), ("~/Library/Trial", None),
               ("~/Library/Application Support/com.apple.geod", None)],
}
for _pools, _extra in ((WRITERS, TEST2_WRITERS), (FOLDERS, TEST2_FOLDERS)):
    for _category, _names in _extra.items():
        _pools[_category]["test2"] = _names

for _pools, _extra in ((WRITERS, EXTRA_WRITERS), (FOLDERS, EXTRA_FOLDERS)):
    for _category, _names in _extra.items():
        _pools[_category]["train"] = _pools[_category]["train"] + _names

# Names in the dev exam (eval/triage-cases.json). Never train on them.
DEV_NAMES = ["Xcode", "swift-frontend", "Docker", "com.docker.backend", "com.xyz.agent", "Google Chrome",
             "Python", "Safari", "照片", "photolibraryd", "WeChat", "LM Studio", "访达", "Finder",
             "com.google.Chrome", "DerivedData", "~/Downloads", "com.docker.docker", "MobileSync",
             "huggingface", "SomeVPN", "~/Movies", "~/Library/Mail", "workspaceStorage", "Visual Studio Code"]

REASONS = {
    "user_files": ["这是你自己的文件，变大属于正常使用", "{name}里是你自己放的内容"],
    "user_activity": ["{name} 在下载或处理文件，属于正常操作", "{name} 正在进行你发起的操作", "{name} 在写入你正在处理的文件"],
    "system": ["系统进程在工作，空间充足不用担心", "{name} 是系统服务，属于正常活动", "多半是系统在后台工作"],
    "dev_work": ["{name} 在编译或准备开发环境，很常见", "{name} 正在构建项目", "{name} 在拉取或构建镜像"],
    "script": ["{name} 程序在高速写入数据，可能很快写满", "{name} 脚本写入量很大，建议看看", "{name} 在持续写数据，留意是否失控"],
    "cache": ["{name} 的缓存在堆积，可以清理", "{name} 是可以再生的数据，占用在增长", "缓存悄悄变大了，可以清理"],
    "log": ["{name} 的日志增长异常，可能有程序出错", "日志几天涨了几 GB，不太正常", "{name} 在大量写日志"],
    "app_data": ["{name} 在后台写入大量数据", "{name} 的数据在悄悄变大", "{name} 在后台持续写数据，值得看看"],
    "unknown": ["{name} 来路不明，正在大量写入", "不认识的程序 {name} 在大量写数据", "{name} 不是常见软件，建议看看"],
}

UNKNOWN_PARTS = {
    "train": (["com.", "net.", "io."], ["qwx", "zentra", "blu", "kora", "fyx", "omni", "vexa", "tlx", "mira", "dax"],
              ["agent", "helper", "daemon", "service", "syncd", "updater", "core"]),
    "valid": (["de.", "me.", "co."], ["trova", "ulix", "pexa", "rhom"], ["runner", "proxy", "loader"]),
    "test": (["org.", "cn.", "app."], ["plum", "nexo", "quab", "irvo", "selt"], ["worker", "bridge", "watcher", "hostd"]),
    "test2": (["ai.", "xyz."], ["korvi", "zamp", "ostra"], ["engine", "relay", "monitor"]),
}


def names(pool, split):
    """test: its own pool. train/valid: the training pool split by name, so validation names are
    never seen in training either (otherwise validation only checks memorised names)."""
    if split in ("test", "test2"):
        return pool.get(split, [])
    # Decide by the app's name (folders: owner, else path), the same way in every list, so an app
    # that appears in two categories (Spotify data and Spotify cache) lands on one side only.
    def is_valid(entry):
        first, second = entry
        is_folder = first.startswith("~")
        key = (second or first) if is_folder else first
        return zlib.crc32(key.encode("utf-8")) % 4 == 0
    return [n for n in pool["train"] if is_valid(n) == (split == "valid")]


def unknown_writer(rng, split):
    prefixes, middles, suffixes = UNKNOWN_PARTS[split]
    if rng.random() < 0.6:
        name = rng.choice(prefixes) + rng.choice(middles) + "." + rng.choice(suffixes)
    else:
        name = rng.choice(middles).capitalize() + rng.choice(suffixes).capitalize()
    return (name, name)


def unknown_folder(rng, split):
    prefixes, middles, suffixes = UNKNOWN_PARTS[split]
    name = rng.choice(prefixes) + rng.choice(middles) + "." + rng.choice(suffixes)
    base = rng.choice(["~/Library/Application Support/", "~/Library/", "~/."])
    return (base + (name if base != "~/." else rng.choice(middles) + rng.choice(suffixes)), None)


def disk(rng):
    total = rng.choice([245, 494, 994, 1995])
    # Always above the hard low-space rule, so every case reaches the model.
    free = round(rng.uniform(max(25, total * 0.07), total * 0.7))
    return free, total


def fast_drop(rng, category, split):
    if category == "unknown":
        app, process = unknown_writer(rng, split)
    else:
        app, process = rng.choice(names(WRITERS[category], split))
    free, total = disk(rng)
    minutes = rng.choice([5, 10, 10, 10, 30])
    main = round(rng.uniform(3, 25), 1)
    writers = [] if (category == "system" and rng.random() < 0.5) else [{"app": app, "process": process, "gb": main}]
    if writers and rng.random() < 0.3:
        # A small second writer that does not explain the drop.
        other_app, other_process = rng.choice(names(WRITERS["system"], split))
        writers.append({"app": other_app, "process": other_process, "gb": round(main * rng.uniform(0.05, 0.25), 1)})
    drop = round(main * rng.uniform(1.0, 1.1), 1)
    name = app if writers else "系统"
    return {"minutes": minutes, "drop_gb": drop, "free_gb": free, "total_gb": total, "writers": writers}, name


def folder_growth(rng, category, split):
    if category == "unknown":
        path, owner = unknown_folder(rng, split)
    else:
        path, owner = rng.choice(names(FOLDERS[category], split))
    free, total = disk(rng)
    grown = round(rng.uniform(3, 30), 1)
    size = round(grown + rng.uniform(0.2, 40), 1)
    facts = {"days": rng.choice([3, 7, 7, 7, 14, 30]), "path": path, "owner": owner,
             "grown_gb": grown, "size_gb": size, "free_gb": free, "total_gb": total}
    name = owner or path.split("/")[-1]
    return facts, name


KINDS = {
    "fast_drop": ["user_activity", "system", "dev_work", "script", "app_data", "unknown"],
    "folder_growth": ["user_files", "cache", "log", "app_data", "system", "unknown"],
}
NOTIFY = {"user_files": False, "user_activity": False, "system": False, "dev_work": False,
          "script": True, "cache": True, "log": True, "app_data": True, "unknown": True}


def make(rng, split, count):
    rows = []
    for i in range(count):
        kind = "fast_drop" if i % 2 == 0 else "folder_growth"
        category = KINDS[kind][(i // 2) % len(KINDS[kind])]
        facts, name = (fast_drop if kind == "fast_drop" else folder_growth)(rng, category, split)
        reason = rng.choice(REASONS[category]).format(name=name)
        rows.append({"kind": kind, "facts": facts, "category": category, "reason": reason})
    rng.shuffle(rows)
    return rows


def all_names(split):
    found = set()
    for pools in (WRITERS, FOLDERS):
        for category in pools.values():
            for a, b in names(category, split):
                found.update(x for x in (a, b) if x)
    return found


def check_overlap():
    train, valid, test, test2 = all_names("train"), all_names("valid"), all_names("test"), all_names("test2")
    for a, b, label in ((train, test, "train/test"), (valid, test, "valid/test"), (train, valid, "train/valid"),
                        (train, test2, "train/test2"), (valid, test2, "valid/test2"), (test, test2, "test/test2")):
        clash = a & b
        assert not clash, f"{label} share names: {clash}"
    for dev in DEV_NAMES:
        for name in train | valid | test | test2:
            assert dev.lower() not in name.lower(), f"dev exam name {dev!r} appears in pool name {name!r}"


def main():
    check_overlap()
    rng = random.Random(20261022)
    os.makedirs(os.path.join(ROOT, "train", "data"), exist_ok=True)

    train = make(rng, "train", 1440)
    valid = make(random.Random(99), "valid", 240)
    for name, rows in (("facts-train.jsonl", train), ("facts-valid.jsonl", valid)):
        with open(os.path.join(ROOT, "train", "data", name), "w", encoding="utf-8") as f:
            for row in rows:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")

    test_rows = make(random.Random(7), "test", 60)
    cases = [{"id": f"T{n + 1:02d}", "kind": r["kind"], "facts": r["facts"], "category": r["category"],
              "expect_notify": NOTIFY[r["category"]]} for n, r in enumerate(test_rows)]
    exam = {"about": "独立测试集：由 train/make_data.py 生成，名字与训练集、模拟考（triage-cases.json）都不重叠。"
                     "category 为期望类别，expect_notify 由类别按代码里的规则推出。",
            "cases": cases}
    with open(os.path.join(ROOT, "eval", "triage-test.json"), "w", encoding="utf-8") as f:
        json.dump(exam, f, ensure_ascii=False, indent=1)

    # Fresh test set 2 (see TEST2_*).
    rows2 = make(random.Random(2026), "test2", 90)
    cases2 = [{"id": f"U{n + 1:02d}", "kind": r["kind"], "facts": r["facts"], "category": r["category"],
               "expect_notify": NOTIFY[r["category"]]} for n, r in enumerate(rows2)]
    exam2 = {"about": "独立测试集 2：第三轮补充系统类数据之后才生成，名字与训练集、验证集、测试集 1、模拟考都不重叠，"
                      "用作第三轮的最终裁判。",
             "cases": cases2}
    with open(os.path.join(ROOT, "eval", "triage-test-v2.json"), "w", encoding="utf-8") as f:
        json.dump(exam2, f, ensure_ascii=False, indent=1)

    counts = {}
    for row in train:
        counts[row["category"]] = counts.get(row["category"], 0) + 1
    print(f"train {len(train)} · valid {len(valid)} · test {len(cases)}")
    print(f"names: train {len(all_names('train'))} · valid {len(all_names('valid'))} · test {len(all_names('test'))} · test2 {len(all_names('test2'))}")
    print("per category:", dict(sorted(counts.items())))


if __name__ == "__main__":
    main()
