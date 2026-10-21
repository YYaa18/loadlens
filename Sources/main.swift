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
