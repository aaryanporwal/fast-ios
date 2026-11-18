// swift-tools-version: 6.3
// The minimum toolchain: Swift 6.3 (Xcode 26.6), the oldest one CI compiles
// and tests on. An older Swift stops here with "requires a minimum Swift
// tools version of 6.3" instead of failing later in the code.
import PackageDescription

let package = Package(
    name: "fast-ios",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FastIOSCore", targets: ["FastIOSCore"]),
        .executable(name: "fast-ios", targets: ["fast-ios"]),
        .executable(name: "FastIOSBar", targets: ["FastIOSBar"]),
    ],
    targets: [
        .target(name: "FastIOSCore"),
        .executableTarget(name: "fast-ios", dependencies: ["FastIOSCore"]),
        .executableTarget(name: "FastIOSBar", dependencies: ["FastIOSCore"]),
        // fast-ios is a dependency so `swift test` builds the binary that
        // CLIHelpTests runs.
        .testTarget(name: "FastIOSCoreTests", dependencies: ["FastIOSCore", "fast-ios"],
                    path: "tests/FastIOSCoreTests", resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
