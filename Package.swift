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
        .target(
            name: "CZstd",
            path: "Sources/CZstd",
            exclude: ["LICENSE", "UPSTREAM.md"],
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "CodexNotch",
            dependencies: ["CZstd"],
            path: "Sources/CodexNotch",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CodexNotchTests",
            dependencies: ["CodexNotch"],
            path: "Tests/CodexNotchTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
