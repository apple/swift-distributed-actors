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
    // Example app showcasing the use of CRDTs to build a distributed "leader board" and "high score" system
    .target(
        name: "SampleDistributedCRDTLeaderboard",
        dependencies: ["DistributedActors"],
        path: "Sources/SampleDistributedCRDTLeaderboard"
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
    .target(
        name: "SampleGenActorsDiningPhilosophers",
        dependencies: [
            "DistributedActors"
        ],
        path: "Sources/SampleGenActorsDiningPhilosophers"
    ),

    /* --- tests --- */
    
    // no-tests placeholder project to not have `swift test` fail on Samples/
    .testTarget(
        name: "NoopTests",
        dependencies: [
            "DistributedActorsTestKit"
        ],
        path: "Tests/NoopTests"
    ),
]

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)

// ==== ------------------------------------------------------------------------------------------------------------
// MARK: XPCActorable Examples (only available on Apple platforms)

targets.append(contentsOf: [
    .target(
        name: "XPCActorServiceAPI",
        dependencies: [
            "DistributedActorsXPC"
        ],
        path: "Sources/XPCActorServiceAPI"
    ),
    .target(
        name: "XPCActorServiceProvider",
        dependencies: [
            "XPCActorServiceAPI",
        ],
        path: "Sources/XPCActorServiceProvider"
    ),
    .target(
        name: "XPCActorCaller", // this is "main"
        dependencies: [
            "XPCActorServiceAPI",
            "Files",
        ],
        path: "Sources/XPCActorCaller"
    ),
])

#endif

var dependencies: [Package.Dependency] = [
    // ~~~~~~~     parent       ~~~~~~~
    .package(path: "../"),

    // ~~~~~~~ only for samples ~~~~~~~

    // for metrics examples:
    .package(url: "https://github.com/MrLotU/SwiftPrometheus", .branch("master")),

    // for mocking logging via files in XPC examples
    .package(url: "https://github.com/JohnSundell/Files", from: "4.0.0"), // MIT license
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
