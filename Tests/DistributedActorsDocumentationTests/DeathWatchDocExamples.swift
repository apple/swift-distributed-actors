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

// tag::imports[]

import DistributedActors

// end::imports[]

struct Player {
    typealias Command = String
}

struct GameUnit {
    enum Command {
        case player(ActorRef<Player.Command>)
        case otherCommand
    }
}

struct GameMatch {
    enum Command {
        case playerConnected(ActorRef<Player.Command>)
        case disconnectedPleaseStop
    }
}

class DeathWatchDocExamples {
    func unitReady() -> Behavior<GameUnit.Command> {
        return .ignore
    }

    func simple_watch() throws {
        // tag::simple_death_watch[]
        func gameUnit(player: ActorRef<Player.Command>) -> Behavior<GameUnit.Command> {
            return .setup { context in
                context.watch(player) // <1>

                return .receiveMessage { _ in // <2>
                    // perform some game logic...
                    .same
                } // <3>
            }
        }
        // end::simple_death_watch[]
    }

    func schedule_event() throws {
        func isPlayer(_: Any) -> Bool {
            return false
        }
        // tag::handling_termination_deathwatch[]
        let concedeTimer: TimerKey = "concede-timer"

        Behavior<GameMatch.Command>.receive { context, command in
            switch command {
            case .playerConnected(let player):
                context.timers.cancel(for: concedeTimer)
                context.watch(player)
                return .same

            case .disconnectedPleaseStop:
                context.log.info("Stopping since player remained not connected for a while...")
                return .stop
            }
        }.receiveSpecificSignal(Signals.Terminated.self) { context, terminated in
            guard isPlayer(terminated) else {
                return .unhandled
            }

            context.timers.startSingle(key: concedeTimer, message: .disconnectedPleaseStop, delay: .seconds(1))
            return .same
        }
        // end::handling_termination_deathwatch[]
    }
}
