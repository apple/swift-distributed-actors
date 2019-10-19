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
// MARK: ORMap as pure CRDT

extension CRDT {
    /// An ORMap is similar to ORSet. In case of concurrent updates the values are merged, therefore they need to
    /// be CRDTs.
    ///
    /// Values are inserted or updated via `update`, using the provided `mutator`. The subscript is *read-only*--this
    /// is to ensure that updates are performed on the values so causal history is preserved (if the CRDT keeps track
    /// of causal history). Allowing read-write would mean values can be replaced, which poses the risks of wiping
    /// causal history (e.g., if a value is replaced by a newly created instance).
    ///
    /// Be warned that `removeValue` (and `removeAll`) deletes a key-value and wipes the value's causal history in
    /// the current replica. If changes were made to the same entry (i.e., a stale version of the value) in other
    /// replica(s) *before* the deletion is propagated, then the entry would be re-added when those changes are
    /// merged to this replica because they are considered to be more recent.
    ///
    /// With that, if a value type supports clear/emptying operation (e.g., `CRDT.ORSet.removeAll`), it is important
    /// to note the difference between applying it through `update` vs. `removeValue` then re-create. The latter does
    /// NOT keep causal history and deletes the key-value from the ORMap, while the former keeps causal history but
    /// also retains the key-value entry (e.g., the value would be an empty set).
    ///
    /// It is possible for an ORMap to contain different CRDT types as values, but for any given key the value type
    /// should remain the same, or perhaps more accurately, "mergeable". It is the user's responsibility to safe-guard
    /// against writing different value types for the same key.
    ///
    /// This implementation is partially based on the ORMap described in [Delta State Replicated Data Types](https://arxiv.org/pdf/1603.01529.pdf)
    /// and Akka's [`ORMap`](https://github.com/akka/akka/blob/master/akka-distributed-data/src/main/scala/akka/cluster/ddata/ORMap.scala).
    /// [Delta State Replicated Data Types](https://arxiv.org/pdf/1603.01529.pdf) proposes having a *global* causal
    /// context (similar to `CRDT.VersionContext`) shared across *all* values, and the design does not have the problem
    /// with re-introduced key-value mentioned above. We chose the simpler approach and note the pitfalls because not
    /// all supported CRDTs are causal (i.e., have `CRDT.VersionContext` embedded).
    ///
    /// - SeeAlso: [Delta State Replicated Data Types](https://arxiv.org/pdf/1603.01529.pdf)
    /// - SeeAlso: CRDT.ORSet
    public struct ORMap<Key: Hashable, Value: CvRDT>: NamedDeltaCRDT {
        public typealias Delta = ORMapDelta<Key, Value>

        public let replicaId: ReplicaId

        /// Creates a new `Value` instance.
        private let valueInitializer: () -> Value

        /// ORSet to maintain causal history of the keys only; values keep their own causal history (if applicable).
        /// This is for tracking key additions and removals.
        var _keys: ORSet<Key>
        /// The underlying dictionary of key-value pairs.
        var _values: [Key: Value]
        /// A dictionary containing key-value pairs that have been updated since last `delta` reset.
        var updatedValues: [Key: Value] = [:]

        /// `delta` is computed based on `_keys`, which should be mutated for all updates.
        public var delta: Delta? {
            // `_keys` should always be mutated whenever `self` is modified in any way.
            if let keysDelta = self._keys.delta {
                return ORMapDelta(keys: keysDelta, values: self.updatedValues, valueInitializer: self.valueInitializer)
            }
            // If `_keys` has not been mutated then assume `self` has not been modified either.
            return nil
        }

        public var keys: Dictionary<Key, Value>.Keys {
            return self._values.keys
        }

        public var values: Dictionary<Key, Value>.Values {
            return self._values.values
        }

        public var count: Int {
            return self._values.count
        }

        public var isEmpty: Bool {
            return self._values.isEmpty
        }

        init(replicaId: ReplicaId, valueInitializer: @escaping () -> Value) {
            self.replicaId = replicaId
            self.valueInitializer = valueInitializer
            self._keys = ORSet(replicaId: replicaId)
            self._values = [:]
        }

