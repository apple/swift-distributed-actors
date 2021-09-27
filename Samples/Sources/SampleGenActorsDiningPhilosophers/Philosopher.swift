//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import _Distributed
import DistributedActors
import Logging

distributed actor Philosopher {
    private let log: Logger

    private let name: String
    private let leftFork: Fork
    private let rightFork: Fork
    private var state: State = .thinking

    init(name: String, leftFork: Fork, rightFork: Fork, transport: ActorTransport) {
        self.name = name
        self.leftFork = leftFork
        self.rightFork = rightFork
        self.log = Logger(label: name)

        Task.detached {
//            context.watch(self.leftFork)
//            context.watch(self.rightFork)
            log.info("\(context.address.name) joined the table!")
            try await self.think()
        }
    }

    distributed func think() {
        if case .takingForks(let leftIsTaken, let rightIsTaken) = self.state {
            if leftIsTaken {
                leftFork.putBack()
                context.log.info("\(context.address.name) put back their left fork!")
            }

            if rightIsTaken {
                rightFork.putBack()
                context.log.info("\(context.address.name) put back their right fork!")
            }
        }

        self.state = .thinking
        self.context.timers.startSingle(key: TimerKey("think"), message: .attemptToTakeForks, delay: .seconds(1))
        self.log.info("\(self.context.address.name) is thinking...")
    }

    distributed func attemptToTakeForks() {
        guard self.state == .thinking else {
            self.log.error("\(self.context.address.name) tried to take a fork but was not in the thinking state!")
            return
        }

        self.state = .takingForks(leftTaken: false, rightTaken: false)

        func attemptToTake(fork: Actor<Fork>) {
            self.context.onResultAsync(of: fork.take(), timeout: .seconds(5)) { result in
                switch result {
                case .failure(let error):
                    self.log.warning("Failed to reach for fork! Error: \(error)")
                case .success(let didTakeFork):
                    if didTakeFork {
                        self.forkTaken(fork)
                    } else {
                        self.log.info("\(self.context.address.name) wasn't able to take a fork!")
                        self.think()
                    }
                }
            }
        }

        attemptToTake(fork: self.leftFork)
        attemptToTake(fork: self.rightFork)
    }

    /// Message sent to oneself after a timer exceeds and we're done `eating` and can become `thinking` again.
    distributed func stopEating() {
        self.leftFork.putBack()
        self.rightFork.putBack()
        self.log.info("\(self.context.address.name) is done eating and replaced both forks!")
        self.think()
    }

    private func forkTaken(_ fork: Actor<Fork>) {
        if self.state == .thinking { // We couldn't get the first fork and have already gone back to thinking.
            fork.putBack()
            return
        }

        guard case .takingForks(let leftForkIsTaken, let rightForkIsTaken) = self.state else {
            self.log.error("Received fork \(fork) but was not in .takingForks state. State was \(self.state)! Ignoring...")
            fork.putBack()
            return
        }

        switch fork {
        case self.leftFork:
            self.log.info("\(self.context.address.name) received their left fork!")
            self.state = .takingForks(leftTaken: true, rightTaken: rightForkIsTaken)
        case self.rightFork:
            self.log.info("\(self.context.address.name) received their right fork!")
            self.state = .takingForks(leftTaken: leftForkIsTaken, rightTaken: true)
        default:
            self.log.error("Received unknown fork! Got: \(fork). Known forks: \(self.leftFork), \(self.rightFork)")
        }

        if case .takingForks(true, true) = self.state {
            becomeEating()
        }
    }

    private func becomeEating() {
        self.state = .eating
        self.log.info("\(self.context.address.name) began eating!")
        (self.actorTransport as! ActorSystem).timers.startSingle(key: TimerKey("eat"), message: .stopEating, delay: .seconds(3))
    }
}

extension Philosopher {
    private enum State: Equatable {
        case thinking
        case takingForks(leftTaken: Bool, rightTaken: Bool)
        case eating
    }
}
