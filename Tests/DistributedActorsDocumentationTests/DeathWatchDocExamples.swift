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
    enum Command: ActorMessage {
        case player(ActorRef<Player.Command>)
        case otherCommand
    }
}

extension GameUnit.Command {
    enum DiscriminatorKeys: String, Codable {
        case player
        case otherCommand
    }

    enum CodingKeys: CodingKey {
        case _case
        case player_value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .player:
            let value = try container.decode(ActorRef<Player.Command>.self, forKey: .player_value)
            self = .player(value)
        case .otherCommand:
            self = .otherCommand
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .player(let value):
            try container.encode(DiscriminatorKeys.player, forKey: ._case)
            try container.encode(value, forKey: .player_value)
        case .otherCommand:
            try container.encode(DiscriminatorKeys.player, forKey: ._case)
        }
    }
}

struct GameMatch {
    enum Command: ActorMessage {
        case playerConnected(ActorRef<Player.Command>)
        case disconnectedPleaseStop
    }
}

extension GameMatch.Command {
    enum DiscriminatorKeys: String, Codable {
        case playerConnected
        case disconnectedPleaseStop
    }

    enum CodingKeys: CodingKey {
        case _case
        case playerConnected_value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(DiscriminatorKeys.self, forKey: ._case) {
        case .playerConnected:
            let value = try container.decode(ActorRef<Player.Command>.self, forKey: .playerConnected_value)
            self = .playerConnected(value)
        case .disconnectedPleaseStop:
            self = .disconnectedPleaseStop
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .playerConnected(let value):
            try container.encode(DiscriminatorKeys.playerConnected, forKey: ._case)
            try container.encode(value, forKey: .playerConnected_value)
        case .disconnectedPleaseStop:
            try container.encode(DiscriminatorKeys.disconnectedPleaseStop, forKey: ._case)
        }
    }
}

class DeathWatchDocExamples {
    func unitReady() -> Behavior<GameUnit.Command> {
        .ignore
    }

    func simple_watch() throws {
        // tag::simple_death_watch[]
        func gameUnit(player: ActorRef<Player.Command>) -> Behavior<GameUnit.Command> {
            .setup { context in
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
            false
        }
        // tag::handling_termination_deathwatch[]
        let concedeTimer: TimerKey = "concede-timer"

        _ = Behavior<GameMatch.Command>.receive { context, command in
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
