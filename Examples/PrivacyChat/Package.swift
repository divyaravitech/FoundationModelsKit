// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrivacyChat",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "PrivacyChat",
            dependencies: [
                .product(name: "FoundationModelsKit", package: "FoundationModelsKit")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
