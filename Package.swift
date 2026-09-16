// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sdocker",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "sdocker", targets: ["SDocker"]),
    ],
    targets: [
        .executableTarget(
            name: "SDocker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
