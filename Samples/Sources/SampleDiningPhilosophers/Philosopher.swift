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
    private let name: String
    private lazy var log: Logger = Logger(actor: self)

    private let leftFork: Fork
    private let rightFork: Fork
    private var state: State = .thinking

    private lazy var timers = DistributedActors.ActorTimers<Philosopher>(self)

    init(name: String, leftFork: Fork, rightFork: Fork, transport: ActorTransport) {
        defer { transport.actorReady(self) }
        self.name = name
        self.leftFork = leftFork
        self.rightFork = rightFork
        self.log.info("\(self.name) joined the table!")

        assert(log[metadataKey: "cluster/node"] != nil, "was: \(self.id)")

        Task {
//            context.watch(self.leftFork)
//            context.watch(self.rightFork)
            try await self.think()
        }
    }

    distributed func think() {
        if case .takingForks(let leftIsTaken, let rightIsTaken) = self.state {
            if leftIsTaken {
                Task {
                    try await leftFork.putBack()
                    self.log.info("\(self.name) put back their left fork!")
                }
            }

            if rightIsTaken {
                Task {
                    try await rightFork.putBack()
                    self.log.info("\(self.name) put back their right fork!")
                }
            }
        }

        self.state = .thinking
        self.timers.startSingle(key: .becomeHungry, delay: .seconds(1)) {
            await self.attemptToTakeForks()
        }
        self.log.info("\(self.self.name) is thinking...")
    }

    distributed func attemptToTakeForks() async {
        guard self.state == .thinking else {
            self.log.error("\(self.self.name) tried to take a fork but was not in the thinking state!")
            return
        }

        self.state = .takingForks(leftTaken: false, rightTaken: false)

        do {
            // TODO(distributed): take the forks in parallel; rdar://83609197 blocked on async let + distributed interaction

            let tookRight = try await self.rightFork.take()
            guard tookRight else {
                self.think()
                return
            }
            self.forkTaken(leftFork)

            let tookLeft = try await self.leftFork.take()
            guard tookLeft else {
                self.think()
                return
            }
            self.forkTaken(rightFork)
        } catch {
            self.log.info("\(self.self.name) wasn't able to take both forks!")
            self.think()
        }
    }

    /// Message sent to oneself after a timer exceeds and we're done `eating` and can become `thinking` again.
    distributed func stopEating() {
        self.log.info("\(self.self.name) is done eating and replaced both forks!")
        Task {
            do {
                try await self.leftFork.putBack()
            } catch {
                self.log.warning("Failed putting back fork \(leftFork): \(error)")
            }
        }
        Task {
            do {
            try await self.rightFork.putBack()
            } catch {
                self.log.warning("Failed putting back fork \(leftFork): \(error)")
            }
        }
        self.think()
    }

    private func forkTaken(_ fork: Fork) {
        if self.state == .thinking { // We couldn't get the first fork and have already gone back to thinking.
            Task { try await fork.putBack() }
            return
        }

        guard case .takingForks(let leftForkIsTaken, let rightForkIsTaken) = self.state else {
            self.log.error("Received fork \(fork) but was not in .takingForks state. State was \(self.state)! Ignoring...")
            Task { try await fork.putBack() }
            return
        }

        switch fork {
        case self.leftFork:
            self.log.info("\(self.self.name) received their left fork!")
            self.state = .takingForks(leftTaken: true, rightTaken: rightForkIsTaken)
        case self.rightFork:
            self.log.info("\(self.self.name) received their right fork!")
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
        self.log.info("\(self.self.name) began eating!")
        self.timers.startSingle(key: .becomeHungry, delay: .seconds(3)) {
            await self.stopEating()
        }
    }
}

extension TimerKey {
    static let becomeHungry: Self = "become-hungry"
    static let finishEating: Self = "finish-eating"
}
extension Philosopher {
    private enum State: Equatable {
        case thinking
        case takingForks(leftTaken: Bool, rightTaken: Bool)
        case eating
    }
}
