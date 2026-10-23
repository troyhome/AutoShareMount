// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoShareMount",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AutoShareMount",
            path: "Sources/AutoShareMount",
            linkerSettings: [
                .linkedFramework("NetFS"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
