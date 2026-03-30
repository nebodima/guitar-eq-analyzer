import Foundation

final class PresetStore {
    private let fileURL: URL

    init(filename: String = "eq_saved.json") {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".guitar-eq-analyzer-swift", isDirectory: true)
        self.fileURL = root.appendingPathComponent(filename)
    }

    func load() -> EQPreset? {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(EQPreset.self, from: data)
        } catch {
            return nil
        }
    }

    @discardableResult
    func save(_ preset: EQPreset) throws -> URL {
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(preset)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    func pathString() -> String {
        fileURL.path
    }
}
