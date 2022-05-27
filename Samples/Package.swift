// swift-tools-version:5.6
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
            .product(name: "DistributedActors", package: "swift-distributed-actors"),
        ],
        path: "Sources/SampleDiningPhilosophers",
        exclude: [
            "dining-philosopher-fsm.graffle",
            "dining-philosopher-fsm.svg",
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
]

let package = Package(
    name: "swift-distributed-actors-samples",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v8),
        // ...
    ],
    products: [
        /* ---  samples --- */

        .executable(
            name: "SampleDiningPhilosophers",
            targets: ["SampleDiningPhilosophers"]
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
