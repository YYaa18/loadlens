import SwiftUI
import AppKit

// MARK: - Window

final class AISettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = AISettingsWindowController()
    private var window: NSWindow?
    private let selection = SettingsSelection()

    func show(provider: String? = nil) {
        selection.id = provider ?? AIConfigStore.shared.settings.activeProvider

        if window == nil {
            let hosting = NSHostingView(rootView: AISettingsView(store: AIConfigStore.shared, selection: selection))
            let newWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered,
                                     defer: false)
            newWindow.title = "AI 模型设置"
            newWindow.titleVisibility = .hidden
            newWindow.titlebarAppearsTransparent = true
            newWindow.contentView = hosting
            newWindow.isReleasedWhenClosed = false
            newWindow.minSize = NSSize(width: 640, height: 480)
            newWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        if ProcessInfo.processInfo.environment["LOADLENS_AI_MOCK"] == "1"
            || CommandLine.arguments.contains("--settings-preview") {
            print("settings-window-number \(window?.windowNumber ?? 0)")
            fflush(stdout)
        }
    }
}

final class SettingsSelection: ObservableObject {
    @Published var id = "deepseek"
}

// MARK: - Root

struct AISettingsView: View {
    @ObservedObject var store: AIConfigStore
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ProviderDetailView(store: store, id: selection.id)
                .id(selection.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("模型服务")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 44)
                .padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ProviderPreset.all) { preset in
                        ProviderRow(preset: preset,
                                    store: store,
                                    selected: selection.id == preset.id) {
                            selection.id = preset.id
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            Divider().opacity(0.5)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.shield")
                Text("API Key 只保存在 macOS 钥匙串，不写入任何文件。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(12)
        }
        .frame(width: 216)
        .background(Color.primary.opacity(0.03))
    }
}

