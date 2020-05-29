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
// MARK: ORSet as pure CRDT

extension CRDT {
    /// An optimized ORSet based on [An optimized conflict-free replicated set](https://hal.inria.fr/file/index/docid/738680/filename/RR-8083.pdf),
    /// influenced by Bartosz Sypytkowski's work (https://github.com/Horusiath/crdt-examples) and Akka's [`ORSet`](https://github.com/akka/akka/blob/master/akka-distributed-data/src/main/scala/akka/cluster/ddata/ORSet.scala).
    ///
    /// ORSet, short for observed-remove set and also known as add-wins replicated set, supports both `add` and `remove`.
    /// An element can be added or removed any number of times. The outcome of `add`s and `remove`s depends only on the
    /// causal history ("happens-before" relation) of operations. It is "add-wins" because when `add` and `remove` of the
    /// same element are concurrent (i.e., we cannot determine which happens before another), `add` always "wins" since
    /// `remove` is concerned with *observed* events only (the concurrent `add` has not been observed yet).
    ///
    /// - SeeAlso: [An optimized conflict-free replicated set](https://hal.inria.fr/file/index/docid/738680/filename/RR-8083.pdf) (Annette Bieniusa, Marek Zawirski, Nuno Preguiça, Marc Shapiro, Carlos Baquero, Valter Balegas, Sérgio Duarte, 2012)
    /// - SeeAlso: [Optimizing state-based CRDTs (part 2)](https://bartoszsypytkowski.com/optimizing-state-based-crdts-part-2/) (Bartosz Sypytkowski, 2018)
    /// - SeeAlso: [A comprehensive study of CRDTs](https://hal.inria.fr/file/index/docid/555588/filename/techreport.pdf) (Marc Shapiro, Nuno Preguiça, Carlos Baquero, Marek Zawirski, 2011)
    public struct ORSet<Element: Codable & Hashable>: NamedDeltaCRDT, ORSetOperations {
        public typealias ORSetDelta = VersionedContainerDelta<Element>
        public typealias Delta = ORSetDelta

        public let replicaID: ReplicaID

        // State is a `VersionedContainer` which does most of the heavy-lifting, which includes tracking delta
        var state: VersionedContainer<Element>

        public var delta: Delta? {
            self.state.delta
        }

        // TODO: API naming, this is called "elements" which makes it sounds as if it was an iterator of elements...?
        public var elements: Set<Element> {
            self.state.elements
        }

        public var count: Int {
            self.state.count
        }

        public var isEmpty: Bool {
            self.state.isEmpty
        }

        /// Creates a pure datatype that can be manually managed (passed around, merged, serialized), without involvement of the actor runtime.
        public init(replicaID: ReplicaID) {
            self.replicaID = replicaID
            self.state = VersionedContainer(replicaID: replicaID)
        }

        public mutating func insert(_ element: Element) {
            // From [An optimized conflict-free replicated set](https://hal.inria.fr/file/index/docid/738680/filename/RR-8083.pdf)
            // on coalescing repeated adds: "for every combination of element and source replica, it is enough to keep
            // the identifier of the latest add, which subsumes previously added elements"

            // The paper suggests we coalesce repeated adds of an element within this replica only, but since
            // `VersionedContainer` keeps track of causal history, we know the globally unique version (i.e., the birth
            // dot) created for this add dominates all previous ones, even if they occurred in other replicas, so it is
            // safe to call `remove(element)` here.

            // Keep only the latest add to reduce space.
            self.state.remove(element)
            self.state.add(element)
        }

        public mutating func remove(_ element: Element) {
            self.state.remove(element)
        }

        public mutating func removeAll() {
            self.state.removeAll()
        }

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

        public mutating func merge(other: ORSet<Element>) {
            self.state.merge(other: other.state)
            self.compact()
        }

        public mutating func mergeDelta(_ delta: Delta) {
            self.state.mergeDelta(delta)
            self.compact()
        }

        public func equalState(to other: StateBasedCRDT) -> Bool {
            guard let other = other as? Self else {
                return false
            }

            return self.state.equalState(to: other.state) // TODO: is this correct?
        }

        /// Similar space reduction as described in the `add` method.
        private mutating func compact() {
            if self.state.elementByBirthDot.count > 1 {
                // Sort birth dots in descending order. i.e., newest version to oldest version by replica
                let sortedBirthDots = self.state.elementByBirthDot.keys.sorted(by: >)
                var replica: ReplicaID = sortedBirthDots[0].replicaID
                var seenReplicaElements: Set<Element> = []

                // Birth dots of duplicate elements within a replica.
                // e.g., suppose `elementByBirthDot` contains [(A,1): 3, (A,2): 5, (A,3): 3], then (A,1) would be added
                // to this because it contains the same element (i.e., 3) as (A,3) and is older, so it can be deleted.
                var birthDotsToDelete: Set<VersionDot> = []

                for birthDot in sortedBirthDots.dropFirst() {
                    // Replica changed - reset
                    if replica != birthDot.replicaID {
                        replica = birthDot.replicaID
                        seenReplicaElements = []
                    }

                    if let element = self.state.elementByBirthDot[birthDot] {
                        // This is an older version within a replica containing duplicate element => delete
                        if seenReplicaElements.contains(element) {
                            birthDotsToDelete.insert(birthDot)
                        }
                        seenReplicaElements.insert(element)
                    }
                }

                self.state.remove(birthDotsToDelete)
            }
        }

        public mutating func resetDelta() {
            self.state.resetDelta()
        }

        public func contains(_ element: Element) -> Bool {
            self.state.elementByBirthDot.first { _, e in e == element } != nil
        }
    }
}

extension CRDT.ORSet: ResettableCRDT {
    public mutating func reset() {
        // Doing this instead of `init` to preserve causal history
        self.removeAll()
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT String Descriptions

extension CRDT.ORSet: CustomStringConvertible, CustomPrettyStringConvertible {
    public var description: String {
        "ORSet(\(self.elements))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned ORSet

public protocol ORSetOperations: CvRDT {
    associatedtype Element: Hashable

    var elements: Set<Element> { get }

    mutating func insert(_ element: Element)
    mutating func remove(_ element: Element)
    mutating func removeAll()
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Aliases

// TODO: find better home for these type aliases

typealias ObservedRemoveSet = CRDT.ORSet
