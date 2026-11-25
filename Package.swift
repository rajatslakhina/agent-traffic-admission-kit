// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentAdmission",
    // Minimum Apple platforms, both built in CI (macOS swift test, iOS generic-Simulator xcodebuild).
    // Linux needs no declaration and is built and tested in CI too.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AgentAdmission", targets: ["AgentAdmission"])
    ],
    targets: [
        .target(name: "AgentAdmission"),
        .testTarget(name: "AgentAdmissionTests", dependencies: ["AgentAdmission"])
    ],
    swiftLanguageModes: [.v6]
)
