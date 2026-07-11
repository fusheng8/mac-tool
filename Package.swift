// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "mac-tool",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "mac-tool", targets: ["MacToolApp"]),
        .executable(name: "mac-tool-finder-sync", targets: ["MacToolFinderSync"]),
        .library(name: "MacToolCore", targets: ["MacToolCore"]),
        .library(name: "MacToolBridge", targets: ["MacToolBridge"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.10.0")),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", .upToNextMajor(from: "2.9.0"))
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
        .target(
            name: "MacToolCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MacToolBridge",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MacToolApp",
            dependencies: [
                "DDCBackend",
                "MacToolCore",
                "MacToolBridge",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
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
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .executableTarget(
            name: "MacToolFinderSync",
            dependencies: ["MacToolBridge", "MacToolCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("FinderSync")
            ]
        ),
        .testTarget(
            name: "MacToolAppTests",
            dependencies: ["MacToolApp", "MacToolCore", "MacToolBridge"],
            resources: [.copy("Fixtures")]
        )
    ]
)
