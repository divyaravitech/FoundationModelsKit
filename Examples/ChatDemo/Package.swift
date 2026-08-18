// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChatDemo",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "ChatDemo",
            dependencies: [
                .product(name: "FoundationModelsKit", package: "FoundationModelsKit")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
