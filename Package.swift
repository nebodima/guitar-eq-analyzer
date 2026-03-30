// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GuitarEQAnalyzerSwift",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "GuitarEQAnalyzerSwift",
            targets: ["GuitarEQAnalyzerSwift"]
        )
    ],
    targets: [
        .executableTarget(
            name: "GuitarEQAnalyzerSwift",
            path: "GuitarEQAnalyzerSwift"
        )
    ]
)
