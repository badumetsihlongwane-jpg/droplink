// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "DropLink",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "DropLinkCore", targets: ["DropLinkCore"]),
        .executable(name: "DropLink", targets: ["DropLinkApp"]),
        .executable(name: "DropLinkTests", targets: ["DropLinkTests"])
    ],
    targets: [
        .target(
            name: "DropLinkCore",
            path: "Sources/DropLinkCore"
        ),
        .executableTarget(
            name: "DropLinkApp",
            dependencies: ["DropLinkCore"],
            path: "Sources/DropLinkApp"
        ),
        .executableTarget(
            name: "DropLinkTests",
            dependencies: ["DropLinkCore"],
            path: "Sources/DropLinkTests"
        )
    ]
)
