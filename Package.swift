// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZoomCheck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ZoomCheck",
            path: "Sources/ZoomCheck",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
