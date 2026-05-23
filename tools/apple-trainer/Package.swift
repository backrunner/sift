// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SiftAppleTrainer",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "SiftAppleTrainer", targets: ["SiftAppleTrainer"])
    ],
    targets: [
        .executableTarget(name: "SiftAppleTrainer")
    ]
)
