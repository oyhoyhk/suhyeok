// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Terminal emulator view that hosts the agents' TUIs inside the app.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "AgentDeck",
            dependencies: ["SwiftTerm"],
            path: "Sources/AgentDeck",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
