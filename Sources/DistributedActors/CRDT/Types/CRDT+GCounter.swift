//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019-2020 Apple Inc. and the Swift Distributed Actors project authors
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
    public struct GCounter: NamedDeltaCRDT, Codable {
        public typealias Delta = GCounterDelta

        public let replicaID: ReplicaID

        // State is a dictionary of replicas and the counter values they've observed.
        var state: [ReplicaID: Int]

        public var delta: Delta?

        var value: Int {
            self.state.values.reduce(0, +)
        }

        init(replicaID: ReplicaID) {
            self.replicaID = replicaID
            self.state = [:]
        }

        /// - Faults: on overflow // TODO perhaps just saturate?
        mutating func increment(by amount: Int) {
            precondition(amount > 0, "Amount must be greater than 0")

            let newCount: Int
            if let currentCount = state[replicaID] {
                guard case (let sum, let overflow) = currentCount.addingReportingOverflow(amount), !overflow else {
                    fatalError("Incrementing GCounter(\(self.replicaID)) by [\(amount)] resulted in overflow")
                }
                newCount = sum
            } else {
                newCount = amount
            }

            // Update state
            self.state[self.replicaID] = newCount

            // Update/create delta
            switch self.delta {
            case .some(var delta):
                delta.state[self.replicaID] = newCount
                self.delta = delta
            case .none:
                self.delta = Delta(state: [replicaID: newCount])
            }
        }

        // TODO: define on DeltaCRDT only once? alg seems generic
        public mutating func _tryMerge(other: StateBasedCRDT) -> CRDT.MergeError? {
            let OtherType = type(of: other as Any)
            if let wellTypedOther = other as? Self {
                self.merge(other: wellTypedOther)
                return nil
            } else if let wellTypedOtherDelta = other as? Self.Delta {
                // TODO: what if we simplify and compute deltas...?
                self.mergeDelta(wellTypedOtherDelta)
                return nil
            } else {
                return CRDT.MergeError(storedType: Self.self, incomingType: OtherType)
            }
        }

        // To merge delta into state, call `mergeDelta`.
        public mutating func merge(other: GCounter) {
            self.state.merge(other.state, uniquingKeysWith: max)
        }

        public mutating func mergeDelta(_ delta: Delta) {
            self.state.merge(delta.state, uniquingKeysWith: max)
        }

        public mutating func resetDelta() {
            self.delta = nil
        }
    }

    public struct GCounterDelta: CvRDT {
        // State is a dictionary of replicas and their counter values.
        var state: [ReplicaID: Int]

        init(state: [ReplicaID: Int] = [:]) {
            self.state = state
        }

        public mutating func _tryMerge(other: StateBasedCRDT) -> CRDT.MergeError? {
            let OtherType = type(of: other as Any)
            if let wellTypedOther = other as? Self {
                self.merge(other: wellTypedOther)
                return nil
            } else {
                return CRDT.MergeError(storedType: Self.self, incomingType: OtherType)
            }
        }

        public mutating func merge(other: GCounterDelta) {
            self.state.merge(other.state, uniquingKeysWith: max)
        }
    }
}

extension CRDT.GCounter: ResettableCRDT {
    public mutating func reset() {
        self = .init(replicaID: self.replicaID)
    }
}

extension CRDT.GCounter: CloneableCRDT {
    private init(replicaID: ReplicaID, state: [ReplicaID: Int], delta: Delta?) {
        self.replicaID = replicaID
        self.state = state
        self.delta = delta
    }

    public func clone() -> CRDT.GCounter {
        CRDT.GCounter(replicaID: self.replicaID, state: self.state, delta: self.delta)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned GCounter

extension CRDT.ActorOwned where DataType == CRDT.GCounter {
    public var lastObservedValue: Int {
        self.data.value
    }

    public func increment(by amount: Int, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
        // Increment locally then propagate
        self.data.increment(by: amount)
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.GCounter {
    public static func owned<Message>(by owner: ActorContext<Message>, id: String) -> CRDT.ActorOwned<CRDT.GCounter> {
        CRDT.ActorOwned<CRDT.GCounter>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.GCounter(replicaID: .actorAddress(owner.address)))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Aliases

// TODO: find better home for these type aliases

typealias GrowOnlyCounter = CRDT.GCounter
