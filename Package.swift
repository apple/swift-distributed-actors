// swift-tools-version:5.6
// The swift-tools-version declares the minimum version of Swift required to build this package.

import class Foundation.ProcessInfo
import PackageDescription

// Workaround: Since we cannot include the flat just as command line options since then it applies to all targets,
// and ONE of our dependencies currently produces one warning, we have to use this workaround to enable it in _our_
// targets when the flag is set. We should remove the dependencies and then enable the flag globally though just by passing it.
// TODO: Follow up to https://github.com/apple/swift-distributed-actors/issues/23 by removing Files and Stencil, then we can remove this workaround
var globalSwiftSettings: [SwiftSetting]

var globalConcurrencyFlags: [String] = [
    "-Xfrontend", "-enable-experimental-distributed",
    "-Xfrontend", "-disable-availability-checking", // FIXME: must remove this
]

if ProcessInfo.processInfo.environment["SACT_WARNINGS_AS_ERRORS"] != nil {
    print("SACT_WARNINGS_AS_ERRORS enabled, passing `-warnings-as-errors`")
    var allUnsafeFlags = globalConcurrencyFlags
    allUnsafeFlags.append(contentsOf: [
        "-warnings-as-errors",
    ])
    globalSwiftSettings = [
        SwiftSetting.unsafeFlags(allUnsafeFlags),
    ]
} else {
    globalSwiftSettings = [
        SwiftSetting.unsafeFlags(globalConcurrencyFlags),
    ]
}

var targets: [PackageDescription.Target] = [
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Actors

    .target(
        name: "DistributedActors",
        dependencies: [
            "DistributedActorsConcurrencyHelpers",
            "CDistributedActorsMailbox",
            .product(name: "SWIM", package: "swift-cluster-membership"),
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOFoundationCompat", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOExtras", package: "swift-nio-extras"),
            .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "Metrics", package: "swift-metrics"),
            .product(name: "ServiceDiscovery", package: "swift-service-discovery"),
            .product(name: "Backtrace", package: "swift-backtrace"),
        ]
