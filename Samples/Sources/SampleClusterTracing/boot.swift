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

/*
 * Sample showcasing a long traced interaction.
 */
@main enum Main {
    static func main() async throws {
        print("===-----------------------------------------------------===")
        print("|            Cluster Tracing Sample App                   |")
        print("|                                                         |")
        print("| USAGE:                                                  |")
        print("|        swift run SampleClusterTracing # leader          |")
        print("|        swift run SampleClusterTracing 7331 chopping     |")
        print("|        swift run SampleClusterTracing 7332 chopping     |")
        print("===-----------------------------------------------------===")

        let port = Int(CommandLine.arguments.dropFirst().first ?? "7330")!
        let role: ClusterNodeRole
        if port == 7330 {
            role = .leader
        } else if CommandLine.arguments.dropFirst(2).first == "chopping" {
            role = .chopping
        } else {
            fatalError("Undefined role for node: \(port)! Available roles: \(ClusterNodeRole.allCases)")
        }
        let nodeName = "SampleNode-\(port)-\(role)"

        // Bootstrap logging:
        LoggingSystem.bootstrap(SamplePrettyLogHandler.init)

        // Bootstrap OpenTelemetry tracing:
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let exporter = OtlpGRPCSpanExporter(config: OtlpGRPCSpanExporter.Config(eventLoopGroup: group))
        let processor = OTel.SimpleSpanProcessor(exportingTo: exporter)

        let otel = OTel(serviceName: nodeName, eventLoopGroup: group, processor: processor)
        InstrumentationSystem.bootstrap(otel.tracer())

        // Start the sample app node.
        // (All nodes attempt to join the leader at 7330, forming a cluster with it).
        let system: ClusterSystem

        if role == .leader {
            let node = await LeaderNode(name: nodeName, port: port)
            system = node.system
            try! await node.run()
        } else {
            var node = await ChoppingNode(name: nodeName, port: port)
            system = node.system
            try! await node.run()
        }

        try await system.terminated
    }
}

func monitorMembership(on system: ClusterSystem) {
    Task {
        for await event in system.cluster.events {
            system.log.debug("Membership change: \(event)")

            let membership = await system.cluster.membershipSnapshot
            if membership.members(withStatus: .down).count == membership.count {
                system.log.notice("Membership: \(membership.count)", metadata: [
                    "cluster/membership": Logger.MetadataValue.array(membership.members(atMost: .down).map {
                        "\($0)"
                    }),
                ])
            }
        }
    }
}

enum ClusterNodeRole: CaseIterable, Hashable {
    case leader
    case chopping
}
