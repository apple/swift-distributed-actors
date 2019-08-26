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
    /// An optimized implementation of GCounter as delta-CRDT.
    ///
    /// GCounter, or grow-only counter, is a counter that only increments. Its value cannot be decreased--there is no
    /// `decrement` operation and negative values are rejected by the `increment` method.
    ///
    /// - SeeAlso: [Delta State Replicated Data Types](https://arxiv.org/abs/1603.01529)
    /// - SeeAlso: [A comprehensive study of CRDTs](https://hal.inria.fr/file/index/docid/555588/filename/techreport.pdf)
    public struct GCounter: NamedDeltaCRDT {
        public typealias Delta = GCounterDelta

        public let replicaId: ReplicaId

        // State is a dictionary of replicas and the counter values they've observed.
        var state: [ReplicaId: Int]

        public var delta: Delta?

        var value: Int {
            return self.state.values.reduce(0, +)
        }

        init(replicaId: ReplicaId) {
            self.replicaId = replicaId
            self.state = [:]
        }

        mutating func increment(by amount: Int) {
            precondition(amount > 0, "Amount must be greater than 0")

            let newCount: Int
            if let currentCount = state[replicaId] {
                guard case (let sum, let overflow) = currentCount.addingReportingOverflow(amount), !overflow else {
                    fatalError("Incrementing GCounter(\(self.replicaId)) by [\(amount)] resulted in overflow")
                }
                newCount = sum
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
        public mutating func merge(other: GCounter) {
            self.state.merge(other.state, uniquingKeysWith: max)
            self.resetDelta()
        }

        public mutating func mergeDelta(_ delta: Delta) {
            self.state.merge(delta.state, uniquingKeysWith: max)
            self.resetDelta()
        }

        public mutating func resetDelta() {
            self.delta = nil
        }
    }

    public struct GCounterDelta: CvRDT {
        // State is a dictionary of replicas and their counter values.
        var state: [ReplicaId: Int]

        init(state: [ReplicaId: Int] = [:]) {
            self.state = state
        }

        public mutating func merge(other: GCounterDelta) {
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
        // Increment locally then propagate
        self.data.increment(by: amount)
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
