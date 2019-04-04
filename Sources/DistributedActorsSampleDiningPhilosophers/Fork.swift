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

import Swift Distributed ActorsActor


public final class Fork {
    public typealias Ref = ActorRef<Fork.Messages>
    public typealias SelfBehavior = Behavior<Fork.Messages>

    public enum Messages: Codable { // Codable only necessary for running distributed
        /// A Philosopher may attempt to take a fork from the table by sending a take message to it
//        case take(by: ActorRef<Fork.Replies>)
        case take(by: Philosopher.Ref)
        /// A
        case putBack(by: Philosopher.Ref) // yet only intended to receive the .forkReply TODO that's why we need adapters
    }

    public enum Replies: Codable { // Codable only necessary for running distributed
        /// when a Fork was successfully picked up by an Philosopher it will receive this response
        case pickedUp(fork: Fork.Ref)
        /// if a Fork was in use by some other Philosopher, we ask the 2nd one (who lost the "race") that the fork is already
        /// being used and that it should try again in a little bit.
        case busy(fork: Fork.Ref)
    }

    public static var behavior: SelfBehavior {
        return available()
    }

    private static func available() -> SelfBehavior {
        return .receive { context, message in
            switch message {
            case .take(let who):
                 who.tell(.forkReply(.pickedUp(fork: context.myself)))
                // who.tell(.pickedUp(fork: context.myself)) // TODO doable when we get adapters
                return taken(context, by: who)

            case .putBack(let who):
                fatalError("\(uniquePath: who) attempted to put back an already available fork \(uniquePath: context.myself)!")
            }
        }
    }

    private static func taken(_ context: ActorContext<Fork.Messages>, by owner: Philosopher.Ref) -> SelfBehavior {
        return .receiveMessage { message in
            switch message {
            case .putBack(let who) where owner.path == owner.path:
                context.log.info("\(uniquePath: who) is putting back the fork \(uniquePath: context.myself)...")
                return available()

            case .putBack(let who):
                fatalError("\(uniquePath: who) attempted to put back \(uniquePath: context.myself), yet it is owned by \(uniquePath: owner)! That's wrong.")

            case .take(let who):
                context.log.info("\(uniquePath: who) attempted to take \(uniquePath: context.myself), yet already taken by \(uniquePath: owner)...")
                // who.tell(.busy(fork: context.myself))
                who.tell(.forkReply(.busy(fork: context.myself)))
                return .ignore
            }
        }
    }
}
