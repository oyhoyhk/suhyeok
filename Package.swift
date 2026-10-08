// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Terminal emulator view that hosts the agents' TUIs inside the app.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        // On-device inference for the Supertonic voice that reads replies aloud.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "AgentDeck",
            dependencies: ["SwiftTerm", "Supertonic"],
            path: "Sources/AgentDeck",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "Supertonic",
            dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")],
            path: "Sources/Supertonic"
        )
    ]
)
