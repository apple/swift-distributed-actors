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

struct DistributedLeaderBoard {
    private func configureMessageSerializers(_ settings: inout ActorSystemSettings) {
    }

    /// Enable networking on this node, and select which port it should bind to.
    private func configureClustering(_ settings: inout ActorSystemSettings, port: Int) {
        settings.cluster.enabled = true
        settings.cluster.bindPort = port
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
            pprint("first.cluster.membershipSnapshot = \(String(reflecting: first.cluster.membershipSnapshot))")
            Thread.sleep(.seconds(1))
        }
        print("~~~~~~~ systems joined each other ~~~~~~~")

        let player1 = try first.spawn("player-one", self.player())
        let player2 = try second.spawn("player-2", self.player())
        let player3 = try third.spawn("player-3", self.player())

        // The "game" is a form of waiting game -- sit back and relax, as the players (randomly) score points
        // and race to the top position. While they do so, they independently update a GCounter of the "total score"
        // which other non participants may observe as well.
        _ = try first.spawn("game-engine", self.game(with: [player1, player2, player3]))


        first.park(atMost: time)
    }
}

extension DistributedLeaderBoard {


    enum GameEvent {
        case scorePoints(Int)
    }

    func player() -> Behavior<GameEvent> {
        .setup { context in
            var myScore: Int = 0

            let totalScore: CRDT.ActorOwned<CRDT.GCounter> = CRDT.ActorOwned(ownerContext: context, id: DataID.totalScore, data: CRDT.GCounter(owner: context.address))
            _ = totalScore.increment(by: 1, writeConsistency: .local, timeout: .seconds(1))

            return .receiveMessage {
                switch $0 {
                case .scorePoints(let points):
                    myScore += points
                    _ = totalScore.increment(by: points, writeConsistency: .local, timeout: .effectivelyInfinite)
                    context.log.info("Scored +\(points), sum: \(myScore), global points sum: \(totalScore.lastObservedValue)")
                }

                return .same
            }
        }
    }

    func game(with players: [ActorRef<GameEvent>]) -> Behavior<String> {
        .setup { context in
            context.timers.startPeriodic(key: "game-tick", message: "game-tick", interval: .milliseconds(200))

            func playerScored(_ player: ActorRef<GameEvent>) {
                player.tell(.scorePoints(.random(in: 1 ... 10)))
            }

            func onGameTick() {
                if let playerScoredPoint = players.randomElement() {
                    playerScored(playerScoredPoint)
                }
            }

            return .receiveMessage { _ in
                onGameTick()
                return .same
            }
        }
    }


}


struct DataID {
    static let totalScore = CRDT.Identity("total-score-counter")
}
