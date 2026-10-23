# AGENTS.md

Instructions for AI coding agents (Claude Code, Cursor, Codex, Copilot, …) working with this repository.
The user-facing documentation is [README.md](README.md) (Chinese). Reply to the user in the language they use.

## What this is

**负载侦探 LoadLens** is a native macOS menu bar app (Swift + SwiftUI, no Xcode project, no
package manager; the only third-party code is a pinned, prebuilt llama.cpp framework that
`tools/fetch-llama.sh` downloads into `vendor/`, checksum-verified, for the on-device model). It shows CPU / memory / disk usage in plain language and has an AI assistant
that can call read-only data tools. The app's UI is in Chinese.

- Bundle ID: `local.loadlens` · executable: `LoadLens` · installed as `~/Applications/负载侦探.app`
- Runs as a menu bar item only (no Dock icon). It needs no sudo and no special permissions.

## Installing for a user

Follow these steps in order. Run every command as the normal user — **never use `sudo`**.

### 1. Check requirements

```bash
sw_vers -productVersion     # must be 13.0 or later
xcrun swiftc --version      # needs Xcode Command Line Tools (Swift 5.9+; tested with Swift 6.4)
```

If `xcrun` reports `invalid active developer path` or swiftc is missing, the Command Line Tools are
not installed. Tell the user to run `xcode-select --install` and click through the installer dialog
themselves (it is a GUI prompt and may require their password), then continue.

### 2. Get the code

```bash
git clone https://github.com/YYaa18/loadlens.git
cd loadlens
```

If the repository is already cloned, `git pull` inside it instead.

### 3. (Optional) stable local signing

```bash
./tools/setup-signing.sh
```

Creates a self-signed code-signing certificate named `LoadLens Local Signing` in the user's login
keychain (never leaves the machine). Builds signed with it keep the same identity, so macOS privacy
grants (e.g. Full Disk Access) survive rebuilds. Skippable: without it builds are signed ad hoc.
It is idempotent. Ask the user first if they did not request it.

### 4. Build, install and launch

```bash
./install.sh
```

This compiles (about a minute), quits any running copy, installs to `~/Applications/负载侦探.app`
and launches it. Success ends with the line `已安装并启动：…`. Compiler warnings are expected;
only lines containing `error:` mean failure.

### 5. Verify

```bash
pgrep -x LoadLens && echo "running"
"$HOME/Applications/负载侦探.app/Contents/MacOS/LoadLens" --diagnose
```

`--diagnose` prints a health report without opening any UI. A working install prints a block that
starts with `负载侦探 · 本机体检` and contains lines beginning with `状态：`, `启动盘`, `占用最高的应用：`
and `建议：`. Report the result to the user, then point them to the menu bar: a small ring with a CPU
percentage appears near the top-right of the screen; clicking it opens the panel. (On MacBooks with a
notch, a crowded menu bar can hide items — if the process is running but the user can't see the
icon, suggest closing a few other menu bar apps.)

### 6. Steps only the user should do

Tell the user about these; do not do them on their behalf:

- **AI assistant setup:** the panel's gear menu → `AI 模型设置…` → pick a provider and paste an API
  key. Never ask the user to paste an API key into the chat with you, and never type keys into the
  app for them. Local Ollama needs no key.
- **Keychain prompt:** the first time the AI reads a saved key, macOS may ask for Keychain access —
  the user should click `始终允许` (Always Allow).
- **Optional privacy permissions:** Full Disk Access (System Settings → Privacy & Security) is only
  needed to measure the Trash and iPhone backups in the disk page.
- **Launch at login:** the gear menu → `开机自动启动`.

## Uninstalling

```bash
./uninstall.sh           # quits the app, removes it and its login item; keeps settings and API keys
./uninstall.sh --purge   # also deletes settings and the API keys stored in the Keychain
```

Only use `--purge` if the user explicitly wants their saved keys deleted.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `xcrun: error: invalid active developer path` | Command Line Tools missing — user runs `xcode-select --install` |
| `error:` lines mentioning SwiftUI APIs | Swift toolchain too old — update Xcode / Command Line Tools |
| Installed, but an old version is still showing | Run `./install.sh` again (it quits the running copy first) |
| No icon in the menu bar but `pgrep -x LoadLens` finds it | Menu bar is full / hidden behind the notch |
| Repeated Keychain password prompts | User clicks `始终允许`; keys are stored so later rebuilds don't ask again |
| AI says the model doesn't exist (404) | Model name is outdated — `AI 模型设置` → `获取模型列表` |

