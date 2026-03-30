import SwiftUI

@main
struct GuitarEQAnalyzerApp: App {
    @StateObject private var engine = AudioEngineManager()

    var body: some Scene {
        WindowGroup("Guitar EQ Analyzer") {
            ContentView(engine: engine)
                .frame(minWidth: 1160, minHeight: 760)
        }
    }
}
