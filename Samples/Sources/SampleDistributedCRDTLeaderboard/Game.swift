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

let roundsMax = 20

extension DistributedLeaderboard {

    func game(with players: [ActorRef<GameEvent>]) -> Behavior<String> {
        .setup { context in
            var round = 0

            context.timers.startPeriodic(key: "game-tick", message: "game-tick", interval: .milliseconds(200))

            func onGameTick() {
                if let player = players.randomElement() {
                    round += 1
                    if round <= roundsMax {
                        context.log.notice("[Round \(round)] Player [\(player.path.name)] may take a turn.")
                        player.tell(.turn)
                    } else {
                        context.timers.cancel(for: "game-tick")
                        context.myself.tell("done")
                    }
                }
            }

            func inspectScores() {
                let counter = CRDT.GCounter.makeOwned(by: context, id: DataID.totalScore)
                let readAll = counter.read(atConsistency: .all, timeout: .seconds(3))
                readAll.onComplete { res in
                    switch res {
                    case .success(let counter):
                        context.log.notice("Total score: \(counter), details: \(counter.prettyDescription)")
                    case .failure(let error):
                        context.log.warning("Error reading scores! Error: \(error)")
                    }
                }
            }

            return .receiveMessage { message in
                switch message {
                case "game-tick": onGameTick()
                case "done": inspectScores()
                default: fatalError("unexpected message: \(message)")
                }
                return .same
            }
        }
    }
}