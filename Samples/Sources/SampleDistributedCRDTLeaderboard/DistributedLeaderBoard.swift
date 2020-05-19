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

struct DistributedLeaderboard {

    /// Enable networking on this node, and select which port it should bind to.
    private func configureClustering(_ settings: inout ActorSystemSettings, port: Int) {
        settings.cluster.enabled = true
        settings.cluster.bindPort = port
    }

    /// Register any types that should be trusted for serialization (messages which are sent across the wire).
    /// 
    /// Notice that we do not need to register the `GCounter` or similar types since they are built-in (and use Int, which is naturally assumed trusted).
    /// If you wanted to gossip an `MyCustomType` e.g. in an `ORSet` rather than the plain GCounter you'd need to register MyCustomType here, like so:
    ///
    /// ```
    /// serialization
    /// ```
    /// - Parameter settings:
    private func configureMessageSerializers(_ settings: inout ActorSystemSettings) {
    }

    func run(for time: TimeAmount) throws {
        let first = ActorSystem("first") { settings in
            self.configureMessageSerializers(&settings)
            self.configureClustering(&settings, port: 1111)
        }
        let second = ActorSystem("second") { settings in
            self.configureMessageSerializers(&settings)
            self.configureClustering(&settings, port: 2222)
        }
        let third = ActorSystem("third") { settings in
            self.configureMessageSerializers(&settings)
            self.configureClustering(&settings, port: 3333)
        }

        print("~~~~~~~ started 3 actor systems ~~~~~~~")
        first.cluster.join(node: second.settings.cluster.node)
        first.cluster.join(node: third.settings.cluster.node)
        third.cluster.join(node: second.settings.cluster.node)

        while first.cluster.membershipSnapshot.members(atLeast: .up).count < 3 {
            Thread.sleep(.seconds(1))
        }
        print("~~~~~~~ systems joined each other ~~~~~~~")

        let player1 = try first.spawn("player-one", self.player())
        let player2 = try second.spawn("player-two", self.player())
        let player3 = try third.spawn("player-three", self.player())

        // The "game" is a form of waiting game -- sit back and relax, as the players (randomly) score points
        // and race to the top position. While they do so, they independently update a GCounter of the "total score"
        // which other non participants may observe as well.
        _ = try first.spawn("game-engine", self.game(with: [player1, player2, player3]))


        first.park(atMost: time)
    }
}

struct DataID {
    static let totalScore = "total-score-counter"
    static let totalScoreIdentity = CRDT.Identity(DataID.totalScore)
}
