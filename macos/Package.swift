// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VibestickMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "VibestickMacCore", targets: ["VibestickMacCore"]),
        .executable(name: "vibestickctl", targets: ["vibestickctl"]),
        .executable(name: "VibestickHelper", targets: ["VibestickHelper"]),
        .executable(name: "VibestickApp", targets: ["VibestickApp"])
    ],
    targets: [
        .target(
            name: "VibestickMacCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices")
            ]),
        .executableTarget(
            name: "vibestickctl",
            dependencies: ["VibestickMacCore"]),
        .executableTarget(
            name: "VibestickHelper",
            dependencies: ["VibestickMacCore"]),
        .executableTarget(
            name: "VibestickApp",
            dependencies: ["VibestickMacCore"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]),
        .testTarget(
            name: "VibestickMacCoreTests",
            dependencies: ["VibestickMacCore"])
    ]
)
