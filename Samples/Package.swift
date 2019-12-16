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

    /* --- xpc actorable examples */
    .target(
        name: "XPCActorServiceAPI",
        dependencies: [
            "XPCActorable"
        ],
        path: "Sources/XPCActorServiceAPI"
    ),
    .target(
        name: "XPCActorServiceProvider",
        dependencies: [
            "XPCActorServiceAPI",
            "XPCActorable",
            "LoggingOSLog",
        ],
        path: "Sources/XPCActorServiceProvider"
    ),
    .target(
        name: "XPCActorCaller", // this is "main"
        dependencies: [
            "XPCActorServiceAPI",
            "XPCActorable",
            "Files",
        ],
        path: "Sources/XPCActorCaller"
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
    // ~~~~~~~     parent       ~~~~~~~
    .package(path: "../"),

    // ~~~~~~~ only for samples ~~~~~~~

    // for metrics examples:
    .package(url: "https://github.com/MrLotU/SwiftPrometheus", .branch("master")),

    // for mocking logging via files in XPC examples
    .package(url: "https://github.com/JohnSundell/Files", from: "4.0.0"), // MIT license
    .package(url: "https://github.com/chrisaljoudi/swift-log-oslog.git", from: "0.1.0"), // TODO: waiting for license https://github.com/chrisaljoudi/swift-log-oslog/issues/4
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
