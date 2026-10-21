# 负载侦探 LoadLens

![负载侦探图标](Resources/icon_1024.png)

一个用大白话告诉你「电脑为什么变慢、风扇为什么响」的 macOS 菜单栏小工具。

菜单栏常驻一个 CPU 圆环 + 百分比（点击它打开面板），点开就能看到：

- 状态总览卡片：一句话结论、CPU 大数字、趋势曲线（平均值 / 峰值 / 负载）
- 内存、温度、磁盘三个指标卡（悬停看交换区、压缩内存等细节，点磁盘卡进入「硬盘」页）
- 「硬盘」页：
  - 启动盘容量（已用 / 可自动清除 / 空闲）、SMART 健康状态、本地 Time Machine 快照数量
  - 实时读写速度和曲线，以及读写最多的应用
  - 外接磁盘的容量，一键推出
  - 「可清理空间」分析：统计下载、废纸篓、应用缓存、日志、Xcode、iOS 模拟器、开发工具缓存、iPhone 备份的大小，可在访达中打开查看；只读大小，不删除任何文件
- 占用排行（按应用合并，比如 Chrome 的所有渲染进程算一项），悬停可退出应用、在访达中显示
- 根据当前情况生成的「诊断建议」，以及一键进入 AI 深入分析
- 右上角齿轮菜单：开机自启、高负载通知、AI 设置、复制诊断报告、退出
- 持续高负载 2 分钟时弹系统通知（30 分钟内不重复打扰）
- 让 AI 结合当前快照做分析，也可以继续追问；支持 DeepSeek、OpenAI、Claude、Gemini、国产大模型、本地 Ollama 和自定义接口
- 一键复制诊断信息，方便发给别人求助

## 运行

```bash
./install.sh
```

脚本会编译并安装到 `~/Applications/负载侦探.app`，然后启动。也可以直接：

```bash
./build.sh
open build/LoadLens.app
```

终端里做一次体检（不开界面）：

```bash
./build/LoadLens.app/Contents/MacOS/LoadLens --diagnose
```

## AI 分析

支持主流大模型服务，也可以接本地模型或任意兼容接口：

| 服务 | 接口格式 |
| --- | --- |
| DeepSeek、OpenAI、Google Gemini、Kimi、通义千问、智谱 GLM、硅基流动、OpenRouter | OpenAI 兼容（`/chat/completions`） |
| Anthropic Claude | Anthropic 原生 Messages 接口（`/v1/messages`） |
| Ollama（本地） | OpenAI 兼容，无需 Key |
| 自定义 | 可选 OpenAI 兼容或 Anthropic 格式，适合公司网关、LM Studio、vLLM 等 |

1. 打开菜单栏面板 → 右上角齿轮 →「AI 模型设置…」（或 AI 窗口右上角齿轮）。
2. 左侧选择服务，填 API Key（只存 macOS 钥匙串），需要时修改接口地址。
3. 点「获取模型列表」从服务端拉取可用模型，或手动添加模型名；点「测试连接」确认可用。
4. 点「设为当前模型」。之后在 AI 窗口顶部的模型名上可以随时切换已配置的服务和模型。
5. 面板底部点「让 AI 帮我深入分析」，AI 助手直接在面板旁边展开（右侧放得下就在右侧，否则在左侧），并自动分析一次当前状态。Return 发送，Shift+Return 换行。
6. AI 助手顶部的「AI 实时读取」会随面板一起刷新，每次提问都带上最新数据；需要更大的窗口时，点右上角的窗口图标改为独立窗口。

### AI 能自己查数据（工具调用）

AI 不只看一份摘要：它可以按需调用只读工具深入分析，回答里会显示它查了什么（例如「✓ 查看「应用缓存」明细」）。

| 工具 | 能查到什么 |
| --- | --- |
| `list_apps` | 所有应用按 CPU / 内存 / 磁盘读写排序 |
| `get_app_processes` | 某个应用下的每个进程 |
| `get_memory_details` | 内存、压缩内存、交换区、占内存最多的应用 |
| `get_disk_details` | 所有磁盘容量、健康、快照、读写速度 |
| `get_space_overview` | 可清理空间总览（没分析过会自动分析） |
| `analyze_folder` | 某个目录里每个子文件夹的大小、属于哪个应用、应用是否还安装 / 正在运行、最近修改时间 |
| `get_history` | 最近几分钟 CPU 或硬盘读写的趋势 |
| `get_system_info` | 型号、芯片、macOS 版本、运行时间等 |

所有工具都是只读的：AI 不能删除文件或结束进程，只会告诉你在哪里操作。「硬盘」页每一项旁边的 ✨、占用排行「⋯」菜单里的「问 AI」可以一键让 AI 分析那一项。OpenAI 兼容接口和 Anthropic 接口都支持；不支持工具调用的模型会自动退回普通对话。

每次提问会把当前的 CPU、内存、温度、占用最高的应用名和本机规则建议作为上下文，发送到你选择的服务。AI 调用工具时，会额外发送它查询到的结果（应用名、进程名、文件夹名和大小）。不会发送文件内容。窗口顶部「AI 实时读取」一栏可以查看完整的快照内容。对话只保存在内存里，退出应用即清空。

使用 Anthropic 官方接口和 Claude Opus / Sonnet 5.5 等模型时，会自动开启服务端 `fallbacks`：如果请求被安全策略拒绝，由服务端换用其他模型重试。

## 它为什么很省资源

