// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clamshell",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Clamshell", targets: ["Clamshell"]),
        .library(name: "ClamshellCore", targets: ["ClamshellCore"]),
    ],
    targets: [
        .target(name: "ClamshellCore"),
        .executableTarget(name: "Clamshell", dependencies: ["ClamshellCore"]),
        .testTarget(name: "ClamshellCoreTests", dependencies: ["ClamshellCore"]),
        .testTarget(
            name: "ClamshellUITests",
            dependencies: ["Clamshell", "ClamshellCore"],
            path: "Tests/ClamshellUITests"
        ),
    ]
)
