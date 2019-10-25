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
    /// is to ensure that updates are performed on the values so causal histories are preserved (if the CRDT keeps track
    /// of causal history). Allowing read-write would mean values can be replaced, which poses the risks of wiping
    /// causal history (e.g., if a value is replaced by a newly created instance).
    ///
    /// Be warned that `unsafeRemoveValue` (and similarly for `unsafeRemoveAllValues`) deletes a key-value and wipes the
    /// value's causal history in the current replica. If changes were made to the same entry (i.e., a stale version of
    /// the value) in other replica(s) *before* the deletion is propagated, then the entry would be re-added when those
    /// changes are merged to this replica because they are considered to be more recent.
    ///
    /// With that, if a value type has causal history embedded AND supports the "reset" operation
    /// (e.g., `CRDT.ORSet.removeAll`), it is important to note the difference between applying "reset" through
    /// `update` vs. `unsafeRemoveValue` then re-create. `unsafeRemoveValue` does NOT keep causal history and deletes
    /// the key-value from the ORMap, while update-reset keeps causal history but also retains the key-value entry
    /// (e.g., the value would be an empty set).
    ///
    /// Convenience methods `resetValue` and `resetAllValues` are provided for value types that conform to the
    /// `ResettableCRDT` protocol to save users from doing update-reset explicitly.
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
    /// - SeeAlso: `CRDT.ORSet`
    public struct ORMap<Key: Hashable, Value: CvRDT>: NamedDeltaCRDT, ORMapOperations {
        public typealias Delta = ORMapDelta<Key, Value>

        public let replicaId: ReplicaId

        /// Creates a new `Value` instance. e.g., zero counter, empty set, etc.
        /// The initializer should not close over mutable state as no strong guarantees are provided about
        /// which context it will execute on.
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

        public var underlying: [Key: Value] {
            return self._values
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

        /// Creates a new "zero" value using `valueInitializer` if the given `key` has no value, and passes this
        /// zero value to the `mutator`. Otherwise the value present for the `key` is passed in.
        public mutating func update(key: Key, mutator: (inout Value) -> Void) {
            // Always add `key` to `_keys` set to track its causal history
            self._keys.add(key)

            // Apply `mutator` to the value then save it to state. Create `Value` if needed.
            var value = self._values[key] ?? self.valueInitializer()
            mutator(&value)
            self._values[key] = value

            // Update delta
            self.updatedValues[key] = value
        }

        /// Removes `key` and the associated value from the `ORMap`.
        ///
        /// - ***Warning**: this erases the value's causal history and may cause anomalies!
        public mutating func unsafeRemoveValue(forKey key: Key) -> Value? {
            self._keys.remove(key)
            let result = self._values.removeValue(forKey: key)
            self.updatedValues.removeValue(forKey: key)
            return result
        }

        /// Removes all entries from the `ORMap`.
        ///
        /// - ***Warning**: this erases all of the values' causal histories and may cause anomalies!
        public mutating func unsafeRemoveAllValues() {
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
        }

        public mutating func mergeDelta(_ delta: Delta) {
            self._keys.mergeDelta(delta.keys)
            // Use the updated `_keys` to merge `_values` dictionaries.
            // Keys that no longer exist will have their values deleted as well.
            self._values.merge(keys: self._keys.elements, other: delta.values, valueInitializer: self.valueInitializer)
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

/// Convenience methods so users can call `resetValue` instead of "update-reset" for example.
extension CRDT.ORMap: ORMapWithResettableValue where Value: ResettableCRDT {
    public mutating func resetValue(forKey key: Key) {
        // Reset value if exists
        if var value = self._values[key] {
            // Always add `key` to `_keys` set to track its causal history
            self._keys.add(key)
            // Update state and delta
            value.reset()
            self._values[key] = value
            self.updatedValues[key] = value
        }
    }

    public mutating func resetAllValues() {
        self._values.keys.forEach { self.resetValue(forKey: $0) }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned ORMap

public protocol ORMapOperations {
    associatedtype Key: Hashable
    associatedtype Value: CvRDT

    var underlying: [Key: Value] { get }

    mutating func update(key: Key, mutator: (inout Value) -> Void)

    /// Removes `key` and the associated value from the `ORMap`.
    ///
    /// - ***Warning**: this erases the value's causal history and may cause anomalies!
    mutating func unsafeRemoveValue(forKey key: Key) -> Value?

    /// Removes all entries from the `ORMap`.
    ///
    /// - ***Warning**: this erases all of the values' causal histories and may cause anomalies!
    mutating func unsafeRemoveAllValues()
}

public protocol ORMapWithResettableValue: ORMapOperations where Value: ResettableCRDT {
    mutating func resetValue(forKey key: Key)

    mutating func resetAllValues()
}

// See comments in CRDT.ORSet
extension CRDT.ActorOwned where DataType: ORMapOperations {
    public var lastObservedValue: [DataType.Key: DataType.Value] {
        return self.data.underlying
    }

    public func update(key: DataType.Key, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount, mutator: (inout DataType.Value) -> Void) -> OperationResult<DataType> {
        // Apply mutator to the value associated with `key` locally then propagate
        self.data.update(key: key, mutator: mutator)
        return self.write(consistency: consistency, timeout: timeout)
    }

    /// Removes `key` and the associated value from the `ORMap`. Must achieve the given `writeConsistency` within
    /// `timeout` to be considered successful.
    ///
    /// - ***Warning**: This might cause anomalies! See `CRDT.ORMap` documentation for more details.
    public func unsafeRemoveValue(forKey key: DataType.Key, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
        // Remove value associated with the given key locally then propagate
        _ = self.data.unsafeRemoveValue(forKey: key)
        return self.write(consistency: consistency, timeout: timeout)
    }

    /// Removes all entries from the `ORMap`. Must achieve the given `writeConsistency` within `timeout` to be
    /// considered successful.
    ///
    /// - ***Warning**: This might cause anomalies! See `CRDT.ORMap` documentation for more details.
    public func unsafeRemoveAllValues(writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
        // Remove all values locally then propagate
        self.data.unsafeRemoveAllValues()
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.ActorOwned where DataType: ORMapWithResettableValue {
    public func resetValue(forKey key: DataType.Key, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
        // Reset value associated with the given key locally then propagate
        self.data.resetValue(forKey: key)
        return self.write(consistency: consistency, timeout: timeout)
    }

    public func resetAllValues(writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
        // Reset all values locally then propagate
        self.data.resetAllValues()
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.ORMap {
    public static func owned<Message>(by owner: ActorContext<Message>, id: String, valueInitializer: @escaping () -> Value) -> CRDT.ActorOwned<CRDT.ORMap<Key, Value>> {
        return CRDT.ActorOwned<CRDT.ORMap>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.ORMap<Key, Value>(replicaId: .actorAddress(owner.address), valueInitializer: valueInitializer))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Aliases

// TODO: find better home for these type aliases

typealias ObservedRemoveMap = CRDT.ORMap
