// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let targets: [PackageDescription.Target] = [
    .target(
        name: "DistributedActors",
        dependencies: [
            "NIO",
            "NIOExtras",
            "NIOFoundationCompat",
            "NIOSSL",
            "Logging",
            "ConcurrencyHelpers",
            "CDistributedActorsMailbox",
            "CDistributedActorsRunQueue",
            "SwiftProtobuf"
        ]
    ),

    /// This target is intended only for use in tests, though we have no way to mark this
    .target(
        name: "ActorsTestKit",
        dependencies: ["DistributedActors", "ConcurrencyHelpers"]
    ),

    .target(
        name: "CDistributedActorsMailbox",
        dependencies: []
    ),

    .target(
        name: "CDistributedActorsRunQueue",
        dependencies: []
    ),

    // NOT SUPPORTED transient library until Swift receives Atomics
    .target(name: "CDistributedActorsAtomics",
        dependencies: []
    ),

    // NOT SUPPORTED transient library until Swift receives Atomics
    .target(
        name: "ConcurrencyHelpers",
        dependencies: ["CDistributedActorsAtomics"]
    ),

    /* test targets */

    .testTarget(
        name: "SwiftDistributedActorsActorTests",
        dependencies: ["DistributedActors", "ActorsTestKit"]
    ),
    .testTarget(
        name: "ActorsTestKitTests",
        dependencies: ["DistributedActors", "ActorsTestKit"]
    ),

    .testTarget(
        name: "CDistributedActorsMailboxTests",
        dependencies: ["CDistributedActorsMailbox", "ActorsTestKit"]
    ),

    .testTarget(
        name: "ConcurrencyHelpersTests",
        dependencies: ["ConcurrencyHelpers"]
    ),

    /* --- performance --- */
    
    .target(
        name: "ActorsBenchmarks",
        dependencies: [
            "DistributedActors",
            "SwiftBenchmarkTools"
        ]
    ),
    .target(
        name: "SwiftBenchmarkTools",
        dependencies: ["DistributedActors"]
    ),

    /* --- samples --- */
    .target(
        name: "ActorsSampleDiningPhilosophers",
        dependencies: ["DistributedActors"]
    ),
    .target(
        name: "ActorsSampleLetItCrash",
        dependencies: ["DistributedActors"]
    ),
    .target(
        name: "ActorsSampleCluster",
        dependencies: ["DistributedActors"]
    ),
    .target(
        name: "SwiftDistributedActorsSampleProcessIsolated",
        dependencies: [
            "DistributedActors"
        ]
    ),

    /* --- documentation snippets --- */
    .testTarget(
        name: "ActorsDocumentationTests",
        dependencies: ["DistributedActors", "DistributedActorsTestKit"]
    )
]

let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git",        from: "2.7.0"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git",    from: "2.2.0"),
    .package(url: "https://github.com/apple/swift-protobuf.git",   from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-log.git",        from: "1.0.0"),
]

let package = Package(
    name: "DistributedActors",
    products: [
        .library(
            name: "DistributedActors",
            targets: ["DistributedActors"]
        ),
        .library(
            name: "DistributedActorsTestKit",
            targets: ["DistributedActorsTestKit"]
        ),
        .library(
            name: "CDistributedActorsMailbox",
            targets: ["CDistributedActorsMailbox"]
        ),
        .library(
            name: "CDistributedActorsRunQueue",
            targets: ["CDistributedActorsRunQueue"]
        ),
        .library(
            name: "CDistributedActorsAtomics",
            targets: ["CDistributedActorsAtomics"]
        ),
        .library(
            name: "ConcurrencyHelpers",
            targets: ["ConcurrencyHelpers"]
        ),

        /* ---  performance --- */
        .executable(
            name: "ActorsBenchmarks",
            targets: ["ActorsBenchmarks"]
        ),

        /* ---  samples --- */

        .executable(
            name: "ActorsSampleDiningPhilosophers",
            targets: ["ActorsSampleDiningPhilosophers"]
        ),
        .executable(
            name: "ActorsSampleLetItCrash",
            targets: ["ActorsSampleLetItCrash"]
        ),
        .executable(
            name: "ActorsSampleCluster",
            targets: ["ActorsSampleCluster"]
        ),
    ],

    dependencies: dependencies,

    targets: targets,

    cxxLanguageStandard: .cxx11
)

