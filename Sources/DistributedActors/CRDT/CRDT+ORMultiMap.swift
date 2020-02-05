//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift Distributed Actors project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Distributed Actors project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ORMultiMap as pure CRDT

extension CRDT {
    /// ORMultiMap is a specialized ORMap in which a key can have multiple values, stored in an `ORSet`.
    ///
    /// - SeeAlso: Akka's [`ORMultiMap`](https://github.com/akka/akka/blob/master/akka-distributed-data/src/main/scala/akka/cluster/ddata/ORMultiMap.scala)
    /// - SeeAlso: `CRDT.ORMap`
    /// - SeeAlso: `CRDT.ORSet`
    public struct ORMultiMap<Key: Hashable, Value: Hashable>: NamedDeltaCRDT, ORMultiMapOperations {
        public typealias Delta = ORMapDelta<Key, ORSet<Value>>

        public let replicaId: ReplicaId

        /// Underlying ORMap for storing pairs of key and its set of values and managing causal history and delta
        var state: ORMap<Key, ORSet<Value>>

        public var delta: Delta? {
            self.state.delta
        }

        public var underlying: [Key: Set<Value>] {
            self.state._values.mapValues { $0.elements }
        }

        public var keys: Dictionary<Key, Set<Value>>.Keys {
            self.underlying.keys
        }

        public var values: Dictionary<Key, Set<Value>>.Values {
            self.underlying.values
        }

        public var count: Int {
            self.state.count
        }

        public var isEmpty: Bool {
            self.state.isEmpty
        }

        init(replicaId: ReplicaId) {
            self.replicaId = replicaId
            self.state = .init(replicaId: replicaId) {
                ORSet<Value>(replicaId: replicaId)
            }
        }

        /// Gets the set of values, if any, associated with `key`.
        ///
        /// The subscript is *read-only*--this is to ensure that values cannot be set to `nil` by mistake which would
        /// erase causal histories.
        public subscript(key: Key) -> Set<Value>? {
            self.state[key]?.elements
        }

        /// Adds `value` for `key`.
        public mutating func add(forKey key: Key, _ value: Value) {
            self.state.update(key: key) { set in
                set.add(value)
            }
        }

        /// Removes `value` for `key`.
        public mutating func remove(forKey key: Key, _ value: Value) {
            self.state.update(key: key) { set in
                set.remove(value)
            }
        }

        /// Removes all values for `key`.
        public mutating func removeAll(forKey key: Key) {
            self.state.update(key: key) { set in
                set.removeAll()
            }
        }

        /// Removes `key` and the associated value set from the `ORMultiMap`.
        ///
        /// - ***Warning**: this erases the value's causal history and may cause anomalies!
        public mutating func unsafeRemoveValue(forKey key: Key) -> Set<Value>? {
            self.state.unsafeRemoveValue(forKey: key)?.elements
        }

        /// Removes all entries from the `ORMultiMap`.
        ///
        /// - ***Warning**: this erases all of the values' causal histories and may cause anomalies!
        public mutating func unsafeRemoveAllValues() {
            self.state.unsafeRemoveAllValues()
        }

        public mutating func merge(other: ORMultiMap<Key, Value>) {
            self.state.merge(other: other.state)
        }

        public mutating func mergeDelta(_ delta: Delta) {
            self.state.mergeDelta(delta)
        }

        public mutating func resetDelta() {
            self.state.resetDelta()
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned ORMultiMap

public protocol ORMultiMapOperations {
    associatedtype Key: Hashable
    associatedtype Value: Hashable

    var underlying: [Key: Set<Value>] { get }

    subscript(key: Key) -> Set<Value>? { get }
    mutating func add(forKey key: Key, _ value: Value)
    mutating func remove(forKey key: Key, _ value: Value)
    mutating func removeAll(forKey key: Key)

    mutating func unsafeRemoveValue(forKey key: Key) -> Set<Value>?
    mutating func unsafeRemoveAllValues()
}

// See comments in CRDT.ORSet
extension CRDT.ActorOwned where DataType: ORMultiMapOperations {
    public var lastObservedValue: [DataType.Key: Set<DataType.Value>] {
        self.data.underlying
    }

    public func add(forKey key: DataType.Key, value: DataType.Value, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
        self.data.add(forKey: key, value)
        return self.write(consistency: consistency, timeout: timeout)
    }

    public func remove(forKey key: DataType.Key, value: DataType.Value, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
        self.data.remove(forKey: key, value)
        return self.write(consistency: consistency, timeout: timeout)
    }

    public func removeAll(forKey key: DataType.Key, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
        self.data.removeAll(forKey: key)
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.ORMultiMap {
    public static func owned<Message>(by owner: ActorContext<Message>, id: String) -> CRDT.ActorOwned<CRDT.ORMultiMap<Key, Value>> {
        CRDT.ActorOwned<CRDT.ORMultiMap>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.ORMultiMap<Key, Value>(replicaId: .actorAddress(owner.address)))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Aliases

// TODO: find better home for these type aliases

typealias ObservedRemoveMultiMap = CRDT.ORMultiMap
