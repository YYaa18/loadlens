# 负载侦探 LoadLens

![负载侦探图标](Resources/icon_1024.png)

一个用大白话告诉你「电脑为什么变慢、风扇为什么响」的 macOS 菜单栏小工具。

菜单栏常驻一个 CPU 圆环 + 百分比（点击它打开面板），点开就能看到：

- 状态总览卡片：一句话结论、CPU 大数字、趋势曲线（平均值 / 峰值）
- 内存、温度、负载三个指标卡（悬停看交换区、压缩内存等细节）
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
5. 面板底部点「让 AI 帮我深入分析」，AI 窗口在面板位置打开并自动分析一次当前状态。Return 发送，Shift+Return 换行。

每次提问会把当前的 CPU、内存、温度、占用最高的应用名和本机规则建议作为上下文，发送到你选择的服务。不会发送文件内容。窗口顶部「AI 能看到」一栏可以查看完整内容。对话只保存在内存里，退出应用即清空。

使用 Anthropic 官方接口和 Claude Opus / Sonnet 5.5 等模型时，会自动开启服务端 `fallbacks`：如果请求被安全策略拒绝，由服务端换用其他模型重试。

## 它为什么很省资源

- 面板关闭时只读取 CPU / 内存 / 温度这几项总量，每 6 秒一次，实测 CPU 约 0.4%，内存约 35–60 MB。
- 面板打开时才扫描进程，每 5 秒一次，实测 CPU 约 1%。
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
| 开机自启 | `~/Library/LaunchAgents/local.loadlens.agent.plist` |
| AI 分析 | 用户选择的服务，流式返回（OpenAI 兼容 / Anthropic Messages） |

## 已知限制

- 没有读取风扇转速和具体温度：需要访问 SMC 或 `sudo powermetrics`，为了保持零权限暂时没做。
- 系统进程的 CPU 来自 `ps` 的近期平均值，不是严格瞬时值。
- 没有拆分单个进程的磁盘 I/O 和 GPU 占用。
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
Sources/Model.swift      进程合并、应用归组、ps 兜底
Sources/Diagnoser.swift  诊断规则与建议生成
Sources/LoginItem.swift  开机自启（LaunchAgent）
Sources/Notifier.swift   高负载系统通知
Sources/Keychain.swift   API Key 的钥匙串存取（每个服务一条）
Sources/AIProviders.swift    预置模型服务、配置存储
Sources/LLMClient.swift      通用流式客户端（OpenAI 兼容 / Anthropic）
Sources/AISettingsView.swift AI 模型设置窗口
Sources/Theme.swift      配色、卡片与通用控件
Sources/MarkdownText.swift   AI 回复的 Markdown 渲染
Sources/AIChat.swift     AI 对话状态与上下文
Sources/AIChatView.swift AI 窗口界面
Sources/AIChatWindow.swift   AI 窗口管理
Sources/Monitor.swift    定时调度、历史曲线与发布
Sources/Views.swift      面板界面
Sources/App.swift        菜单栏入口
Sources/CLI.swift        终端报告与开发用预览
Resources/AppIcon.icns   应用图标
tools/IconGen.swift      图标生成器
```
