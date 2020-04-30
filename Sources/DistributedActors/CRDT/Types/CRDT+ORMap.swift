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
    public struct ORMap<Key: Codable & Hashable, Value: CvRDT>: NamedDeltaCRDT, ORMapOperations {
        public typealias Delta = ORMapDelta<Key, Value>

        public let replicaID: ReplicaID

        /// We allow `defaultValue` to be `nil` when we reconstruct `ORMap` from a remote message,
        /// but it **is** required in the initializer to ensure that **local** `ORMap` has `defaultValue`
        /// for `merge`, `update`, etc. In those methods `defaultValue` is required in case **local**
        /// `ORMap` does not have an existing value for the given `key`.
        let defaultValue: Value?

        /// ORSet to maintain causal history of the keys only; values keep their own causal history (if applicable).
        /// This is for tracking key additions and removals.
        var _keys: ORSet<Key>
        /// The underlying dictionary of key-value pairs.
        var _values: [Key: Value]
        /// A dictionary containing key-value pairs that have been updated since last `delta` reset.
        var updatedValues: [Key: Value] = [:]

        // `delta` is computed based on `_keys`, which should be mutated for all updates.
        public var delta: Delta? {
            // `_keys` should always be mutated whenever `self` is modified in any way.
            if let keysDelta = self._keys.delta {
                return ORMapDelta(keys: keysDelta, values: self.updatedValues, defaultValue: self.defaultValue)
            }
            // If `_keys` has not been mutated then assume `self` has not been modified either.
            return nil
        }

        public var underlying: [Key: Value] {
            self._values
        }

        public var keys: Dictionary<Key, Value>.Keys {
            self._values.keys
        }

        public var values: Dictionary<Key, Value>.Values {
            self._values.values
        }

        public var count: Int {
            self._values.count
        }

        public var isEmpty: Bool {
            self._values.isEmpty
        }

        init(replicaID: ReplicaID, defaultValue: Value) {
            self.replicaID = replicaID
            self.defaultValue = defaultValue
            self._keys = ORSet(replicaID: replicaID)
            self._values = [:]
        }

        public mutating func update(key: Key, mutator: (inout Value) -> Void) {
            guard let defaultValue = self.defaultValue else {
                preconditionFailure("'defaultValue' is not set. This is a bug. Please report.")
            }

            // Always add `key` to `_keys` set to track its causal history
            self._keys.add(key)

            // Apply `mutator` to the value then save it to state. Create `Value` if needed.
            var value = self._values[key] ?? defaultValue
            mutator(&value)
            self._values[key] = value

            // Update delta
            self.updatedValues[key] = value
        }

        public mutating func unsafeRemoveValue(forKey key: Key) -> Value? {
            self._keys.remove(key)
            let result = self._values.removeValue(forKey: key)
            self.updatedValues.removeValue(forKey: key)
            return result
        }

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
            self._values[key]
        }

        public mutating func _tryMerge(other: StateBasedCRDT) -> CRDT.MergeError? {
            let OtherType = type(of: other as Any)
            guard let wellTypedOther = other as? Self else {
                return CRDT.MergeError(storedType: Self.self, incomingType: OtherType)
            }

            // TODO: check if delta merge or normal
            // TODO: what if we simplify and compute deltas...?

            self.merge(other: wellTypedOther)
            return nil
        }

        public mutating func merge(other: ORMap<Key, Value>) {
            guard let defaultValue = self.defaultValue else {
                preconditionFailure("'defaultValue' is not set. This is a bug. Please report.")
            }

            self._keys.merge(other: other._keys)
            // Use the updated `_keys` to merge `_values` dictionaries.
            // Keys that no longer exist will have their values deleted as well.
            self._values.merge(keys: self._keys.elements, other: other._values, defaultValue: defaultValue)
        }

        public mutating func mergeDelta(_ delta: Delta) {
            guard let defaultValue = self.defaultValue else {
                preconditionFailure("'defaultValue' is not set. This is a bug. Please report.")
            }

            self._keys.mergeDelta(delta.keys)
            // Use the updated `_keys` to merge `_values` dictionaries.
            // Keys that no longer exist will have their values deleted as well.
            self._values.merge(keys: self._keys.elements, other: delta.values, defaultValue: defaultValue)
        }

        public mutating func resetDelta() {
            self._keys.resetDelta()
            self.updatedValues.removeAll()
        }
    }

    public struct ORMapDelta<Key: Codable & Hashable, Value: CvRDT>: CvRDT {
        var keys: ORSet<Key>.Delta
        // TODO: potential optimization: send only the delta if Value is DeltaCRDT. i.e., instead of Value here we would use Value.Delta
        // TODO: `merge` defined in the Dictionary extension below should use `mergeDelta` when Value is DeltaCRDT
        var values: [Key: Value]

        // See comment in `ORMap` on why this is optional
        let defaultValue: Value?

        init(keys: ORSet<Key>.Delta, values: [Key: Value], defaultValue: Value?) {
            self.keys = keys
            self.values = values
            self.defaultValue = defaultValue
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

        public mutating func merge(other: ORMapDelta<Key, Value>) {
            guard let defaultValue = self.defaultValue else {
                preconditionFailure("Unable to merge [\(self)] with [\(other)] as 'defaultValue' is not set. This is a bug. Please report.")
            }

            // Merge `keys` first--keys that have been deleted will be gone
            self.keys.merge(other: other.keys)
            // Use the updated `keys` to merge `values` dictionaries.
            // Keys that no longer exist will have their values deleted as well.
            self.values.merge(keys: self.keys.elements, other: other.values, defaultValue: defaultValue)
        }
    }
}

