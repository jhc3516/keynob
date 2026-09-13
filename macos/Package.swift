// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Keynob",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "KeynobCore", targets: ["KeynobCore"]),
        .executable(name: "keynob-probe", targets: ["KeynobProbe"]),
        .executable(name: "keynob-status-hook", targets: ["KeynobStatusHook"]),
        .executable(name: "Keynob", targets: ["Keynob"])
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
            name: "KeynobCore",
            dependencies: ["CHIDBridge"]
        ),
        .executableTarget(
            name: "KeynobProbe",
            dependencies: ["KeynobCore"]
        ),
        .executableTarget(
            name: "KeynobStatusHook"
        ),
        .executableTarget(
            name: "Keynob",
            dependencies: ["KeynobCore"]
        ),
        .testTarget(
            name: "KeynobCoreTests",
            dependencies: ["KeynobCore"]
        )
    ]
)
