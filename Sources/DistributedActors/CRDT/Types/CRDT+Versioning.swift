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
// MARK: VersionContext

// Version vectors might pose problems depending on how they are used. Dotted version vectors (DVV) are augmented version
// vectors aimed to overcome those problems and are capable of representing causal histories that are otherwise not possible
// with version vectors. See:
//   - [Dotted Version Vectors: Logical Clocks for Optimistic Replication](https://arxiv.org/pdf/1011.5808.pdf)
//   - [Dotted Version Vectors: Efficient Causality Tracking for Distributed Key-Value Stores](http://gsd.di.uminho.pt/members/vff/dotted-version-vectors-2012.pdf)
//
// As an example, given causal history {a1, a2, a3, b1, b2, c1, c2, c4}
//  - Cannot be represented by a version vector because c4 is not contiguous.
//  - Dotted version vector: {(c,4), {(a,3), (b,2), (c,2)}}, where (c,4) is the "dot".
//
// In the papers listed above a dotted version vector is defined to have only a single dot, and Riak implemented it so (https://github.com/basho/riak_core/blob/develop-3.0/src/dvvset.erl).
// (DVVSet is an improved implementation of DVV. See https://github.com/ricardobcl/Dotted-Version-Vectors)
//
// Akka's CRDTs and Bartosz Sypytkowski's work (https://github.com/Horusiath/crdt-examples, https://bartoszsypytkowski.com/optimizing-state-based-crdts-part-2/)
// are similar to one another. Different from Riak, which uses DVV (i.e., a single dot with a version vector), they both
// use multiple dots with a version vector instead--a notion that we will follow here.

extension CRDT {
    /// `VersionContext`'s internal structure is very similar to dotted version vector. The difference is that it keeps
    /// track of a set of dots rather than just one.
    ///
    /// Inspired by Bartosz Sypytkowski's [`DotContext`](https://github.com/Horusiath/crdt-examples/blob/master/convergent/delta/context.fsx).
    ///
    /// - SeeAlso: [Optimizing state-based CRDTs (part 2)](https://bartoszsypytkowski.com/optimizing-state-based-crdts-part-2/)
    public struct VersionContext: CvRDT {
        // Contiguous causal past
        internal var vv: VersionVector

        // Discrete events ("gaps") that do not fit in `vv`
        internal var gaps: Set<VersionDot>

        public init(vv: VersionVector = VersionVector(), gaps: Set<VersionDot> = []) {
            self.vv = vv
            self.gaps = gaps
        }

