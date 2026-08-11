// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TimMethodCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "TimMethodCore", targets: ["TimMethodCore"]),
        .executable(name: "timmethod-eval", targets: ["timmethod-eval"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .target(
            name: "TimMethodCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "timmethod-eval",
            dependencies: [
                "TimMethodCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TimMethodCoreTests",
            dependencies: ["TimMethodCore", "timmethod-eval"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
