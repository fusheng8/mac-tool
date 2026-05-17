// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "mac-tool",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "mac-tool", targets: ["MacToolApp"]),
        .executable(name: "mac-tool-finder-sync", targets: ["MacToolFinderSync"])
    ],
    targets: [
        .target(
            name: "DDCBackend",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-fmodules"])
            ],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreDisplay"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "MacToolApp",
            dependencies: ["DDCBackend"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreSpotlight"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "MacToolFinderSync",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("FinderSync")
            ]
        )
    ]
)
