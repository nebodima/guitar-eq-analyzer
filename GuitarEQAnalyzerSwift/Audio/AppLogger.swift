import Foundation

/// Простой файловый логгер. Пишет в ~/guitar-eq-log.txt
/// Читать: tail -f ~/guitar-eq-log.txt
enum AppLog {
    private static let logURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("guitar-eq-log.txt")
    }()

    private static let lock = NSLock()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let ts   = dateFormatter.string(from: Date())
        let line = "[\(ts)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let fh = try? FileHandle(forWritingTo: logURL) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try? fh.close()
                }
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }

    static func clear() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }
}
