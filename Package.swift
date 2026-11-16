// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Keylane",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Keylane", targets: ["Keylane"]),
        .executable(name: "keylane-extension", targets: ["KeylaneExtensionCLI"]),
    ],
    targets: [
        .target(name: "KeylaneCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Keylane", dependencies: ["KeylaneCore"]),
        .executableTarget(name: "KeylaneExtensionCLI", dependencies: ["KeylaneCore"]),
        .testTarget(name: "KeylaneCoreTests", dependencies: ["KeylaneCore"]),
    ],
    swiftLanguageModes: [.v5]
)
