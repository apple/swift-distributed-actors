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
    public struct ORMultiMap<Key: Codable & Hashable, Value: Codable & Hashable>: NamedDeltaCRDT, ORMultiMapOperations {
        public typealias Delta = ORMapDelta<Key, ORSet<Value>>

        public let replicaID: ReplicaID

        /// Underlying ORMap for storing pairs of key and its set of values and managing causal history and delta
        internal var state: ORMap<Key, ORSet<Value>>

        public var delta: Delta? {
            self.state.delta
        }

        public var underlying: [Key: Set<Value>] {
            self.state._storage.mapValues { $0.elements }
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

        init(replicaID: ReplicaID) {
            self.replicaID = replicaID
            self.state = .init(replicaID: replicaID, defaultValue: ORSet<Value>(replicaID: replicaID))
        }

        /// Gets the set of values, if any, associated with `key`.
        ///
        /// The subscript is *read-only*--this is to ensure that values cannot be set to `nil` by mistake which would
        /// erase causal histories.
        public subscript(key: Key) -> Set<Value>? {
            self.state[key]?.elements
        }

        public mutating func add(forKey key: Key, _ value: Value) {
            self.state.update(key: key) { set in
                set.insert(value)
            }
        }

        public mutating func remove(forKey key: Key, _ value: Value) {
            self.state.update(key: key) { set in
                set.remove(value)
            }
        }

        public mutating func removeAll(forKey key: Key) {
            self.state.update(key: key) { set in
                set.removeAll()
            }
        }

        public mutating func unsafeRemoveValue(forKey key: Key) -> Set<Value>? {
            self.state.unsafeRemoveValue(forKey: key)?.elements
        }

        public mutating func unsafeRemoveAllValues() {
            self.state.unsafeRemoveAllValues()
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

        public mutating func merge(other: ORMultiMap<Key, Value>) {
            self.state.merge(other: other.state)
        }

        public mutating func mergeDelta(_ delta: Delta) {
            self.state.mergeDelta(delta)
        }

        public mutating func resetDelta() {
            self.state.resetDelta()
        }

        public func equalState(to other: StateBasedCRDT) -> Bool {
            guard let other = other as? Self else {
                return false
            }

            return self.state.equalState(to: other.state)
        }

    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned ORMultiMap

public protocol ORMultiMapOperations {
    associatedtype Key: Hashable
    associatedtype Value: Hashable

    var underlying: [Key: Set<Value>] { get }

    /// Adds `value` for `key`.
    mutating func add(forKey key: Key, _ value: Value)
    /// Removes `value` for `key`.
    mutating func remove(forKey key: Key, _ value: Value)
    /// Removes all values for `key`.
    mutating func removeAll(forKey key: Key)

    /// Removes `key` and the associated value set from the `ORMultiMap`.
    ///
    /// - ***Warning**: this erases the value's causal history and may cause anomalies!
    mutating func unsafeRemoveValue(forKey key: Key) -> Set<Value>?

    /// Removes all entries from the `ORMultiMap`.
    ///
    /// - ***Warning**: this erases all of the values' causal histories and may cause anomalies!
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
    public static func makeOwned<Message>(by owner: ActorContext<Message>, id: String) -> CRDT.ActorOwned<CRDT.ORMultiMap<Key, Value>> {
        let ownerAddress = owner.address.ensuringNode(owner.system.settings.cluster.uniqueBindNode)
        return CRDT.ActorOwned<CRDT.ORMultiMap>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.ORMultiMap<Key, Value>(replicaID: .actorAddress(ownerAddress)))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: CRDT String Descriptions

extension CRDT.ORMultiMap: CustomStringConvertible, CustomPrettyStringConvertible {
    public var description: String {
        "\(Self.self)(\(self.underlying))"
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Aliases

// TODO: find better home for these type aliases

typealias ObservedRemoveMultiMap = CRDT.ORMultiMap
