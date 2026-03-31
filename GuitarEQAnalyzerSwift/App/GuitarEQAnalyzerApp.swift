import AppKit
import SwiftUI

private class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Если уже запущена другая копия — поднять её окно и выйти.
        let bundleID = Bundle.main.bundleIdentifier
            ?? "GuitarEQAnalyzerSwift"
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID)
        let others = running.filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first {
            existing.activate(options: .activateIgnoringOtherApps)
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct GuitarEQAnalyzerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = AudioEngineManager()

    var body: some Scene {
        WindowGroup("Guitar EQ Analyzer") {
            ContentView(engine: engine)
                .frame(minWidth: 900, minHeight: 720)
        }
    }
}