        /// Add dot to this `VersionContext`.
        ///
        /// - Parameter dot: The `Dot` to add.
        mutating func add(_ dot: VersionDot) {
            self.gaps.insert(dot)
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

        /// Merge another `VersionContext` into this. This `VersionContext` is mutated while `other` is not.
        ///
        /// - Parameter other: The `VersionContext` to merge.
        public mutating func merge(other: VersionContext) {
            self.vv.merge(other: other.vv)
            self.gaps.formUnion(other.gaps)
        }

        /// Check if any of the dots in `gaps` have become part of `vv` and as a result can be removed.
        ///
        /// This should be called after `gaps` is updated to reduce memory footprint.
        public mutating func compact() {
            // Sort dots by replica then by version in ascending order. We need this ordering to check for continuity.
            for dot in self.gaps.sorted() {
                if dot.version == self.vv[dot.replicaID] + 1 {
                    // If the dot's version follows replica's version in `vv`, it is no longer detached and can be added to `vv`.
                    self.vv.increment(at: dot.replicaID)
                    self.gaps.remove(dot)
                } else if self.vv.contains(dot.replicaID, dot.version) {
                    // The dot is covered by `vv` already. Remove.
                    self.gaps.remove(dot)
                }
                // Else the dot is still detached and remains in `gaps`
            }
        }

        /// For a `VersionContext` to contain a dot means that the corresponding event has been acknowledged or observed.
        /// It requires either 1) the dot is covered by `vv` or 2) the dot is in `gaps`.
        ///
        /// Dots that are NOT contained in `VersionContext` are important because they are likely changes that have not
        /// been processed yet.
        public func contains(_ dot: VersionDot) -> Bool {
            self.vv.contains(dot.replicaID, dot.version) || self.gaps.contains(dot)
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: VersionedContainer

extension CRDT {
    /// Inspired by Bartosz Sypytkowski's [`DotKernel`](https://github.com/Horusiath/crdt-examples/blob/master/convergent/delta/kernel.fsx),
    /// `VersionedContainer` can be used as a building block for optimized `ORSet`, `MVRegister`, etc.
    ///
    /// The concept of "birth dot" (i.e., (replica, version) tuple) is described in Akka's
    /// [`ORSet` documentation](https://github.com/akka/akka/blob/master/akka-distributed-data/src/main/scala/akka/cluster/ddata/ORSet.scala).
    ///
    /// The optimization implemented by Akka and Sypytkowski is based on [An optimized conflict-free replicated set](https://hal.inria.fr/file/index/docid/738680/filename/RR-8083.pdf).
    /// In essence, the addition of a (replica, version, element) tuple always happens before its removal (i.e., you cannot
    /// delete without adding first), so there is no need to store tombstones. Conflict can be resolved by analyzing
    /// `VersionContext`, which contains version vector, and birth dot (see `merge` method for details).
    ///
    /// Important: Each replica must be associated with a single `VersionedContainer` instance only to ensure version is incremented properly.
    ///
    /// - SeeAlso: [Optimizing state-based CRDTs (part 2)](https://bartoszsypytkowski.com/optimizing-state-based-crdts-part-2/)
    public struct VersionedContainer<Element: Codable & Hashable>: NamedDeltaCRDT {
        public typealias Delta = VersionedContainerDelta<Element>

        public let replicaID: ReplicaID

        // Version context of the container
        internal var versionContext: VersionContext

        // Birth dots and their associated elements. This dictionary contains active elements only (i.e., not removed).
        // Keys are birth dots because they are globally unique and an element may have multiple birth dots if added
        // repeatedly. Using elements as keys instead might lead to lost dots and consequently broken causal history.
        typealias VersionDottedElements = [VersionDot: Element]
        internal var elementByBirthDot: VersionDottedElements

        public var delta: Delta?

        public var elements: Set<Element> {
            Set(self.elementByBirthDot.values)
        }

        public var count: Int {
            self.elements.count
        }

        public var isEmpty: Bool {
            self.elementByBirthDot.isEmpty
        }

        public init(replicaID: ReplicaID, versionContext: VersionContext = VersionContext(), elementByBirthDot: [VersionDot: Element] = [:]) {
            self.replicaID = replicaID
            self.versionContext = versionContext
            self.elementByBirthDot = elementByBirthDot
        }

        public mutating func add(_ element: Element) {
            // The assumption here is that a replica is always up-to-date with its updates (i.e., `versionContext.gaps`
            // should not contain dots for the current replica), so we can generate next dot using `versionContext.vv` only.
            precondition(
                self.versionContext.gaps.filter { dot in
                    dot.replicaID == self.replicaID
                }.isEmpty,
                "There must not be gaps in replica \(self.replicaID)'s version context"
            )

            // Increment version vector and create a birth dot with the new version
            let nextVersion = self.versionContext.vv.increment(at: self.replicaID)
            let birthDot = VersionDot(self.replicaID, nextVersion)
            // An element may have multiple birth dots if added multiple times
            self.elementByBirthDot[birthDot] = element

            // Prepare to update delta
            if self.delta == nil {
                self.delta = Delta()
            }
            // Unless birth dot's version is 1 and version context is empty (i.e., version 0), the birth dot
            // will stay in `versionContext.gaps` and cannot be added to `vv` because it is not contiguous.
            self.delta?.versionContext.add(birthDot)
            self.delta?.versionContext.compact()
            self.delta?.elementByBirthDot[birthDot] = element
        }

        public mutating func remove(_ element: Element) {
            // Find all birth dots associated with the given element
            let birthDots = self.elementByBirthDot.filter { _, e in e == element }
                .map { birthDot, _ in birthDot }

            self.remove(Set(birthDots))
        }

        internal mutating func remove(_ birthDots: Set<VersionDot>) {
            // Prepare to update delta
            if self.delta == nil {
                self.delta = Delta()
            }

            // Remove all the (birth dot, element) entries. No tombstone.
            for birthDot in birthDots {
                self.elementByBirthDot.removeValue(forKey: birthDot)

                self.delta?.elementByBirthDot.removeValue(forKey: birthDot)
                // Add the deleted element's birth dot to delta's `versionContext`.
                // We are not adding element to delta's `elementByBirthDot`!!!
                // Why? Keep in mind that delete is acknowledged by version being present in `versionContext` but the
                // element is not found in `elementByBirthDot`.
                // To understand that take a look at `merge` method. When delta reaches another replica:
                //   If the other replica has the birth dot in its `elementByBirthDot` but delta does not, it will
                //   compare the birth dot against delta's `versionContext`. If delta has a more recent version,
                //   then the other replica will delete the (birth dot, element) entry.
                self.delta?.versionContext.add(birthDot)
            }

            self.delta?.versionContext.compact()
        }

        public mutating func removeAll() {
            // Prepare to update delta
            if self.delta == nil {
                self.delta = Delta()
            }

            // Delete entries from `elementByBirthDot` and add all birth dots to delta to remember the delete.
            // See comment in the `remove` method for more details.
            self.delta?.elementByBirthDot = [:]
            for (birthDot, _) in self.elementByBirthDot {
                self.delta?.versionContext.add(birthDot)
            }
            self.delta?.versionContext.compact()

            // Remove all elements but keep `versionContext`
            self.elementByBirthDot = [:]
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

        public mutating func merge(other: VersionedContainer<Element>) {
            let merged = VersionContextAndElements(self.versionContext, self.elementByBirthDot)
                .merging(other: VersionContextAndElements(other.versionContext, other.elementByBirthDot))
            self.versionContext = merged.versionContext
            self.elementByBirthDot = merged.elementByBirthDot
        }

        public mutating func mergeDelta(_ delta: Delta) {
            let merged = VersionContextAndElements(self.versionContext, self.elementByBirthDot)
                .merging(other: VersionContextAndElements(delta.versionContext, delta.elementByBirthDot))
            self.versionContext = merged.versionContext
            self.elementByBirthDot = merged.elementByBirthDot
        }

        public mutating func resetDelta() {
            self.delta = nil
        }
    }

    public struct VersionedContainerDelta<Element: Codable & Hashable>: CvRDT {
        // Version context of the delta, containing new versions/dots associated with updates captured in this delta.
        internal var versionContext: VersionContext = VersionContext()

        // Birth dots and their associated elements. This dictionary contains active elements only (i.e., not removed).
        internal var elementByBirthDot: [VersionDot: Element] = [:]

        public var elements: Set<Element> {
            Set(self.elementByBirthDot.values)
        }

        init() {}

        public mutating func _tryMerge(other: StateBasedCRDT) -> CRDT.MergeError? {
            let OtherType = type(of: other as Any)
            if let wellTypedOther = other as? Self {
                self.merge(other: wellTypedOther)
                return nil
            } else {
                return CRDT.MergeError(storedType: Self.self, incomingType: OtherType)
            }
        }

        public mutating func merge(other: VersionedContainerDelta) {
            let merged = VersionContextAndElements(self.versionContext, self.elementByBirthDot)
                .merging(other: VersionContextAndElements(other.versionContext, other.elementByBirthDot))
            self.versionContext = merged.versionContext
            self.elementByBirthDot = merged.elementByBirthDot
        }
    }
}

extension CRDT {
    /// Factor out logic for reuse when merging two `VersionedContainer` or `VersionedContainerDelta` instances, or
    /// when merging `VersionedContainerDelta` into `VersionedContainer`. This is not necessary if we are allowed
    /// to use `VersionedContainer` as the `Delta` type.
    internal struct VersionContextAndElements<Element: Hashable> {
        internal let versionContext: VersionContext
        internal let elementByBirthDot: [VersionDot: Element]

        init(_ versionContext: VersionContext, _ elementByBirthDot: [VersionDot: Element]) {
            self.versionContext = versionContext
            self.elementByBirthDot = elementByBirthDot
        }

        internal func merging(other: VersionContextAndElements<Element>) -> VersionContextAndElements<Element> {
            // When an element exists in replica A but not replica B, it could be either:
            //   1) A added it and B has not seen that yet
            //   2) B removed it and A has not seen that yet
            // We compare the element's birth dot to the `versionContext` in the replica that the element is absent
            // from. If the dot is covered by `versionContext`, it means the element was removed recently (2).
            // Otherwise, the element was added recently (1).

            var mergedElementByBirthDot = self.elementByBirthDot

            // `self` does not have birth dot and `self`'s `versionContext` does NOT dominate birth dot => element added (1)
            let toAdd = other.elementByBirthDot.filter { birthDot, _ in
                self.elementByBirthDot[birthDot] == nil && !self.versionContext.contains(birthDot)
            }
            mergedElementByBirthDot.merge(toAdd) { _, new in new }

            // `self` has birth dot but `other`'s `versionContext` dominates birth dot => element removed (2)
            let toDelete = self.elementByBirthDot.filter { birthDot, _ in
                other.elementByBirthDot[birthDot] == nil && other.versionContext.contains(birthDot)
            }
            toDelete.forEach { birthDot, _ in mergedElementByBirthDot.removeValue(forKey: birthDot) }

            // Else the birth dot is in both `self` and `other`

            // `VersionContext` is CRDT
            var versionContext = self.versionContext.merging(other: other.versionContext)
            versionContext.compact()

            return VersionContextAndElements(versionContext, mergedElementByBirthDot)
        }
    }
}
