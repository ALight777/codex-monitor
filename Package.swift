// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexNotch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexNotch", targets: ["CodexNotch"])
    ],
    targets: [
        .executableTarget(
            name: "CodexNotch",
            path: "Sources/CodexNotch",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
