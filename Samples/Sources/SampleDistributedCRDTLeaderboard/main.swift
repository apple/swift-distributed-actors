//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
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

extension DistributedLeaderboard {

    enum GameEvent: ActorMessage {
        case scorePoints(Int)
    }

    func player() -> Behavior<GameEvent> {
        .setup { context in
            context.log.info("Ready: \(context.name)")

            /// Local score, of how much this player has contributed to the total score
            var myScore: Int = 0

            /// A cluster-wise distributed counter; each time we perform updates to it, the update will be replicated.
            let totalScore: CRDT.ActorOwned<CRDT.GCounter> = CRDT.GCounter.owned(by: context, id: DataID.totalScore)
            _ = totalScore.increment(by: 1, writeConsistency: .quorum, timeout: .seconds(1))

            return .receiveMessage {
                switch $0 {
                case .scorePoints(let points):
                    myScore += points
                    _ = totalScore.increment(by: points, writeConsistency: .quorum, timeout: .seconds(1))
                    context.log.info("Scored +\(points), my score: \(myScore), global total score: \(totalScore.lastObservedValue)"
                        //     , metadata: ["total/score": "\(totalScore.data)"]
                    )
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
    static let totalScore = "total-score-counter"
    static let totalScoreIdentity = CRDT.Identity(DataID.totalScore)
}


extension DistributedLeaderboard.GameEvent: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let points = try container.decode(Int.self)
        self = .scorePoints(points)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .scorePoints(let points):
            var container = encoder.singleValueContainer()
            try container.encode(points)
        }
    }
}

try! DistributedLeaderboard().run(for: .seconds(20))
