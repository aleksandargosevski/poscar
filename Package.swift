// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Poscar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Poscar",
            dependencies: [
                "PoscarCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Poscar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PoscarCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/PoscarCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PoscarCoreTests",
            dependencies: ["PoscarCore"],
            path: "Tests/PoscarCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
