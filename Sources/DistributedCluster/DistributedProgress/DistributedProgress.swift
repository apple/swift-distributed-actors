//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2022 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Distributed
import DistributedActorsConcurrencyHelpers
import Logging

public distributed actor DistributedProgress<Steps: DistributedProgressSteps> {
    public typealias ActorSystem = ClusterSystem
    lazy var log = Logger(actor: self)

    var step: Steps?
    var subscribers: Set<ProgressSubscriber> = []

    public init(actorSystem: ActorSystem, steps: Steps.Type = Steps.self) {
        self.actorSystem = actorSystem
    }

    func to(step: Steps) async throws {
        // TODO: checks that we don't move backwards...
        log.notice("Move to step: \(step)")
        self.step = step

        for sub in subscribers {
            try await sub.currentStep(step)
        }

        if step == Steps.allCases.reversed().first {
            self.log.notice("Progress completed, clear subscribers.")
            self.subscribers = []
            return
        }
    }

    distributed func subscribe<Subscriber: ProgressSubscriber>(subscriber: Subscriber) async throws {
        self.log.notice("Subscribed \(subscriber.id)...")
        self.subscribers.insert(subscriber)

        if let step {
            try await subscriber.currentStep(step)
        }
    }

    distributed actor ProgressSubscriber {
        typealias ActorSystem = ClusterSystem

        /// Mutable box that we update as the progress proceeds remotely...
        let box: Box

        init(box: Box, actorSystem: ActorSystem) {
            self.actorSystem = actorSystem
            self.box = box
        }

        distributed func currentStep(_ step: Steps) {
            self.box.updateStep(step)
        }
    }

    public final class Box: Codable {
        public typealias Element = Steps

        let lock: Lock
        private var currentStep: Steps?

        let source: DistributedProgress<Steps>
        let actorSystem: ClusterSystem
        private var _sub: ProgressSubscriber?

        private var _nextCC: CheckedContinuation<Steps, Never>?
        private var _completedCC: CheckedContinuation<Void, Never>?

        public // FIXME: not public
        init(source: DistributedProgress<Steps>) {
            self.source = source
            self.actorSystem = source.actorSystem
            self.lock = Lock()
            self.currentStep = nil
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.lock = Lock()
            self.currentStep = nil
            self.actorSystem = decoder.userInfo[.actorSystemKey] as! ClusterSystem
            self.source = try container.decode(DistributedProgress<Steps>.self)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(self.source)
        }

        /// Suspend until this ``DistributedProgress`` has reached its last, and final, "step".
        public func completed() async throws {
            if self.currentStep == Steps.last {
                return
            }

            try await ensureSubscription()

            await withCheckedContinuation { (cc: CheckedContinuation<Void, Never>) in
                self._completedCC = cc
            }
        }

        /// Suspend until this ``DistributedProgress`` receives a next "step".
        public func nextStep() async throws -> Steps? {
            if self.currentStep == Steps.last {
                return nil // last step was already emitted
            }

            try await ensureSubscription()

            return await withCheckedContinuation { (cc: CheckedContinuation<Steps, Never>) in
                self._nextCC = cc
            }
        }

        func updateStep(_ step: Steps) {
            self.lock.lock()
            defer { self.lock.unlock() }

            self.currentStep = step

            if let onNext = _nextCC {
                onNext.resume(returning: step)
            }

            if step == Steps.last {
                if let completed = _completedCC {
                    completed.resume()
                }
            }
        }

        @discardableResult
        private func ensureSubscription() async throws -> ProgressSubscriber {
            self.lock.lock()

            if let sub = self._sub {
                self.lock.unlock()
                return sub
            } else {
                let sub = ProgressSubscriber(box: self, actorSystem: self.actorSystem)
                self._sub = sub
                self.lock.unlock()

                try await self.source.subscribe(subscriber: sub)
                return sub
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Progress AsyncSequence

extension DistributedProgress.Box {

    public func steps(file: String = #file, line: UInt = #line) async throws -> DistributedProgressAsyncSequence<Steps> {
        try await self.ensureSubscription()

        return DistributedProgressAsyncSequence(box: self)
    }
}

public struct DistributedProgressAsyncSequence<Steps: DistributedProgressSteps>: AsyncSequence {
    public typealias Element = Steps

    private let box: DistributedProgress<Steps>.Box

    public init(box: DistributedProgress<Steps>.Box) {
        self.box = box
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(box: self.box)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        public typealias Element = Steps
        let box: DistributedProgress<Steps>.Box

        init(box: DistributedProgress<Steps>.Box) {
            self.box = box
        }

        public func next() async throws -> Steps? {
            try await box.nextStep()
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Progress Steps protocol

public protocol DistributedProgressSteps: Codable, Sendable, Equatable, CaseIterable {
    static var count: Int { get }
    static var last: Self { get }
}
extension DistributedProgressSteps {
    public static var count: Int {
        precondition(count > 0, "\(Self.self) cannot have zero steps (cases)!")
        return Self.allCases.count
    }

    public static var last: Self {
        guard let last = Self.allCases.reversed().first else {
            fatalError("\(Self.self) cannot have zero steps (cases)!")
        }
        return last
    }
}