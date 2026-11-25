// swift-tools-version: 6.0
//
// Matiné's logic lives here so it builds and tests on the Mac in seconds
// (`swift test`). The tvOS app in Apps/Matine is a thin shell of views over
// MatineKit. No third-party dependencies: see THIRD_PARTY.md before adding one.

import PackageDescription

let package = Package(
    name: "matine",
    platforms: [
        .macOS("26.0"),
        .tvOS("27.0"),
        .iOS("27.0"),
    ],
    products: [
        .library(name: "MatineKit", targets: ["MatineKit"]),
        .executable(name: "matine", targets: ["MatineCLI"]),
    ],
    targets: [
        .target(name: "MatineKit"),
        .executableTarget(name: "MatineCLI", dependencies: ["MatineKit"]),
        .testTarget(
            name: "MatineKitTests",
            dependencies: ["MatineKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
