import Foundation

struct EQPreset: Codable {
    let version: Int
    let gains: [Float]
    init(gains: [Float], version: Int = 1) {
        self.version = version
        self.gains   = gains
    }
}

struct NamedPreset: Codable, Identifiable {
    var id:    UUID
    var name:  String
    var gains: [Float]
    var date:  Date

    init(name: String, gains: [Float]) {
        self.id    = UUID()
        self.name  = name
        self.gains = gains
        self.date  = Date()
    }
}
