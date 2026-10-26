// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Sussu",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "Sussu",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")]
        ),
    ],
    // AVAudioEngine taps, CGEvent taps and WhisperKit predate strict concurrency.
    swiftLanguageModes: [.v5]
)
