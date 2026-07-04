// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SiftIOS",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "MessageFilterCore", targets: ["MessageFilterCore"]),
        .library(name: "SiftAppKit", targets: ["SiftAppKit"]),
        .library(name: "MessageFilterExtensionKit", targets: ["MessageFilterExtensionKit"]),
        .executable(name: "CoreSmokeTests", targets: ["CoreSmokeTests"])
    ],
    targets: [
        .target(name: "MessageFilterCore"),
        .target(name: "SiftAppKit", dependencies: ["MessageFilterCore"]),
        .target(name: "MessageFilterExtensionKit", dependencies: ["MessageFilterCore"]),
        .executableTarget(
            name: "CoreSmokeTests",
            dependencies: ["MessageFilterCore"],
            path: "Tools/CoreSmokeTests"
        ),
        .testTarget(name: "MessageFilterCoreTests", dependencies: ["MessageFilterCore", "MessageFilterExtensionKit"]),
        .testTarget(name: "SiftAppKitTests", dependencies: ["SiftAppKit", "MessageFilterCore"])
    ]
)