struct ProviderIcon: View {
    let preset: ProviderPreset
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(preset.tint.gradient)
            if preset.id == ProviderPreset.custom {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(preset.monogram)
                    .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct ProviderRow: View {
    let preset: ProviderPreset
    @ObservedObject var store: AIConfigStore
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let configured = store.isConfigured(preset.id)
        let active = store.settings.activeProvider == preset.id

        Button(action: action) {
            HStack(spacing: 9) {
                ProviderIcon(preset: preset, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(configured ? store.config(for: preset.id).model : "未配置")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if active {
                    Text("使用中")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(LoadLevel.calm.tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(LoadLevel.calm.tint.opacity(0.15)))
                } else if configured {
                    Circle().fill(LoadLevel.calm.tint).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16)
                                   : Color.primary.opacity(hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Detail

private struct ProviderDetailView: View {
    @ObservedObject var store: AIConfigStore
    let id: String

    @State private var keyDraft = ""
    @State private var revealKey = false
    @State private var keyStatus: String?
    @State private var newModel = ""
    @State private var modelFilter = ""
    @State private var fetching = false
    @State private var fetchError: String?
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    private var preset: ProviderPreset { ProviderPreset.find(id) }
    private var config: ProviderConfig { store.config(for: id) }
    private var isCustom: Bool { id == ProviderPreset.custom }
    private var style: APIStyle { isCustom ? config.style : preset.style }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if preset.requiresKey || isCustom { keySection }
                endpointSection
                modelSection
                testSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)
            .padding(.bottom, 24)
        }
    }

    // Header

    private var header: some View {
        let active = store.settings.activeProvider == id
        return HStack(alignment: .top, spacing: 12) {
            ProviderIcon(preset: preset, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.name)
                    .font(.system(size: 18, weight: .semibold))
                if !preset.note.isEmpty {
                    Text(preset.note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if active {
                Label("正在使用", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LoadLevel.calm.tint)
                    .padding(.top, 4)
            } else {
                Button("设为当前模型") { store.activate(id) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(!store.isConfigured(id))
                    .help(store.isConfigured(id) ? "AI 分析将使用这个服务" : "先填写 API Key 和模型")
            }
        }
    }

    // API key

    private var keySection: some View {
        FormSection(title: "API Key", trailing: keyLink) {
            HStack(spacing: 8) {
                Group {
                    if revealKey {
                        TextField(keyPlaceholder, text: $keyDraft)
                    } else {
                        SecureField(keyPlaceholder, text: $keyDraft)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .onSubmit { saveKey() }

                Button { revealKey.toggle() } label: {
                    Image(systemName: revealKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealKey ? "隐藏" : "显示")

                Button("保存") { saveKey() }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 6) {
                if config.hasKey {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(LoadLevel.calm.tint)
                    Text(keyStatus ?? "已保存在钥匙串")
                    Spacer()
                    Button("删除 Key") {
                        store.removeKey(for: id)
                        keyStatus = nil
                        testResult = nil
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(LoadLevel.hot.tint)
                } else {
                    Image(systemName: "info.circle")
                    Text(keyStatus ?? (isCustom ? "接口不需要鉴权时可以留空" : "还没有保存 Key"))
                    Spacer()
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var keyPlaceholder: String {
        config.hasKey ? "已保存，输入新的 Key 可替换" : (style == .anthropic ? "sk-ant-…" : "sk-…")
    }

    @ViewBuilder
    private var keyLink: some View {
        if let link = preset.keyURL, let url = URL(string: link) {
            Link(destination: url) {
                Label("获取 API Key", systemImage: "arrow.up.right.square")
                    .font(.system(size: 11))
            }
        }
    }

    private func saveKey() {
        let value = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if store.saveKey(value, for: id) {
            keyDraft = ""
            keyStatus = "已保存在钥匙串"
            testResult = nil
            // First usable provider becomes the active one automatically.
            if !store.isReady { store.activate(id) }
        } else {
            keyStatus = "保存失败，请检查钥匙串权限"
        }
    }

    // Endpoint

    private var endpointSection: some View {
        FormSection(title: "接口地址", trailing: resetButton) {
            if isCustom {
                Picker("接口格式", selection: binding(\.style)) {
                    ForEach(APIStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            TextField(isCustom ? "https://your-gateway.example.com/v1" : preset.baseURL,
                      text: binding(\.baseURL))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
            Text(requestPreview)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var resetButton: some View {
        if !isCustom && config.baseURL != preset.baseURL {
            Button("恢复默认") { store.update(id) { $0.baseURL = preset.baseURL } }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
    }

    private var requestPreview: String {
        var base = config.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return "请求地址：—" }
        switch style {
        case .openAI: return "请求地址：\(base)/chat/completions"
        case .anthropic: return "请求地址：\(base.hasSuffix("/v1") ? base : base + "/v1")/messages"
        }
    }

    // Models

    private var modelSection: some View {
        let all = store.models(for: id)
        let filtered = modelFilter.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(modelFilter) }

        return FormSection(title: "模型", trailing: fetchButton) {
            if all.count > 10 {
                TextField("搜索 \(all.count) 个模型", text: $modelFilter)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(spacing: 0) {
                if filtered.isEmpty {
                    Text(all.isEmpty ? "还没有模型，点右上角「获取模型列表」，或在下面手动添加" : "没有匹配的模型")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(filtered, id: \.self) { model in
                                ModelRow(name: model,
                                         selected: config.model == model,
                                         custom: config.customModels.contains(model)) {
                                    store.update(id) { $0.model = model }
                                    testResult = nil
                                } onRemove: {
                                    store.update(id) { $0.customModels.removeAll { $0 == model } }
                                }
                            }
                        }
                    }
                    .frame(height: min(CGFloat(filtered.count) * 30, 210))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )

            HStack(spacing: 8) {
                TextField("手动添加模型名，例如 \(preset.models.first ?? "my-model")", text: $newModel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addModel() }
                Button("添加") { addModel() }
                    .disabled(newModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let fetchError {
                Label(fetchError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(LoadLevel.busy.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fetchButton: some View {
        HStack(spacing: 6) {
            if fetching { ProgressView().controlSize(.small) }
            Button("获取模型列表") { fetchModels() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .disabled(fetching || config.baseURL.isEmpty)
        }
    }

    private func addModel() {
        let name = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.update(id) {
            if !$0.customModels.contains(name) { $0.customModels.append(name) }
            $0.model = name
        }
        newModel = ""
        testResult = nil
    }

    private func fetchModels() {
        fetching = true
        fetchError = nil
        let endpoint = draftEndpoint()
        Task {
            do {
                let models = try await LLMClient.shared.listModels(endpoint: endpoint)
                await MainActor.run {
                    store.update(id) {
                        $0.fetchedModels = models
                        if $0.model.isEmpty, let first = models.first { $0.model = first }
                    }
                    fetching = false
                    if models.isEmpty { fetchError = "服务没有返回任何模型" }
                }
            } catch {
                await MainActor.run {
                    fetching = false
                    fetchError = "获取失败：\(error.localizedDescription)。可以手动添加模型名。"
                }
            }
        }
    }

    // Test

    private var testSection: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                runTest()
            } label: {
                HStack(spacing: 5) {
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.horizontal.circle")
                    }
                    Text(testing ? "测试中…" : "测试连接")
                }
            }
            .controlSize(.large)
            .disabled(testing || config.model.isEmpty || config.baseURL.isEmpty)

            if let testResult {
                Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(testResult.ok ? LoadLevel.calm.tint : LoadLevel.hot.tint)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func runTest() {
        testing = true
        testResult = nil
        let endpoint = draftEndpoint()
        let started = Date()
        Task {
            do {
                let reply = try await LLMClient.shared.test(endpoint: endpoint)
                let seconds = Date().timeIntervalSince(started)
                await MainActor.run {
                    testing = false
                    let preview = reply.isEmpty ? "（无文字回复）" : String(reply.prefix(30))
                    testResult = (true, String(format: "连接成功，用时 %.1f 秒 · 回复：%@", seconds, preview))
                }
            } catch {
                await MainActor.run {
                    testing = false
                    testResult = (false, error.localizedDescription)
                }
            }
        }
    }

    /// Current settings, using an unsaved key draft if the user typed one.
    private func draftEndpoint() -> LLMEndpoint {
        let saved = store.endpoint(for: id)
        let draft = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMEndpoint(preset: saved.preset,
                           style: saved.style,
                           baseURL: saved.baseURL,
                           model: saved.model,
                           apiKey: draft.isEmpty ? saved.apiKey : draft)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ProviderConfig, T>) -> Binding<T> {
        Binding(get: { store.config(for: id)[keyPath: keyPath] },
                set: { value in
                    store.update(id) { $0[keyPath: keyPath] = value }
                    testResult = nil
                })
    }
}

private struct FormSection<Trailing: View, Content: View>: View {
    let title: String
    let trailing: Trailing
    let content: Content

    init(title: String, trailing: Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                trailing
            }
            content
        }
    }
}

private struct ModelRow: View {
    let name: String
    let selected: Bool
    let custom: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.6))
                Text(name)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if custom && hovering {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("移除这个自定义模型")
                } else if custom {
                    Text("自定义")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(hovering ? 0.05 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