extension Dictionary where Key: Hashable, Value: CvRDT {
    internal mutating func merge(keys: Set<Key>, other: [Key: Value], defaultValue: Value) {
        // Remove from `self` and `other` keys that no longer exist
        self = self.filter { k, _ in keys.contains(k) }
        let other = other.filter { k, _ in keys.contains(k) }

        // Merge `other` into `self`
        for (k, rv) in other {
            // If `k` is not found in `self` then create a new `Value` instance.
            // We must NOT copy `other`'s value directly to `self` because the two should have different replica IDs.
            var lv: Value = self[k] ?? defaultValue
            lv.merge(other: rv)
            self[k] = lv
        }
    }
}

/// Convenience methods so users can call `resetValue` instead of "update-reset" for example.
extension CRDT.ORMap: ORMapWithResettableValue where Value: ResettableCRDT {
    /// Resets value for `key` if exists.
    public mutating func resetValue(forKey key: Key) {
        if var value = self._values[key] {
            // Always add `key` to `_keys` set to track its causal history
            self._keys.add(key)
            // Update state and delta
            value.reset()
            self._values[key] = value
            self.updatedValues[key] = value
        }
    }

    /// Resets all values in the `ORMap`.
    public mutating func resetAllValues() {
        self._values.keys.forEach { self.resetValue(forKey: $0) }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned - Common protocols and extensions for generic and specialized ORMap types (e.g., ORMap, LWWMap)

public protocol ORMapWithUnsafeRemove {
    associatedtype Key: Hashable
    associatedtype Value

    var underlying: [Key: Value] { get }

    /// Removes `key` and the associated value from the `ORMap`.
    ///
    /// - ***Warning**: this erases the value's causal history and may cause anomalies!
    mutating func unsafeRemoveValue(forKey key: Key) -> Value?

    /// Removes all entries from the `ORMap`.
    ///
    /// - ***Warning**: this erases all of the values' causal histories and may cause anomalies!
    mutating func unsafeRemoveAllValues()
}

/// Additional `ORMap` methods when `Value` type conforms to `ResettableCRDT`.
public protocol ORMapWithResettableValue: ORMapWithUnsafeRemove {
    /// Resets value for `key` by calling `ResettableCRDT.reset()`.
    mutating func resetValue(forKey key: Key)

    /// Resets all values in the `ORMap` by calling `ResettableCRDT.reset()`.
    mutating func resetAllValues()
}

extension CRDT.ActorOwned where DataType: ORMapWithUnsafeRemove {
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

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned ORMap

public protocol ORMapOperations: ORMapWithUnsafeRemove where Value: CvRDT {
    /// Creates a new "zero" value using `valueInitializer` if the given `key` has no value, and passes this
    /// zero value to the `mutator`. Otherwise the value present for the `key` is passed in.
    mutating func update(key: Key, mutator: (inout Value) -> Void)
}

// See comments in CRDT.ORSet
extension CRDT.ActorOwned where DataType: ORMapOperations {
    public var lastObservedValue: [DataType.Key: DataType.Value] {
        self.data.underlying
    }

    public func update(key: DataType.Key, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount, mutator: (inout DataType.Value) -> Void) -> OperationResult<DataType> {
        // Apply mutator to the value associated with `key` locally then propagate
        self.data.update(key: key, mutator: mutator)
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.ORMap {
    public static func owned<Message>(by owner: ActorContext<Message>, id: String, defaultValue: Value) -> CRDT.ActorOwned<CRDT.ORMap<Key, Value>> {
        CRDT.ActorOwned<CRDT.ORMap>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.ORMap<Key, Value>(replicaID: .actorAddress(owner.address), defaultValue: defaultValue))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Aliases

// TODO: find better home for these type aliases

typealias ObservedRemoveMap = CRDT.ORMap
