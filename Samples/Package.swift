// swift-tools-version:5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

var globalSwiftSettings: [SwiftSetting]

var globalConcurrencyFlags: [String] = [
    "-Xfrontend", "-disable-availability-checking", // TODO(distributed): remove this flag
]

globalSwiftSettings = [
    SwiftSetting.unsafeFlags(globalConcurrencyFlags),
]

var targets: [PackageDescription.Target] = [
    // ==== ----------------------------------------------------------------------------------------------------------------
    // MARK: Samples

    .executableTarget(
        name: "SampleDiningPhilosophers",
        dependencies: [
            .product(name: "DistributedCluster", package: "swift-distributed-actors"),
            "_PrettyLogHandler",
        ],
        path: "Sources/SampleDiningPhilosophers",
        exclude: [
            "dining-philosopher-fsm.graffle",
            "dining-philosopher-fsm.svg",
        ]
    ),

    .executableTarget(
        name: "SampleClusterTracing",
        dependencies: [
            .product(name: "DistributedCluster", package: "swift-distributed-actors"),
            .product(name: "OpenTelemetry", package: "opentelemetry-swift"),
            .product(name: "OtlpGRPCSpanExporting", package: "opentelemetry-swift"),
            "_PrettyLogHandler",
        ],
        path: "Sources/SampleClusterTracing"
    ),

    .target(
        name: "_PrettyLogHandler",
        dependencies: [
            .product(name: "DistributedCluster", package: "swift-distributed-actors"),
        ]
    ),

    /* --- tests --- */

    // no-tests placeholder project to not have `swift test` fail on Samples/
    .testTarget(
        name: "NoopTests",
        dependencies: [
        ],
        path: "Tests/NoopTests"
    ),
]

var dependencies: [Package.Dependency] = [
    // ~~~~~~~     parent       ~~~~~~~
    .package(name: "swift-distributed-actors", path: "../"),

    // ~~~~~~~ only for samples ~~~~~~~
    .package(url: "https://github.com/slashmo/opentelemetry-swift", from: "0.3.0"),
]

let package = Package(
    name: "swift-distributed-actors-samples",
    platforms: [
        // we require the 'distributed actor' language and runtime feature:
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        /* ---  samples --- */
        .executable(
            name: "SampleDiningPhilosophers",
            targets: ["SampleDiningPhilosophers"]
        ),
        .executable(
            name: "SampleClusterTracing",
            targets: ["SampleClusterTracing"]
        ),
    ],

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
