// swift-tools-version:5.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import class Foundation.ProcessInfo
import PackageDescription

// Workaround: Since we cannot include the flat just as command line options since then it applies to all targets,
// and ONE of our dependencies currently produces one warning, we have to use this workaround to enable it in _our_
// targets when the flag is set. We should remove the dependencies and then enable the flag globally though just by passing it.
// TODO: Follow up to https://github.com/apple/swift-distributed-actors/issues/23 by removing Files and Stencil, then we can remove this workaround
let globalSwiftSettings: [SwiftSetting]
if ProcessInfo.processInfo.environment["SACT_WARNINGS_AS_ERRORS"] != nil {
    print("SACT_WARNINGS_AS_ERRORS enabled, passing `-warnings-as-errors`")
    globalSwiftSettings = [
        SwiftSetting.unsafeFlags(["-warnings-as-errors"]),
    ]
} else {
    globalSwiftSettings = []
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
            .product(name: "SwiftProtobuf", package: "SwiftProtobuf"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "Metrics", package: "swift-metrics"),
            .product(name: "Backtrace", package: "swift-backtrace"),
        ]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: GenActors

    .target(
        name: "GenActors",
        dependencies: [
            "DistributedActors",
            .product(name: "SwiftSyntax", package: "SwiftSyntax"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),

            .product(name: "Stencil", package: "Stencil"), // TODO: remove this dependency
            .product(name: "Files", package: "Files"), // TODO: remove this dependency
        ]
    ),


    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Plugins

    .target(
         name: "ActorSingletonPlugin",
         dependencies: ["DistributedActors"]
     ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: XPC

    .target(
        name: "CDistributedActorsXPC",
        dependencies: []
    ),
    .target(
        name: "DistributedActorsXPC",
        dependencies: [
            "DistributedActors",
            "CDistributedActorsXPC",
            .product(name: "Files", package: "Files"),
        ]
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
            "DistributedActorsXPC",
            "ActorSingletonPlugin",
            "DistributedActorsTestKit",
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
        name: "GenActorsTests",
        dependencies: [
            "GenActors",
            "DistributedActorsTestKit",
        ]
    ),

    .testTarget(
        name: "ActorSingletonPluginTests",
        dependencies: ["ActorSingletonPlugin", "DistributedActorsTestKit"]
    ),

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Integration Tests - `it_` prefixed

    .target(
        name: "it_ProcessIsolated_escalatingWorkers",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_02_process_isolated/it_ProcessIsolated_escalatingWorkers"
    ),
    .target(
        name: "it_ProcessIsolated_respawnsServants",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_02_process_isolated/it_ProcessIsolated_respawnsServants"
    ),
    .target(
        name: "it_ProcessIsolated_noLeaking",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_02_process_isolated/it_ProcessIsolated_noLeaking"
    ),
    .target(
        name: "it_ProcessIsolated_backoffRespawn",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_02_process_isolated/it_ProcessIsolated_backoffRespawn"
    ),
    .target(
        name: "it_Clustered_swim_suspension_reachability",
        dependencies: [
            "DistributedActors",
        ],
        path: "IntegrationTests/tests_04_cluster/it_Clustered_swim_suspension_reachability"
    ),

    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Performance / Benchmarks

    .target(
        name: "DistributedActorsBenchmarks",
        dependencies: [
            "DistributedActors",
            "SwiftBenchmarkTools",
        ]
    ),
    .target(
        name: "SwiftBenchmarkTools",
        dependencies: ["DistributedActors"]
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
        dependencies: []
    ),

    .target(
        name: "DistributedActorsConcurrencyHelpers",
        dependencies: ["CDistributedActorsAtomics"]
    ),
]

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
targets.append(
    contentsOf: [
        /* --- XPC Integration Tests --- */
        .target(
            name: "it_XPCActorable_echo",
            dependencies: [
                "DistributedActorsXPC",
                "it_XPCActorable_echo_api",
            ],
            path: "IntegrationTests/disabled_tests_03_xpc_actorable/it_XPCActorable_echo"
        ),
        .target(
            name: "it_XPCActorable_echo_api",
            dependencies: [
                "DistributedActorsXPC",
            ],
            path: "IntegrationTests/disabled_tests_03_xpc_actorable/it_XPCActorable_echo_api"
        ),
        .target(
            name: "it_XPCActorable_echo_service",
            dependencies: [
                "DistributedActorsXPC",
                "it_XPCActorable_echo_api",
                "Files",
            ],
            path: "IntegrationTests/disabled_tests_03_xpc_actorable/it_XPCActorable_echo_service"
        ),
    ]
)
#endif

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-cluster-membership.git", from: "0.2.0"),

    .package(url: "https://github.com/apple/swift-nio.git", from: "2.12.0"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.2.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.2.0"),

    .package(name: "SwiftProtobuf", url: "https://github.com/apple/swift-protobuf.git", from: "1.7.0"),

    // ~~~ workaround for backtraces ~~~
    .package(url: "https://github.com/swift-server/swift-backtrace.git", from: "1.1.1"),

    // ~~~ SSWG APIs ~~~

    .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    // swift-metrics 1.x and 2.x are almost API compatible, so most clients should use
    .package(url: "https://github.com/apple/swift-metrics.git", "1.0.0" ..< "3.0.0"),

    // ~~~ only for GenActors ~~~
    // swift-syntax is Swift version dependent, and added  as such below
    .package(url: "https://github.com/stencilproject/Stencil.git", from: "0.13.1"), // BSD license
    .package(url: "https://github.com/JohnSundell/Files", from: "4.1.0"), // MIT license
    .package(url: "https://github.com/apple/swift-argument-parser", .exact("0.0.6")), // not API stable, Apache v2
]

#if swift(>=5.3)
dependencies.append(
    .package(name: "SwiftSyntax", url: "https://github.com/apple/swift-syntax.git", .exact("0.50300.0"))
)
#elseif swift(>=5.2)
dependencies.append(
    .package(name: "SwiftSyntax", url: "https://github.com/apple/swift-syntax.git", .exact("0.50200.0"))
)
#else
fatalError("Currently only Swift 5.2+ is supported, if you need earlier Swift support please reach out to to the team.")
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

    /* --- GenActors --- */

    .executable(
        name: "GenActors",
        targets: ["GenActors"]
    ),

    /* --- Plugins --- */

    .library(
        name: "ActorSingletonPlugin",
        targets: ["ActorSingletonPlugin"]
    ),

    /* --- XPC --- */
    .library(
        name: "DistributedActorsXPC",
        targets: ["DistributedActorsXPC"]
    ),

    /* ---  performance --- */
    .executable(
        name: "DistributedActorsBenchmarks",
        targets: ["DistributedActorsBenchmarks"]
    ),
]

var package = Package(
    name: "swift-distributed-actors",
    products: products,

    dependencies: dependencies,

    targets: targets.map { target in
        var swiftSettings = target.swiftSettings ?? []
        swiftSettings.append(contentsOf: globalSwiftSettings)
        if !swiftSettings.isEmpty {
            target.swiftSettings = swiftSettings
        }
        return target
    },

    cxxLanguageStandard: .cxx11
)
