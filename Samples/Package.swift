// swift-tools-version:5.5
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

var targets: [PackageDescription.Target] = [
    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Samples

    .executableTarget(
        name: "SampleDiningPhilosophers",
        dependencies: [
            .product(name: "DistributedActors", package: "swift-distributed-actors"),
        ],
        path: "Sources/SampleDiningPhilosophers"
    ),
    .executableTarget(
        name: "SampleGenActorsDiningPhilosophers",
        dependencies: [
            .product(name: "DistributedActors", package: "swift-distributed-actors"),
        ],
        path: "Sources/SampleGenActorsDiningPhilosophers"
    ),
    .executableTarget(
        name: "SampleLetItCrash",
        dependencies: [
            .product(name: "DistributedActors", package: "swift-distributed-actors"),
        ],
        path: "Sources/SampleLetItCrash"
    ),
    .executableTarget(
        name: "SampleCluster",
        dependencies: [
            .product(name: "DistributedActors", package: "swift-distributed-actors"),
        ],
        path: "Sources/SampleCluster"
    ),
    .executableTarget(
        name: "SampleReceptionist",
        dependencies: [
            .product(name: "DistributedActors", package: "swift-distributed-actors"),
        ],
        path: "Sources/SampleReceptionist"
    ),
    .executableTarget(
        name: "SampleMetrics",
        dependencies: [
            .product(name: "DistributedActors", package: "swift-distributed-actors"),
            .product(name: "SwiftPrometheus", package: "SwiftPrometheus"),
        ],
        path: "Sources/SampleMetrics"
    ),
    .executableTarget(
        name: "SampleGenActors",
        dependencies: [
            .product(name: "DistributedActors", package: "swift-distributed-actors"),
        ],
        path: "Sources/SampleGenActors"
    ),

    /* --- tests --- */

    // no-tests placeholder project to not have `swift test` fail on Samples/
    .testTarget(
        name: "NoopTests",
        dependencies: [
            .product(name: "DistributedActorsTestKit", package: "swift-distributed-actors"),
        ],
        path: "Tests/NoopTests"
    ),
]

var dependencies: [Package.Dependency] = [
    // ~~~~~~~     parent       ~~~~~~~
    .package(name: "swift-distributed-actors", path: "../"),

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
