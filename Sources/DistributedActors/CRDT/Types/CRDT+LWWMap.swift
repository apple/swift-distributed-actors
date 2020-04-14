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
// MARK: LWWMap as pure CRDT

extension CRDT {
    /// LWWMap, or last-writer-wins map, is a specialized ORMap in which values are automatically wrapped inside
    /// `LWWRegister`s. Unlike `ORMap`, there is no constraint on `Value` type.
    ///
    /// - SeeAlso: Akka's [`LWWMap`](https://github.com/akka/akka/blob/master/akka-distributed-data/src/main/scala/akka/cluster/ddata/LWWMap.scala)
    /// - SeeAlso: `CRDT.ORMap`
    /// - SeeAlso: `CRDT.LWWRegister`
    public struct LWWMap<Key: Codable & Hashable, Value: Codable>: NamedDeltaCRDT, LWWMapOperations {
        public typealias Delta = ORMapDelta<Key, LWWRegister<Value>>

        public let replicaId: ReplicaID

        /// Underlying ORMap for storing key-value entries and managing causal history and delta
        var state: ORMap<Key, LWWRegister<Value>>

        public var delta: Delta? {
            self.state.delta
        }

        public var underlying: [Key: Value] {
            self.state._values.mapValues { $0.value }
        }

        public var keys: Dictionary<Key, Value>.Keys {
            self.underlying.keys
        }

        public var values: Dictionary<Key, Value>.Values {
            self.underlying.values
        }

        public var count: Int {
            self.state.count
        }

        public var isEmpty: Bool {
            self.state.isEmpty
        }

        init(replicaId: ReplicaID, defaultValue: Value) {
            self.replicaId = replicaId
            self.state = .init(replicaId: replicaId) {
                // This is relevant only in `ORMap.merge`, when `key` exists in `other` but not `self` and therefore we
                // must create a "zero" value before merging `other` into it.
                // The "zero" value's timestamp must happen-before `other`'s to allow `other` to win. If we just
                // use the current time here `other` would never win.
                // We don't need to worry about the usage of this and timestamp being too new in `ORMap.update` because
                // a call to `LWWRegister.assign` immediately follows and the value is updated without comparing
                // timestamps.
                LWWRegister<Value>(replicaId: replicaId, initialValue: defaultValue, clock: .wallTime(WallTimeClock.zero))
            }
        }

        /// Gets the value, if any, associated with `key`.
        ///
        /// The subscript is *read-only*--this is to ensure that values cannot be set to `nil` by mistake which would
        /// erase causal histories.
        public subscript(key: Key) -> Value? {
            self.state[key]?.value
        }

        public mutating func set(forKey key: Key, value: Value) {
            self.state.update(key: key) { register in
                register.assign(value)
            }
        }

        public mutating func unsafeRemoveValue(forKey key: Key) -> Value? {
            self.state.unsafeRemoveValue(forKey: key)?.value
        }

        public mutating func unsafeRemoveAllValues() {
            self.state.unsafeRemoveAllValues()
        }

        public mutating func resetValue(forKey key: Key) {
            self.state.resetValue(forKey: key)
        }

        public mutating func resetAllValues() {
            self.state.resetAllValues()
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

        public mutating func merge(other: LWWMap<Key, Value>) {
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
// MARK: ActorOwned LWWMap

public protocol LWWMapOperations: ORMapWithResettableValue {
    /// Sets the `value` for `key`.
    mutating func set(forKey key: Key, value: Value)
}

// See comments in CRDT.ORSet
extension CRDT.ActorOwned where DataType: LWWMapOperations {
    public var lastObservedValue: [DataType.Key: DataType.Value] {
        self.data.underlying
    }

    public func set(forKey key: DataType.Key, value: DataType.Value, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
        // Set value for key locally then propagate
        self.data.set(forKey: key, value: value)
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.LWWMap {
    public static func owned<Message>(by owner: ActorContext<Message>, id: String, defaultValue: Value) -> CRDT.ActorOwned<CRDT.LWWMap<Key, Value>> {
        CRDT.ActorOwned<CRDT.LWWMap>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.LWWMap<Key, Value>(replicaId: .actorAddress(owner.address), defaultValue: defaultValue))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Aliases

// TODO: find better home for these type aliases

typealias LastWriterWinsMap = CRDT.LWWMap
