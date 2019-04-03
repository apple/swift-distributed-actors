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

    public enum Messages {
        /// A Philosopher may attempt to take a fork from the table by sending a take message to it
        case take(by: ActorRef<Fork.Replies>)
        /// A
        case putBack(by: Philosopher.Ref) // yet only intended to receive the .forkReply TODO that's why we need adapters
    }

    public enum Replies {
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
        return .receive { (context: ActorContext<Messages>, msg: Fork.Messages) in
            switch msg {
            case let .take(who):
                 who.tell(.pickedUp(fork: context.myself))
                return taken(by: who, context)

            case let .putBack(who):
                fatalError("\(who) attempted to put back an already available fork!")
            }
        }
    }

    private static func taken(by owner: ActorRef<Fork.Replies>, _ context: ActorContext<Fork.Messages>) -> SelfBehavior {
        context.log.info("Taken by \(owner)")
        return .receiveMessage { msg in
            switch msg {
            case .putBack(let who) where owner.path == owner.path:
                context.log.info("\(who) is putting back the fork \(context.myself)...")
                return available()

            case let .putBack(who):
                fatalError("\(who) attempted to put back \(context.myself), yet it is owned by \(owner)! That's wrong.")

            case let .take(who):
                context.log.info("\(who) attempted to take [\(context.myself)], yet already taken by \(owner)...")
                who.tell(.busy(fork: context.myself))
                return .ignore
            }
        }
    }
}
