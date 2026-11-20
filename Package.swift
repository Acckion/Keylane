// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Keylane",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Keylane", targets: ["Keylane"]),
        .executable(name: "keylane-extension", targets: ["KeylaneExtensionCLI"]),
        .executable(name: "KeylaneStoreGuest", targets: ["KeylaneStoreGuest"]),
        .executable(name: "keylane-store-lifecycle-fixture", targets: ["KeylaneStoreLifecycleFixture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
    targets: [
        .target(name: "KeylaneCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "KeylaneProviderConfig", dependencies: [.product(name: "Yams", package: "Yams")]),
        .executableTarget(name: "Keylane", dependencies: ["KeylaneCore", "KeylaneProviderConfig"]),
        .executableTarget(name: "KeylaneExtensionCLI", dependencies: ["KeylaneCore"]),
        .executableTarget(name: "KeylaneStoreGuest", dependencies: ["KeylaneCore"]),
        .executableTarget(name: "KeylaneStoreLifecycleFixture", dependencies: ["KeylaneCore"], path: "Tests/ExtensionPrototype/StoreLifecycleFixture"),
        .testTarget(name: "KeylaneCoreTests", dependencies: ["KeylaneCore"]),
        .testTarget(name: "KeylaneProviderConfigTests", dependencies: ["KeylaneProviderConfig"]),
    ],
    swiftLanguageModes: [.v5]
)
