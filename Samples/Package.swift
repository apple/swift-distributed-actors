// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

var targets: [PackageDescription.Target] = [
    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Samples

    .target(
        name: "SampleDiningPhilosophers",
        dependencies: ["DistributedActors"],
        path: "Sources/SampleDiningPhilosophers"
    ),
    .target(
        name: "SampleGenActorsDiningPhilosophers",
        dependencies: [
            "DistributedActors",
        ],
        path: "Sources/SampleGenActorsDiningPhilosophers"
    ),
    .target(
        name: "SampleLetItCrash",
        dependencies: ["DistributedActors"],
        path: "Sources/SampleLetItCrash"
    ),
    .target(
        name: "SampleCluster",
        dependencies: ["DistributedActors"],
        path: "Sources/SampleCluster"
    ),
    .target(
        name: "SampleReceptionist",
        dependencies: ["DistributedActors"],
        path: "Sources/SampleReceptionist"
    ),
    .target(
        name: "SampleMetrics",
        dependencies: [
            "DistributedActors",
            "SwiftPrometheus",
        ],
        path: "Sources/SampleMetrics"
    ),
    .target(
        name: "SampleGenActors",
        dependencies: [
            "DistributedActors",
        ],
        path: "Sources/SampleGenActors"
    ),

    /* --- tests --- */

    // no-tests placeholder project to not have `swift test` fail on Samples/
    .testTarget(
        name: "NoopTests",
        dependencies: [
            "DistributedActorsTestKit",
        ],
        path: "Tests/NoopTests"
    ),
]

var dependencies: [Package.Dependency] = [
    // ~~~~~~~     parent       ~~~~~~~
    .package(path: "../"),

    // ~~~~~~~ only for samples ~~~~~~~

    // for metrics examples:
    .package(url: "https://github.com/MrLotU/SwiftPrometheus", from: "1.0.0-alpha.11"), // Apache v2 license
]

let package = Package(
    name: "swift-distributed-actors-samples",
    platforms: [
        .macOS(.v10_11), // TODO: workaround for rdar://76035286
        .iOS(.v8),
        // ...
    ],
    products: [
        /* ---  samples --- */

        .executable(
            name: "SampleDiningPhilosophers",
            targets: ["SampleDiningPhilosophers"]
        ),
        .executable(
            name: "SampleLetItCrash",
            targets: ["SampleLetItCrash"]
        ),
        .executable(
            name: "SampleCluster",
            targets: ["SampleCluster"]
        ),
        .executable(
            name: "SampleMetrics",
            targets: ["SampleMetrics"]
        ),
        .executable(
            name: "SampleGenActors",
            targets: ["SampleGenActors"]
        ),

    ],

    dependencies: dependencies,

    targets: targets,

    cxxLanguageStandard: .cxx11
)
