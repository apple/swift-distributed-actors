// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let targets: [PackageDescription.Target] = [
    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Samples

    .target(
        name: "SampleDiningPhilosophers",
        dependencies: ["DistributedActors"],
        path: "Sources/SampleDiningPhilosophers"
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
    .testTarget(
        name: "SampleGenActorsTests",
        dependencies: [
            "SampleGenActors",
            "DistributedActorsTestKit"
        ],
        path: "Tests/SampleGenActorsTests"
    ),

]

var dependencies: [Package.Dependency] = [
    // ~~~ parent ~~~
    .package(path: "../"),
    // ~~~ only for samples ~~~
    .package(url: "https://github.com/MrLotU/SwiftPrometheus", .branch("master")),
]

let package = Package(
    name: "swift-distributed-actors-samples",
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
