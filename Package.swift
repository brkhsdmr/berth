// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Berth",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Berth", targets: ["Berth"])
    ],
    targets: [
        // Yalnızca geometri ve kurallar: AppKit yok, testi kolay, Windows sürümüne örnek.
        .target(name: "BerthCore", path: "Sources/BerthCore"),
        .executableTarget(
            name: "Berth",
            dependencies: ["BerthCore"],
            path: "Sources/Berth"
        ),
        .testTarget(
            name: "BerthCoreTests",
            dependencies: ["BerthCore"],
            path: "Tests/BerthCoreTests"
        )
    ]
)
