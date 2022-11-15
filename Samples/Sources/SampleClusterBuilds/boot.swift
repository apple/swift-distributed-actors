//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import _PrettyLogHandler
import Distributed
import DistributedCluster
import Logging
import NIO
import OpenTelemetry
import OtlpGRPCSpanExporting
import Tracing

@main
enum Main {

    enum Config {
        // "seed" node that all others will join (and learn about other nodes in the cluster automatically)
        static let seedEndpoint = Cluster.Endpoint(host: "127.0.0.1", port: 7330) // just a convention, leader can be decided in various ways

        // How many workers per node
        static let workersPerNode = 2
        // How many tasks should the leader try to process, scaling out computation to workers.
        static let totalBuildTasks = 100
    }

    static func main() async throws {
        print("===---------------------------------------------------------===")
        print("|            Sample Cluster Builds                            |")
        print("|                                                             |")
        print("| USAGE:                                                      |")
        print("|        swift run SampleClusterBuilds 7330 (becomes leader)  |")
        print("|        swift run SampleClusterBuilds 7331 worker            |")
        print("|        swift run SampleClusterBuilds ...  worker            |")
        print("===---------------------------------------------------------===")

        let port = Int(CommandLine.arguments.dropFirst().first ?? "7330")!
        let role: ClusterNodeRole
        if port == 7330 {
            role = .leader
        } else if CommandLine.arguments.dropFirst(2).first == "worker" {
            role = .worker
        } else {
            fatalError("Undefined role for node: \(port)! Available roles: \(ClusterNodeRole.allCases)")
        }
        let nodeName = "ClusterBuilds-\(port)-\(role)"

        // Bootstrap logging:
        LoggingSystem.bootstrap(SamplePrettyLogHandler.init)

        // Bootstrap OpenTelemetry tracing:
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let exporter = OtlpGRPCSpanExporter(config: OtlpGRPCSpanExporter.Config(eventLoopGroup: group))
        let processor = OTel.SimpleSpanProcessor(exportingTo: exporter)

        let otel = OTel(serviceName: nodeName, eventLoopGroup: group, processor: processor)
        InstrumentationSystem.bootstrap(otel.tracer())


        var app = await ClusterBuilds(name: nodeName, port: port)
        try! await app.run(tasks: Main.Config.totalBuildTasks)

        try await app.system.terminated
    }
}

enum ClusterNodeRole: CaseIterable, Hashable {
    case leader
    case worker
}
