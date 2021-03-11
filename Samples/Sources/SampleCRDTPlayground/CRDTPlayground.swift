//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import DistributedActors

struct CRDTPlayground {
    /// Enable networking on this node, and select which port it should bind to.
    private func configureClustering(_ settings: inout ActorSystemSettings, port: Int) {
        settings.cluster.enabled = true
        settings.cluster.bindPort = port
    }

    private func configureMessageSerializers(_ settings: inout ActorSystemSettings) {
        settings.serialization.register(CRDT.ORSet<String>.self)
    }

    func run(nodes nodesN: Int, for time: TimeAmount) throws {
        let nodes = (1 ... nodesN).map { n in
            ActorSystem("\(n)") { settings in
                self.configureMessageSerializers(&settings)
                self.configureClustering(&settings, port: 1110 + n)

                settings.crdt.gossipInterval = .milliseconds(500)

                #if os(macOS) || os(tvOS) || os(iOS) || os(watchOS)
                if n == 1 { // enough to instrument a single node
                    settings.instrumentation.configure(with: OSSignpostInstrumentationProvider())
                }
                #endif
            }
        }

        print("~~~~~~~ started \(nodesN) actor systems ~~~~~~~")
        let first: ActorSystem = nodes.first!

        _ = nodes.reduce(first) { node, nextNode in
            node.cluster.join(node: nextNode.cluster.uniqueNode)
            return nextNode
        }

        while first.cluster.membershipSnapshot.members(atLeast: .up).count < nodes.count {
            Thread.sleep(.seconds(1))
        }
        print("~~~~~~~ systems joined each other ~~~~~~~")

        let peers = try nodes.map { system in
            try system.spawn("peer-\(system.name)", self.peer(
                writeConsistency: .quorum,
                stopWhen: { set in set.count == nodes.count * 2 } // each node to perform 2 unique writes
            ))
        }

        for peer in peers {
            peer.tell("write-1-\(peer.path.name)")
            peer.tell("write-2-\(peer.path.name)")
        }

        try! first.park(atMost: time)
    }
}

struct DataID {
    static let totalScore = "total-score-counter"
    static let totalScoreIdentity = CRDT.Identity(DataID.totalScore)
}
