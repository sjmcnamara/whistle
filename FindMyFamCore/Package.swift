// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FindMyFamCore",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "FindMyFamCore",
            targets: ["FindMyFamCore"]
        )
    ],
    targets: [
        .target(
            name: "FindMyFamCore",
            path: "Sources/FindMyFamCore"
        ),
        .testTarget(
            name: "FindMyFamCoreTests",
            dependencies: ["FindMyFamCore"],
            path: "Tests/FindMyFamCoreTests"
        )
    ]
)
