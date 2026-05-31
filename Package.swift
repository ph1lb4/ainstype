// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AinstypeApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.12.0"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "AinstypeApp",
            dependencies: ["WhisperKit", "TOMLKit"],
            path: "Sources/AinstypeApp"
        ),
        .testTarget(
            name: "AinstypeAppTests",
            dependencies: ["AinstypeApp"],
            path: "Tests/AinstypeAppTests"
        ),
    ]
)
