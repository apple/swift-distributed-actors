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

        /// Current value of the GCounter.
        ///
        /// It is a sum of all replicas counts.
        public var value: Int {
            self.state.values.reduce(0, +)
        }

        /// Creates a pure datatype that can be manually managed (passed around, merged, serialized), without involvement of the actor runtime.
        public init(replicaID: ReplicaID) {
            self.replicaID = replicaID
            self.state = [:]
        }

        /// Increment the counter (using the stored owner `replicaID`) by the passed in `amount`.
        ///
        /// - Faults: when amount is negative
        /// - Faults: on overflow // TODO perhaps just saturate?
        mutating func increment(by amount: Int) {
            precondition(amount >= 0, "Amount must be greater than 0, was: \(amount)")

            guard amount > 0 else {
                return // adding 0 is a no-op, and we don't even perform the action (which would create deltas)
            }

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

        public func equalState(to other: StateBasedCRDT) -> Bool {
            guard let other = other as? Self else {
                return false
            }

            return self.state == other.state
        }
    }

    public struct GCounterDelta: CvRDT, Equatable {
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

        public func equalState(to other: StateBasedCRDT) -> Bool {
            guard let other = other as? Self else {
                return false
            }

            return self.state == other.state
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT String Descriptions

extension CRDT.GCounter: CustomStringConvertible, CustomPrettyStringConvertible {
    public var description: String {
        "\(Self.self)(\(self.value))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Aliases

// TODO: find better home for these type aliases

typealias GrowOnlyCounter = CRDT.GCounter
