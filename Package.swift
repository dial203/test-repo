// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HRVKit",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "HRVKit", targets: ["HRVKit"]),
        // Runs the agreement analysis on exported files, so a criterion comparison needs
        // no Xcode and no device — only the two CSVs.
        .executable(name: "hrv-agreement", targets: ["hrv-agreement"]),
    ],
    targets: [
        // Platform-agnostic analysis core. Deliberately has NO HealthKit dependency
        // so it compiles and runs its test suite on Linux/CI without a Mac.
        .target(
            name: "HRVKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "hrv-agreement",
            dependencies: ["HRVKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HRVKitTests",
            dependencies: ["HRVKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
