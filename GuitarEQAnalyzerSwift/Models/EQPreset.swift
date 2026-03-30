import Foundation

struct EQPreset: Codable {
    let version: Int
    let gains: [Float]

    init(gains: [Float], version: Int = 1) {
        self.version = version
        self.gains = gains
    }
}
