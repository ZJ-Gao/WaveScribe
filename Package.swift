// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WaveScribe",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.9.1"),
        .package(url: "https://github.com/soniqo/speech-swift", revision: "a57702e6f523fa36ac5532d2bdc5f35f701a052c")
    ],
    targets: [
        .target(name: "CSherpaPunct", path: "Sources/CSherpaPunct"),
        .executableTarget(
            name: "WaveScribe",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit"), .product(name: "FluidAudio", package: "FluidAudio"),
                           .product(name: "Qwen3ASR", package: "speech-swift"), "CSherpaPunct"],
            path: "Sources/WaveScribe"
        )
    ]
)
