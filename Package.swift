// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZeroByte",
    platforms: [.iOS(.v16), .macOS(.v13), .watchOS(.v9), .tvOS(.v16), .visionOS(.v1)],
    products: [
        .library(name: "ZeroByte", targets: ["ZeroByte"]),
        // APNs registrations and payloads, for apps that use Apple push.
        .library(name: "ZeroBytePush", targets: ["ZeroBytePush"]),
        // One keyed state both devices keep, synced as commits (timeline-v1.md).
        .library(name: "ZeroByteTimeline", targets: ["ZeroByteTimeline"]),
    ],
    targets: [
        .target(name: "ZeroByte"),
        .target(name: "ZeroBytePush", dependencies: ["ZeroByte"]),
        .target(name: "ZeroByteTimeline", dependencies: ["ZeroByte"]),
        .testTarget(
            name: "ZeroByteTests",
            dependencies: ["ZeroByte", "ZeroBytePush"],
            resources: [.copy("relay-v1.json")]
        ),
        .testTarget(
            name: "ZeroByteTimelineTests",
            dependencies: ["ZeroByte", "ZeroByteTimeline"],
            resources: [.copy("timeline.json")]
        ),
    ]
)
