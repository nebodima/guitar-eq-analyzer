import Foundation

final class PresetStore {
    private let dir: URL
    private let lastUsedURL: URL
    private let namedURL:    URL

    init() {
        dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".guitar-eq-analyzer-swift", isDirectory: true)
        lastUsedURL = dir.appendingPathComponent("eq_saved.json")
        namedURL    = dir.appendingPathComponent("eq_presets.json")
    }

    // ── Last-used (авто-сохранение) ─────────────────────────
    func loadLastUsed() -> EQPreset? {
        guard let data = try? Data(contentsOf: lastUsedURL) else { return nil }
        return try? JSONDecoder().decode(EQPreset.self, from: data)
    }

    func saveLastUsed(_ preset: EQPreset) {
        try? ensureDir()
        let data = try? JSONEncoder().encode(preset)
        try? data?.write(to: lastUsedURL, options: .atomic)
    }

    // ── Named presets ────────────────────────────────────────
    func loadNamed() -> [NamedPreset] {
        guard let data = try? Data(contentsOf: namedURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([NamedPreset].self, from: data)) ?? []
    }

    func saveNamed(_ presets: [NamedPreset]) {
        try? ensureDir()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .prettyPrinted
        let data = try? enc.encode(presets)
        try? data?.write(to: namedURL, options: .atomic)
    }

    func defaultPreset() -> NamedPreset? {
        loadNamed().first(where: { $0.isDefault })
    }

    private func ensureDir() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