- 面板关闭时每 6 秒采样一次总量和本用户进程，实测 CPU 约 0.2%。
- 面板打开时每 5 秒一次，额外读取系统进程和每个进程的磁盘读写，实测 CPU 约 0.7%。
- 「实时」脉冲点用 Core Animation 绘制，不会让界面每帧重绘。
- 硬盘健康（`diskutil`、`tmutil`）最多 30 分钟读一次；可清理空间只在点击「开始分析」时统计，用和 `du` 相同的 `fts` 遍历，几个位置并行，大目录会显示实时进度。
- 进程数据来自系统 `libproc` 接口，不启动 `top`，不轮询整个进程树。
- 系统进程（WindowServer、kernel_task 等）因为普通用户权限读不到，才用 `ps` 兜底：CPU 每 30 秒刷新，进程名每 5 分钟刷新。
- 不联网、不需要 sudo、不需要辅助功能或屏幕录制权限、不读取文件内容。

## 数据来源

| 指标 | 来源 |
| --- | --- |
| 整机 CPU | `host_processor_info` tick 差值 |
| 单进程 CPU / 内存 | `proc_pidinfo(PROC_PIDTASKINFO)` 差值 |
| 系统进程 | `/bin/ps -axo pid=,pcpu=,rss=,comm=`（仅面板打开时） |
| 内存 / 压缩内存 | `host_statistics64` + `sysctl vm.swapusage` |
| 温度状态 | `ProcessInfo.thermalState` |
| 负载 / 运行时间 | `getloadavg` / `sysctl kern.boottime` |
| 通知 | `UserNotifications`（首次开启时请求授权） |
| 磁盘容量 | `URLResourceKey.volumeAvailableCapacityForImportantUsage` 等 |
| 整机读写速度 | IOKit `IOBlockStorageDriver` 的 Statistics |
| 单进程读写 | `proc_pid_rusage`（仅本用户进程） |
| 硬盘健康 / 本地快照 | `diskutil info -plist /`、`tmutil listlocalsnapshots /` |
| 可清理空间 | `fts` 遍历常见目录，只读文件大小 |
| 开机自启 | `~/Library/LaunchAgents/local.loadlens.agent.plist` |
| AI 分析 | 用户选择的服务，流式返回（OpenAI 兼容 / Anthropic Messages） |

## 已知限制

- 没有读取风扇转速和具体温度：需要访问 SMC 或 `sudo powermetrics`，为了保持零权限暂时没做。
- 系统进程的 CPU 来自 `ps` 的近期平均值，不是严格瞬时值。
- 系统进程（其他用户）的磁盘读写读不到，只能看到整机总量；没有拆分 GPU 占用。
- 废纸篓、iPhone 备份等目录受系统隐私保护，需要在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」里允许负载侦探才能统计；第一次分析「下载」时系统可能询问访问权限。
- 应用缓存可能有几十万个小文件，统计一次需要几十秒，这是文件系统本身的速度。
- 通知需要系统授权；高负载要持续 2 分钟才提醒，30 分钟内最多一次。
- 趋势曲线只保存在内存里，退出应用后清空。
- AI 分析需要自备对应服务的 API Key（本地 Ollama 除外），按各家标准计费；对话不落盘。重新编译应用后，首次读取钥匙串可能要求授权。
- 预置的模型名可能随厂商更新而过时，用「获取模型列表」拉取最新列表即可。
- 需要 macOS 13 及以上（使用了 `MenuBarExtra`）。

## 图标

深色圆角底 + 白色放大镜，镜片里是三根从黄到红、逐渐升高的柱子：放大镜代表“侦探”，递增的暖色柱子代表正在升高的负载，底部的暖光暗示发热。

源文件是 `Resources/icon_1024.png`，打包用 `Resources/AppIcon.icns`。重新生成：

```bash
swiftc -O -parse-as-library tools/IconGen.swift -o /tmp/icongen
/tmp/icongen Resources/icon_1024.png
```

## 目录

```
Sources/Sampler.swift    系统数据采样
Sources/Disk.swift       磁盘容量、读写速度、健康状态
Sources/SpaceScanner.swift   可清理空间分析
Sources/DiskViews.swift  「硬盘」页界面
Sources/Model.swift      进程合并、应用归组、ps 兜底
Sources/Diagnoser.swift  诊断规则与建议生成
Sources/LoginItem.swift  开机自启（LaunchAgent）
Sources/Notifier.swift   高负载系统通知
Sources/Keychain.swift   API Key 的钥匙串存取（每个服务一条）
Sources/AIProviders.swift    预置模型服务、配置存储
Sources/LLMClient.swift      通用流式客户端与工具调用循环（OpenAI 兼容 / Anthropic）
Sources/AITools.swift        AI 可调用的只读数据工具
Sources/AISettingsView.swift AI 模型设置窗口
Sources/Theme.swift      配色、卡片与通用控件
Sources/MarkdownText.swift   AI 回复的 Markdown 渲染
Sources/AIChat.swift     AI 对话状态与上下文
Sources/AIChatView.swift AI 窗口界面
Sources/AIChatWindow.swift   AI 独立窗口管理
Sources/AIDock.swift     AI 助手贴在面板旁边展开（左右自适应）
Sources/Monitor.swift    定时调度、历史曲线与发布
Sources/Views.swift      面板界面
Sources/App.swift        菜单栏入口
Sources/CLI.swift        终端报告与开发用预览
Resources/AppIcon.icns   应用图标
tools/IconGen.swift      图标生成器
```

## 许可协议

本项目采用 [PolyForm Noncommercial License 1.0.0](LICENSE.md)。

- ✅ **个人、学习、研究、非营利组织使用**：免费，可以随意下载、修改和分享（分享时请保留 `LICENSE.md`）。
- 💼 **商业用途**（公司内部使用、集成到收费产品或服务、二次售卖等）：需要另外获得商业授权，请在 GitHub 上[提交 Issue](https://github.com/YYaa18/loadlens/issues) 联系作者。

Copyright © 2026 YYaa18