        /// Updates value for the given `key` in the `ORMap` by applying `mutator`. Creates a new `Value` with
        /// `self.valueInitializer` if it does not exist.
        public mutating func update(key: Key, mutator: (Value) -> Value) {
            // Always add `key` to `_keys` set to track its causal history
            self._keys.add(key)

            // Apply `mutator` to the value and save the result. Create `Value` if needed.
            let value = mutator(self._values[key] ?? self.valueInitializer())
            self._values[key] = value

            // Update delta
            self.updatedValues[key] = value
        }

        /// Removes `key` and the associated value from the `ORMap`.
        /// WARNING: this erases the value's causal history and may cause anomalies!
        public mutating func removeValue(forKey key: Key) -> Value? {
            self._keys.remove(key)
            let result = self._values.removeValue(forKey: key)
            self.updatedValues.removeValue(forKey: key)
            return result
        }

        /// Removes all entries for the `ORMap`.
        /// WARNING: this erases all of the values' causal history and may cause anomalies!
        public mutating func removeAll() {
            self._keys.removeAll()
            self._values.removeAll()
            self.updatedValues.removeAll()
        }

        /// Gets the value, if any, associated with `key`.
        ///
        /// The subscript is *read-only*--this is to ensure that updates are performed on the values so causal
        /// history is preserved.
        public subscript(key: Key) -> Value? {
            return self._values[key]
        }

        public mutating func merge(other: ORMap<Key, Value>) {
            self._keys.merge(other: other._keys)
            // Use the updated `_keys` to merge `_values` dictionaries.
            // Keys that no longer exist will have their values deleted as well.
            self._values.merge(keys: self._keys.elements, other: other._values, valueInitializer: self.valueInitializer)
            self.resetDelta()
        }

        public mutating func mergeDelta(_ delta: Delta) {
            self._keys.mergeDelta(delta.keys)
            // Use the updated `_keys` to merge `_values` dictionaries.
            // Keys that no longer exist will have their values deleted as well.
            self._values.merge(keys: self._keys.elements, other: delta.values, valueInitializer: self.valueInitializer)
            self.resetDelta()
        }

        public mutating func resetDelta() {
            self._keys.resetDelta()
            self.updatedValues.removeAll()
        }
    }

    public struct ORMapDelta<Key: Hashable, Value: CvRDT>: CvRDT {
        var keys: ORSet<Key>.Delta
        // TODO: potential optimization: send only the delta if Value is DeltaCRDT. i.e., instead of Value here we would use Value.Delta
        // TODO: `merge` defined in the Dictionary extension below should use `mergeDelta` when Value is DeltaCRDT
        var values: [Key: Value]

        private let valueInitializer: () -> Value

        init(keys: ORSet<Key>.Delta, values: [Key: Value], valueInitializer: @escaping () -> Value) {
            self.keys = keys
            self.values = values
            self.valueInitializer = valueInitializer
        }

        public mutating func merge(other: ORMapDelta<Key, Value>) {
            // Merge `keys` first--keys that have been deleted will be gone
            self.keys.merge(other: other.keys)
            // Use the updated `keys` to merge `values` dictionaries.
            // Keys that no longer exist will have their values deleted as well.
            self.values.merge(keys: self.keys.elements, other: other.values, valueInitializer: self.valueInitializer)
        }
    }
}

extension Dictionary where Key: Hashable, Value: CvRDT {
    internal mutating func merge(keys: Set<Key>, other: [Key: Value], valueInitializer: () -> Value) {
        // Remove from `self` and `other` keys that no longer exist
        self = self.filter { k, _ in keys.contains(k) }
        let other = other.filter { k, _ in keys.contains(k) }

        // Merge `other` into `self`
        for (k, rv) in other {
            // If `k` is not found in `self` then create a new `Value` instance.
            // We must NOT copy `other`'s value directly to `self` because the two should have different replica IDs.
            var lv: Value = self[k] ?? valueInitializer()
            lv.merge(other: rv)
            self[k] = lv
        }
    }
}
