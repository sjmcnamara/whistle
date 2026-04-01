// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhistleCore",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "WhistleCore",
            targets: ["WhistleCore"]
        )
    ],
    targets: [
        .target(
            name: "WhistleCore",
            path: "Sources/WhistleCore"
        ),
        .testTarget(
            name: "WhistleCoreTests",
            dependencies: ["WhistleCore"],
            path: "Tests/WhistleCoreTests"
        )
    ]
)
