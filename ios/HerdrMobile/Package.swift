// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HerdrMobileCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v14),
    ],
    products: [
        .library(name: "HerdrMobileCore", targets: ["HerdrMobileCore"]),
    ],
    targets: [
        .target(
            name: "HerdrMobileCore",
            path: "HerdrMobile/Core"
        ),
        .executableTarget(
            name: "HerdrMobileCoreTests",
            dependencies: ["HerdrMobileCore"],
            path: "Tests/HerdrMobileCoreTests"
        ),
    ]
)
