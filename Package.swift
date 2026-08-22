// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Planner",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PlannerCore", targets: ["PlannerCore"]),
        .executable(name: "planner", targets: ["PlannerCLI"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite"
        ),
        .target(
            name: "PlannerCore",
            dependencies: ["CSQLite"],
            linkerSettings: [
                .linkedFramework("EventKit"),
            ]
        ),
        .executableTarget(
            name: "PlannerCLI",
            dependencies: ["PlannerCore"]
        ),
        .testTarget(
            name: "PlannerCoreTests",
            dependencies: ["PlannerCore"]
        ),
    ]
)
