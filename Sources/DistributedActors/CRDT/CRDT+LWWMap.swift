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

import Foundation // for Date

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: LWWMap as pure CRDT

extension CRDT {
    public struct LWWMap<Key: Hashable, Value>: NamedDeltaCRDT {
        public typealias Delta = ORMapDelta<Key, LWWRegister<Value>>

        public let replicaId: ReplicaId

        var state: ORMap<Key, LWWRegister<Value>>

        public var delta: Delta? {
            return self.state.delta
        }

        public var underlying: [Key: Value] {
            return self.state._values.mapValues { $0.value }
        }

        public var keys: Dictionary<Key, Value>.Keys {
            return self.underlying.keys
        }

        public var values: Dictionary<Key, Value>.Values {
            return self.underlying.values
        }

        public var count: Int {
            return self.state.count
        }

        public var isEmpty: Bool {
            return self.state.isEmpty
        }

        init(replicaId: ReplicaId, defaultValue: Value) {
            self.replicaId = replicaId
            self.state = .init(replicaId: replicaId) {
                // This is relevant only in `ORMap.merge`, when `key` exists in `other` but not `self` and therefore we
                // must create a "zero" value before merging `other` into it.
                // The "zero" value's timestamp must "happen-before" `other`'s to allow `other` to win. If we just
                // use the current time `other` would never win.
                LWWRegister<Value>(replicaId: replicaId, initialValue: defaultValue, clock: .wallTime(WallTimeClock.zero))
            }
        }

        /// Accesses the value associated with the given `key` for reading and writing.
        ///
        /// - ***Warning**: If you assign `nil` as the value for the given `key`, the `LWWMap` removes that key by
        ///     calling `unsafeRemoveValue`, which might cause unexpected consequences.
        /// - SeeAlso: `LWWMap.unsafeRemoveValue(forKey:)`
        public subscript(key: Key) -> Value? {
            get {
                return self.state[key]?.value
            }

            set(value) {
                if let value = value {
                    self.state.update(key: key) { register in
                        register.assign(value)
                    }
                } else {
                    _ = self.unsafeRemoveValue(forKey: key)
                }
            }
        }

        /// Removes `key` and the associated value from the `LWWMap`.
        ///
        /// - ***Warning**: this erases the value's causal history and may cause anomalies!
        public mutating func unsafeRemoveValue(forKey key: Key) -> Value? {
            return self.state.unsafeRemoveValue(forKey: key)?.value
        }

        /// Removes all entries from the `LWWMap`.
        ///
        /// - ***Warning**: this erases all of the values' causal histories and may cause anomalies!
        public mutating func unsafeRemoveAllValues() {
            self.state.unsafeRemoveAllValues()
        }

        /// Resets value for `key` to `defaultValue` provided in `init`.
        public mutating func resetValue(forKey key: Key) {
            self.state.resetValue(forKey: key)
        }

        /// Resets all values in the `LWWMap` to `defaultValue` provided in `init`.
        public mutating func resetAllValues() {
            self.state.resetAllValues()
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
// MARK: Aliases

// TODO: find better home for these type aliases

typealias LastWriterWinsMap = CRDT.LWWMap
