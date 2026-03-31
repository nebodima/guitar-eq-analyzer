import Foundation

/// Файловый логгер. Пишет в ~/guitar-eq-log.txt только в DEBUG-сборках.
/// В release все вызовы — no-op.
enum AppLog {
    enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR" }

    private static let logURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("guitar-eq-log.txt")
    }()
    private static let lock = NSLock()
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func write(_ message: String, level: Level = .info) {
#if DEBUG
        let line = "[\(fmt.string(from: Date()))] [\(level.rawValue)] \(message)\n"
        lock.lock(); defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fh = try? FileHandle(forWritingTo: logURL) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
#endif
    }

    static func warn(_ msg: String)  { write(msg, level: .warn) }
    static func error(_ msg: String) { write(msg, level: .error) }

    static func clear() {
#if DEBUG
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
#endif
    }
}
