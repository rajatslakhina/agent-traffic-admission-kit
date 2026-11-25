// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentAdmission",
    // Only the platforms CI actually builds: macOS (swift test) and iOS (xcodebuild, generic Simulator).
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
