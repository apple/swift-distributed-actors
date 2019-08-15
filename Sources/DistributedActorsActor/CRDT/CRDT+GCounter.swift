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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: GCounter as pure CRDT

extension CRDT {
    public struct GCounter: NamedDeltaCRDT {
        public typealias Delta = GCounterDelta

        public let replicaId: ReplicaId

        // State is a dictionary of replicas and the counter values they've observed.
        var state: [ReplicaId: Int]

        public var delta: Delta?

        var value: Int {
            return self.state.values.reduce(0, +)
        }

        init(replicaId: ReplicaId, state: [ReplicaId: Int] = [:], delta: Delta? = nil) {
            self.replicaId = replicaId
            self.state = state
            self.delta = delta
        }

        mutating func increment(by amount: Int) {
            precondition(amount > 0, "Amount must be greater than 0")

            let newCount: Int
            if let currentCount = state[replicaId] {
                // TODO: handle overflow (use currentCount.addingReportingOverflow)
                newCount = currentCount + amount
            } else {
                newCount = amount
            }

            // Update state
            self.state[replicaId] = newCount

            // Update/create delta
            switch self.delta {
            case .some(var delta):
                delta.state[replicaId] = newCount
                self.delta = delta
            case .none:
                self.delta = Delta(state: [replicaId: newCount])
            }
        }

        // To merge delta into state, call `mergeDelta`.
        mutating public func merge(other: GCounter) {
            self.state.merge(other.state, uniquingKeysWith: max)
            self.resetDelta()
        }

        mutating public func mergeDelta(_ delta: Delta) {
            self.state.merge(delta.state, uniquingKeysWith: max)
            self.resetDelta()
        }

        mutating public func resetDelta() {
            self.delta = nil
        }
    }

    public struct GCounterDelta: CvRDT {
        // State is a dictionary of replicas and their counter values.
        var state: [ReplicaId: Int]

        init(state: [ReplicaId: Int] = [:]) {
            self.state = state
        }

        mutating public func merge(other: GCounterDelta) {
            self.state.merge(other.state, uniquingKeysWith: max)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned GCounter

extension CRDT.ActorOwned where DataType == CRDT.GCounter {
    public var lastObservedValue: Int {
        return self.data.value
    }

    public func increment(by amount: Int, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> Result<DataType> {
        // Increment locally
        self.data.increment(by: amount)
        // Generic write which includes calling the replicator
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.GCounter {
    public static func owned<Message>(by owner: ActorContext<Message>, id: String) -> CRDT.ActorOwned<CRDT.GCounter> {
        return CRDT.ActorOwned<CRDT.GCounter>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.GCounter(replicaId: .actorAddress(owner.address)))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Aliases
// TODO: find better home for these type aliases

typealias GrowOnlyCounter = CRDT.GCounter
