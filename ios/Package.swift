// SwiftPM package for host UI development.
// Full slice requires linking static libs from cmake (orca_ios_api + libslic3r + deps).
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OrcaSlicerIOS",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "OrcaSlicerAppCore", targets: ["OrcaSlicerAppCore"]),
    ],
    targets: [
        .target(
            name: "OrcaSlicerAppCore",
            path: "OrcaSlicerApp",
            exclude: ["Info.plist", "Bridging-Header.h", "OrcaSlicerApp.swift"],
            sources: ["OrcaEngine.swift"]
        ),
    ]
)