## Developing

### Build and run

```bash
./build.sh                                   # builds build/LoadLens.app (prints "built:" and "signed:")
open build/LoadLens.app                      # run without installing
./install.sh                                 # build + install + relaunch
```

`build.sh` first runs `tools/fetch-llama.sh` (network needed once; `vendor/` is git-ignored). To upgrade
llama.cpp, change `VERSION` and `SHA256` there together and rerun `--llm-test`, since its C API changes often.

There is no Xcode project and no SwiftPM package: `build.sh` passes an explicit list of source files
to `swiftc`. **When you add a new `.swift` file, add it to the list in `build.sh`**, or the build fails
with "cannot find … in scope".

### Verifying changes (there is no unit test suite)

- Always finish with a clean `./build.sh` (no `error:` lines).
- `--diagnose` — terminal health report; checks sampling, disk and diagnosis logic.
- `--tool-test <tool> '<json>'` — runs one AI tool against live data, e.g.
  `build/LoadLens.app/Contents/MacOS/LoadLens --tool-test analyze_folder '{"target":"logs"}'`.
- `--preview-window [seconds]` — shows the panel in a normal window for screenshots.
- `LOADLENS_AI_MOCK=1` — AI replies with canned text, no network or key needed.
- `LOADLENS_MAX_HEIGHT=<points>` — pretend the screen is only this tall, to check the responsive
  panel layout (header/footer fixed, middle scrolls, AI pane capped) on a large display.
- `LOADLENS_SETTINGS_SUITE=<name>` — isolated settings and Keychain entries, so tests never touch the
  user's real configuration. Clean up afterwards (`defaults delete local.loadlens.<name>`).

See the README's "开发用命令行参数" section for the full list.

### Conventions

- UI text is Simplified Chinese, written for non-technical users. Code comments are English.
- Stay permission-free: no sudo, no Accessibility / Screen Recording, never read file contents
  (sizes and metadata only).
- Disk alerts go through `TriageService` before notifying. The bundled model
  (`Resources/triage/`, bge-small-zh 8-bit + `probe.json`) runs in a short-lived helper process
  (`LoadLens --triage-judge`), never inside the menu bar app: initialising llama.cpp alone costs
  ~94MB that is not returned while the process lives. Keep it that way. `probe.json` only fits that
  exact model file; retrain it (see `train/README.md`) if the model changes.
- Asking the cloud model is opt-in (off by default) and sends only event descriptions
  (process / folder names and sizes). User corrections in the answer memory always win.
- Everything sent to a cloud model (chat snapshot, messages, tool results, cloud triage) goes through
  `Redactor` when the user's privacy switch is on (default): personal file/folder names, account and
  computer names, emails, phones and IPs become codes such as 【文件1.dmg】 and are restored locally in
  the reply. New tools that return paths or names from the user's own folders must keep working with it.
- AI tools in `Sources/AITools.swift` must stay **read-only**. Never add tools that delete files,
  kill processes or change settings.
- Keep it light: the app idles at ~0.2% CPU (panel closed) and ~0.7% (panel open). Avoid SwiftUI
  `repeatForever` animations in always-mounted views (they re-render the whole panel every frame);
  use Core Animation layers as `LiveDot` does.
- API keys live only in the Keychain (`Sources/Keychain.swift`), never in files or logs.
- Commit messages are in Chinese, summarising user-visible changes.

### Layout

```
Sources/        all app code (see README → 目录结构 for a per-file summary)
Resources/      app icon
tools/          setup-signing.sh, IconGen.swift
build.sh        compile + sign → build/LoadLens.app
install.sh      build + install to ~/Applications + launch
uninstall.sh    remove the app (optionally settings and keys)
```

## License

PolyForm Noncommercial 1.0.0 — free for non-commercial use; commercial use needs a separate license
from the author (see [LICENSE.md](LICENSE.md)). Mention this if the user wants to use it at a company
or in a paid product.
