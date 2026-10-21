import Foundation
import AppKit
import Darwin

if CommandLine.arguments.contains("--keychain-test") {
    let saved = Keychain.save("loadlens-test-key", account: "selftest")
    let loaded = Keychain.load(account: "selftest")
    Keychain.delete(account: "selftest")
    let deleted = Keychain.load(account: "selftest") == nil
    print("keychain save=\(saved) load=\(loaded == "loadlens-test-key") delete=\(deleted)")
    exit(0)
}

if CommandLine.arguments.contains("--login-item-on") {
    try? LoginItem.setEnabled(true)
    print("login item enabled: \(LoginItem.isEnabled)")
    exit(0)
}

if CommandLine.arguments.contains("--login-item-off") {
    try? LoginItem.setEnabled(false)
    print("login item enabled: \(LoginItem.isEnabled)")
    exit(0)
}

if CommandLine.arguments.contains("--diagnose") {
    runDiagnosticReport()
    exit(0)
}

// Developer check: run one AI tool against live data, e.g. --tool-test analyze_folder '{"target":"caches"}'
if let index = CommandLine.arguments.firstIndex(of: "--tool-test") {
    let args = CommandLine.arguments
    let name = args.count > index + 1 ? args[index + 1] : "list_apps"
    let raw = args.count > index + 2 ? args[index + 2] : "{}"
    let arguments = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Monitor.shared.start()
        Monitor.shared.panelDidOpen()
        RunLoop.main.run(until: Date().addingTimeInterval(7))
        var output: String?
        Task { output = await AITools.execute(name, arguments) }
        while output == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        print(output ?? "")
    }
    exit(0)
}

if CommandLine.arguments.contains("--settings-preview") {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.regular)
        AISettingsWindowController.shared.show()
        NSApplication.shared.run()
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--preview-window") {
    let seconds = CommandLine.arguments.count > index + 1
        ? (Double(CommandLine.arguments[index + 1]) ?? 12)
        : 12
    MainActor.assumeIsolated {
        showPreviewWindow(seconds: seconds)
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--render-preview") {
    let path = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "/tmp/loadlens-panel.png"
    MainActor.assumeIsolated {
        renderPreview(to: path)
    }
    exit(0)
}

LoadLensApp.main()