//        ,
//        plugins: ["DistributedActorsGeneratorPlugin"]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: SwiftPM Plugin: Distributed Actors Generator

    .executableTarget(
        name: "DistributedActorsGenerator",
        dependencies: [
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),

    .plugin(
        name: "DistributedActorsGeneratorPlugin",
        capability: .buildTool(),
        dependencies: ["DistributedActorsGenerator"],
        path: "Sources/DistributedActorsGeneratorPlugin"
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Plugins // TODO: rename since may be confused with package plugins?

    .target(
        name: "ActorSingletonPlugin",
        dependencies: ["DistributedActors"]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: TestKit

    /// This target is intended only for use in tests, though we have no way to mark this
    .target(
        name: "DistributedActorsTestKit",
        dependencies: ["DistributedActors", "DistributedActorsConcurrencyHelpers"]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Documentation

    .testTarget(
        name: "DistributedActorsDocumentationTests",
        dependencies: [
            "DistributedActors",
            "ActorSingletonPlugin",
            "DistributedActorsTestKit",
        ],
        exclude: [
          "DocumentationProtos/",
        ]
    ),

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Tests

    .testTarget(
        name: "DistributedActorsTests",
        dependencies: ["DistributedActors", "DistributedActorsTestKit"]
    ),

    .testTarget(
        name: "DistributedActorsTestKitTests",
        dependencies: ["DistributedActors", "DistributedActorsTestKit"]
    ),

    .testTarget(
        name: "CDistributedActorsMailboxTests",
        dependencies: ["CDistributedActorsMailbox", "DistributedActorsTestKit"]
    ),

    .testTarget(
        name: "DistributedActorsConcurrencyHelpersTests",
        dependencies: ["DistributedActorsConcurrencyHelpers"]
    ),

    .testTarget(
        name: "DistributedActorsGeneratorTests",
        dependencies: [
            "DistributedActorsGenerator",
            "DistributedActorsTestKit",
        ],
        plugins: ["DistributedActorsGeneratorPlugin"]
    ),

    .testTarget(
        name: "ActorSingletonPluginTests",
        dependencies: ["ActorSingletonPlugin", "DistributedActorsTestKit"]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------

    .executableTarget(
        name: "Playground",
        dependencies: [
          "DistributedActors",
        ],
        plugins: ["DistributedActorsGeneratorPlugin"]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Integration Tests - `it_` prefixed

    .executableTarget(
        name: "it_ProcessIsolated_escalatingWorkers",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_02_process_isolated/it_ProcessIsolated_escalatingWorkers"
    ),
    .executableTarget(
        name: "it_ProcessIsolated_respawnsServants",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_02_process_isolated/it_ProcessIsolated_respawnsServants"
    ),
    .executableTarget(
        name: "it_ProcessIsolated_noLeaking",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_02_process_isolated/it_ProcessIsolated_noLeaking"
    ),
    .executableTarget(
        name: "it_ProcessIsolated_backoffRespawn",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_02_process_isolated/it_ProcessIsolated_backoffRespawn"
    ),
    .executableTarget(
        name: "it_Clustered_swim_suspension_reachability",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_04_cluster/it_Clustered_swim_suspension_reachability"
    ),

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Performance / Benchmarks

    .executableTarget(
        name: "DistributedActorsBenchmarks",
        dependencies: [
            "DistributedActors",
            "SwiftBenchmarkTools",
        ],
        exclude: [
          "README.md",
          "BenchmarkProtos/bench.proto",
        ]
    ),
    .target(
        name: "SwiftBenchmarkTools",
        dependencies: ["DistributedActors"],
        exclude: [
          "README_SWIFT.md"
        ]
    ),

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Samples are defined in Samples/Package.swift
    // ==== ----------------------------------------------------------------------------------------------------------------

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Internals; NOT SUPPORTED IN ANY WAY

    .target(
        name: "CDistributedActorsMailbox",
        dependencies: []
    ),

    .target(
        name: "CDistributedActorsAtomics",
        dependencies: [],
        exclude: [
          "README.md"
        ]
    ),

    .target(
        name: "DistributedActorsConcurrencyHelpers",
        dependencies: ["CDistributedActorsAtomics"],
        exclude: [
          "README.md"
        ]
    ),
]

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-cluster-membership.git", from: "0.3.0"),

    .package(url: "https://github.com/apple/swift-nio.git", from: "2.12.0"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.16.1"),

    .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.7.0"),

//    .package(url: "https://github.com/apple/swift-atomics.git", from: "1.0.1"),

    // ~~~ backtraces ~~~
    .package(url: "https://github.com/swift-server/swift-backtrace.git", from: "1.1.1"),

    // ~~~ SSWG APIs ~~~

    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    // swift-metrics 1.x and 2.x are almost API compatible, so most clients should use
    .package(url: "https://github.com/apple/swift-metrics.git", "1.0.0" ..< "3.0.0"),
    .package(url: "https://github.com/apple/swift-service-discovery.git", from: "1.0.0"),
]

// ~~~ only for DistributedActorsGenerator ~~~
dependencies += [
    .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMinor(from: "0.3.2")), // not API stable, Apache v2
]

// swift-syntax is Swift version dependent, and added as such below
#if swift(>=5.6)
dependencies.append(
    .package(url: "https://github.com/apple/swift-syntax.git", revision: "swift-DEVELOPMENT-SNAPSHOT-2021-09-18-a")
//    .package(url: "https://github.com/apple/swift-syntax.git", branch: "main")
)
#else
fatalError("Only Swift 5.6+ is supported, because the dependency on the 'distributed actor' language feature")
#endif

let products: [PackageDescription.Product] = [
    .library(
        name: "DistributedActors",
        targets: ["DistributedActors"]
    ),
    .library(
        name: "DistributedActorsTestKit",
        targets: ["DistributedActorsTestKit"]
    ),

    /* --- Functional Plugins --- */

    .library(
        name: "ActorSingletonPlugin",
        targets: ["ActorSingletonPlugin"]
    ),

    /* --- SwiftPM Plugins --- */

    .plugin(
        name: "DistributedActorsGeneratorPlugin",
        targets: ["DistributedActorsGeneratorPlugin"]
    ),

    // code generation tool, used by the plugin
    .executable(
        name: "DistributedActorsGenerator",
        targets: ["DistributedActorsGenerator"]
    ),
]

var package = Package(
    name: "swift-distributed-actors",
    platforms: [
        .macOS(.v10_15), // because of the 'distributed actor' feature
        .iOS(.v8),
        // ...
    ],
    products: products,

    dependencies: dependencies,

    targets: targets.map { target in
        var swiftSettings = target.swiftSettings ?? []
        if target.type != .plugin {
            swiftSettings.append(contentsOf: globalSwiftSettings)
        }
        if !swiftSettings.isEmpty {
            target.swiftSettings = swiftSettings
        }
        return target
    },

    cxxLanguageStandard: .cxx11
)
