// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacroPadStudioMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MacroPadCore", targets: ["MacroPadCore"]),
        .executable(name: "macropad-probe", targets: ["MacroPadProbe"]),
        .executable(name: "macropad-status-hook", targets: ["MacroPadStatusHook"]),
        .executable(name: "MacroPadStudioMac", targets: ["MacroPadStudioMac"])
    ],
    targets: [
        .target(
            name: "CHIDBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "MacroPadCore",
            dependencies: ["CHIDBridge"]
        ),
        .executableTarget(
            name: "MacroPadProbe",
            dependencies: ["MacroPadCore"]
        ),
        .executableTarget(
            name: "MacroPadStatusHook"
        ),
        .executableTarget(
            name: "MacroPadStudioMac",
            dependencies: ["MacroPadCore"]
        ),
        .testTarget(
            name: "MacroPadCoreTests",
            dependencies: ["MacroPadCore"]
        )
    ]
)
