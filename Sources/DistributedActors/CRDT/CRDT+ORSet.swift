//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2019 Apple Inc. and the Swift Distributed Actors project authors
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
    /// - SeeAlso: [An optimized conflict-free replicated set](https://hal.inria.fr/file/index/docid/738680/filename/RR-8083.pdf)
    /// - SeeAlso: [Optimizing state-based CRDTs (part 2)](https://bartoszsypytkowski.com/optimizing-state-based-crdts-part-2/)
    /// - SeeAlso: [A comprehensive study of CRDTs](https://hal.inria.fr/file/index/docid/555588/filename/techreport.pdf)
    public struct ORSet<Element: Hashable>: NamedDeltaCRDT, ORSetOperations {
        public typealias ORSetDelta = VersionedContainer<Element>.Delta
        public typealias Delta = ORSetDelta

        public let replicaId: ReplicaId

        // State is a `VersionedContainer` which does most of the heavy-lifting, which includes tracking delta
        var state: VersionedContainer<Element>

        public var delta: Delta? {
            return self.state.delta
        }

        public var elements: Set<Element> {
            return self.state.elements
        }

        public var count: Int {
            return self.state.count
        }

        public var isEmpty: Bool {
            return self.state.isEmpty
        }

        init(replicaId: ReplicaId) {
            self.replicaId = replicaId
            self.state = VersionedContainer(replicaId: replicaId)
        }

        public mutating func add(_ element: Element) {
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

        public mutating func merge(other: ORSet<Element>) {
            self.state.merge(other: other.state)
            self.compact()
            self.resetDelta()
        }

        public mutating func mergeDelta(_ delta: Delta) {
            self.state.mergeDelta(delta)
            self.compact()
            self.resetDelta()
        }

        /// Similar space reduction as described in the `add` method.
        private mutating func compact() {
            if self.state.elementByBirthDot.count > 1 {
                // Sort birth dots in descending order. i.e., newest version to oldest version by replica
                let sortedBirthDots = self.state.elementByBirthDot.keys.sorted(by: >)
                var replica: ReplicaId = sortedBirthDots[0].replicaId
                var seenReplicaElements: Set<Element> = []

                // Birth dots of duplicate elements within a replica.
                // e.g., suppose `elementByBirthDot` contains [(A,1): 3, (A,2): 5, (A,3): 3], then (A,1) would be added
                // to this because it contains the same element (i.e., 3) as (A,3) and is older, so it can be deleted.
                var birthDotsToDelete: Set<Dot<ReplicaId>> = []

                for birthDot in sortedBirthDots.dropFirst() {
                    // Replica changed - reset
                    if replica != birthDot.replicaId {
                        replica = birthDot.replicaId
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
            return self.state.elementByBirthDot.first { _, e in e == element } != nil
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned ORSet

public protocol ORSetOperations {
    associatedtype Element: Hashable

    var elements: Set<Element> { get }

    mutating func add(_ element: Element)
    mutating func remove(_ element: Element)
}

// `CRDT.ORSet` is a generic type and we are not allowed to have `extension CRDT.ActorOwned where DataType == ORSet`. As
// a result we introduce the `ORSetOperations` in order to bind `Element`. A workaround would be to add generic parameter
// to each method:
//
//     extension CRDT.ActorOwned {
//         public func add<Element: Hashable>(_ element: Element, ...) -> Result<DataType> where DataType == CRDT.ORSet<Element> { ... }
//     }
//
// But this does not work for `lastObservedValue`, which is a computed property.
extension CRDT.ActorOwned where DataType: ORSetOperations {
    public var lastObservedValue: Set<DataType.Element> {
        return self.data.elements
    }

    public func add(_ element: DataType.Element, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
        // Add element locally then propagate
        self.data.add(element)
        return self.write(consistency: consistency, timeout: timeout)
    }

    public func remove(_ element: DataType.Element, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
        // Remove element locally then propagate
        self.data.remove(element)
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.ORSet {
    public static func owned<Message>(by owner: ActorContext<Message>, id: String) -> CRDT.ActorOwned<CRDT.ORSet<Element>> {
        return CRDT.ActorOwned<CRDT.ORSet>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.ORSet<Element>(replicaId: .actorAddress(owner.address)))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Aliases

// TODO: find better home for these type aliases

typealias ObservedRemoveSet = CRDT.ORSet
