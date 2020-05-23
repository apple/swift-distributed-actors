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

extension DistributedLeaderboard {

    enum GameEvent: Codable {
        case turn
    }

    func player() -> Behavior<GameEvent> {
        .setup { context in
            context.log.info("Ready: \(context.name)")

            /// Local score, of how much this player has contributed to the total score
            var myScore: Int = 0

            let consistency: CRDT.OperationConsistency = .local

            /// A cluster-wise distributed counter; each time we perform updates to it, the update will be replicated.
            let totalScore: CRDT.ActorOwned<CRDT.GCounter> = CRDT.GCounter.makeOwned(by: context, id: DataID.totalScore)

            return .receiveMessage {
                switch $0 {
                case .turn:
                    let points = Int.random(in: 0...10)
                    myScore += points
                    context.log.info("Scored \(points), write consistency: \(consistency)")
                    _ = totalScore.increment(by: points, writeConsistency: consistency, timeout: .seconds(1))
                }

                return .same
            }
        }
    }
}

extension DistributedLeaderboard.GameEvent {
    enum DiscriminatorKeys: String, Codable {
        case turn
    }
    enum CodingKeys: CodingKey {
        case _case
        case scorePoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .turn:
            self = .turn
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .turn:
            try container.encode(DiscriminatorKeys.turn, forKey: ._case)
        }
    }
}