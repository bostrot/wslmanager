// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "vmctl",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "VMCtlKit",
            path: "Sources/VMCtlKit"
        ),
        .executableTarget(
            name: "vmctl",
            dependencies: ["VMCtlKit"],
            path: "Sources/vmctl"
        ),
        .testTarget(
            name: "VMCtlKitTests",
            dependencies: ["VMCtlKit"],
            path: "Tests/VMCtlKitTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
