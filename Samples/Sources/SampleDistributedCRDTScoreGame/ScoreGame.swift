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

struct ScoreGame {

    /// Enable networking on this node, and select which port it should bind to.
    private func configureClustering(_ settings: inout ActorSystemSettings, port: Int) {
        settings.cluster.enabled = true
        settings.cluster.bindPort = port
    }

    /// Register any types that should be trusted for serialization (messages which are sent across the wire).
    private func configureMessageSerializers(_ settings: inout ActorSystemSettings) {
    }

    func run(nodes nodesN: Int, for time: TimeAmount) throws {
        let nodes = (1...nodesN).map { n in
            ActorSystem("\(n)") { settings in
                self.configureMessageSerializers(&settings)
                self.configureClustering(&settings, port: 1110 + n)

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

        let players = try nodes.map { system in
            try system.spawn("player-\(system.name)", self.player())
        }

        // The "game" is a form of waiting game -- sit back and relax, as the players (randomly) score points
        // and race to the top position. While they do so, they independently update a GCounter of the "total score"
        // which other non participants may observe as well.
        _ = try first.spawn("game-engine", self.game(with: players))

        try first.park(atMost: time)
    }
}

struct DataID {
    static let totalScore = "total-score-counter"
    static let totalScoreIdentity = CRDT.Identity(DataID.totalScore)
}
