//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import DistributedActors

public class Philosopher {
    public typealias Ref = ActorRef<Message>

    public enum Message: Codable { // Codable only necessary for running distributed
        case think
        case eat
        /* --- internal protocol --- */
        case forkReply(_ reply: Fork.Reply)
    }

    private let left: Fork.Ref
    private let right: Fork.Ref

    init(left: Fork.Ref, right: Fork.Ref) {
        self.left = left
        self.right = right
    }

    public var behavior: Behavior<Philosopher.Message> {
        return self.thinking
    }

    /// Initial and public state from which a Philosopher starts its life
    private var thinking: Behavior<Philosopher.Message> {
        return .setup { context in
            context.watch(self.left)
            context.watch(self.right)

            let myselfForFork = context.messageAdapter(from: Fork.Reply.self) { .forkReply($0) }
            context.log.info("I'm thinking...")
            // remember to eat after some time!
            context.timers.startSingle(key: TimerKey("eat"), message: .eat, delay: .seconds(1))

            return .receiveMessage { msg in
                switch msg {
                case .eat:
                    context.log.info("I'm becoming hungry, trying to grab forks...")
                    self.left.tell(Fork.Message.take(by: myselfForFork))
                    self.right.tell(Fork.Message.take(by: myselfForFork))
                    return self.hungry(myselfForFork: myselfForFork)

                case .think:
                    fatalError("Already thinking")

                case .forkReply:
                    return .same
                }
            }
        }
    }

    /// A hungry philosopher is waiting to obtain both forks before it can start eating
    private func hungry(myselfForFork: ActorRef<Fork.Reply>) -> Behavior<Philosopher.Message> {
        return .receive { _, msg in
            switch msg {
            case .forkReply(.pickedUp(let fork)):
                let other: Fork.Ref = (fork == self.left) ? self.right : self.left
                return self.hungryAwaitingFinalFork(inHand: fork, pending: other, myselfForFork: myselfForFork)

            case .forkReply(.busy):
                // we know that we were refused one fork, so regardless of the 2nd one being available or not
                // we will not be able to become eating. In order to not accidentally keep holding the 2nd fork,
                // in case it would reply with `pickedUp` we want to put it down (sadly), as we will try again some time later.
                return .receiveMessage {
                    switch $0 {
                    case .forkReply(.pickedUp(let fork)):
                        // sadly we have to put it back, we know we won't succeed this time
                        fork.tell(.putBack(by: myselfForFork))
                        return self.thinking
                    case .forkReply(.busy(_)):
                        // we failed picking up either of the forks, time to become thinking about obtaining forks again
                        return self.thinking
                    default:
                        return .ignore
                    }
                }

            case .think:
                return .ignore // only based on fork replies we may decide to become thinking again
            case .eat:
                return .ignore // we are in process of trying to eat already
            }
        }
    }

    private func hungryAwaitingFinalFork(inHand: Fork.Ref, pending: Fork.Ref, myselfForFork: ActorRef<Fork.Reply>) -> Behavior<Philosopher.Message> {
        return .receive { _, msg in
            switch msg {
            case .forkReply(.pickedUp(pending)):
                return self.eating(myselfForFork: myselfForFork)
            case .forkReply(.pickedUp(let fork)):
                fatalError("Received fork which I already hold in hand: \(fork), this is wrong!")

            case .forkReply(.busy(pending)):
                // context.log.info("The pending \(pending) busy, I'll think about obtaining it...")
                // the Fork we attempted to pick up is already in use (busy), we'll back off and try again
                inHand.tell(.putBack(by: myselfForFork))
                return self.thinking
            case .forkReply(.busy(let fork)):
                fatalError("Received fork busy response from an unexpected fork: \(fork)! Already in hand: \(inHand), and pending: \(pending)")

            // Ignore others...
            case .think: return .ignore // since we'll decide to become thinking ourselves
            case .eat: return .ignore // since we'll decide to become eating ourselves
            }
        }
    }

    /// A state reached by successfully obtaining two forks and becoming "eating".
    /// Once the Philosopher is done eating, it will putBack both forks and become thinking again.
    private func eating(myselfForFork: ActorRef<Fork.Reply>) -> Behavior<Philosopher.Message> {
        return .setup { context in
            // here we act as if we "think and then eat"
            context.log.info("Setup eating, I have: \(uniquePath: self.left) and \(uniquePath: self.right)")

            // simulate that eating takes time; once done, notify myself to become thinking again
            context.timers.startSingle(key: TimerKey("think"), message: .think, delay: .milliseconds(200))

            return .receiveMessage { // TODO: `receiveExactly` would be nice here
                switch $0 {
                case .think:
                    context.log.info("I've had a good meal, returning forks, and become thinking!")
                    self.left.tell(.putBack(by: myselfForFork))
                    self.right.tell(.putBack(by: myselfForFork))
                    return self.thinking

                default:
                    return .ignore // ignore eat and others, since I'm eating already!
                }
            }
        }
    }

    private func forkSideName(_ fork: Fork.Ref) -> String {
        return fork == self.left ? "left" : "right"
    }
}
