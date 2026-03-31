import AppKit
import SwiftUI

/// Нужен чтобы приложение появлялось в Dock и получало фокус при запуске через swift run
/// (SPM-executable без .app bundle не регистрируется как GUI-приложение автоматически)
private class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct GuitarEQAnalyzerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = AudioEngineManager()

    var body: some Scene {
        WindowGroup("Guitar EQ Analyzer") {
            ContentView(engine: engine)
                .frame(minWidth: 1160, minHeight: 760)
        }
    }
}
