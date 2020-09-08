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

extension CRDT {
    public final class ActorableOwned<DataType: CvRDT> {
        let wrapped: ActorOwned<DataType>

        public init<OwnerActorable: Actorable>(
            ownerContext: OwnerActorable.Myself.Context,
            id: CRDT.Identity,
            data: DataType
        ) {
            self.wrapped = ActorOwned<DataType>(
                ownerContext: ownerContext._underlying,
                id: id,
                data: data
            )
        }

        public func read(atConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
            self.wrapped.read(atConsistency: consistency, timeout: timeout)
        }

        // FIXME: delete always at .all perhaps?
        public func deleteFromCluster(consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<Void> {
            self.wrapped.deleteFromCluster(consistency: consistency, timeout: timeout)
        }
    }
}

extension CRDT.ActorableOwned {
    /// Register callback for owning actor to be notified when the CRDT instance has been updated.
    ///
    /// Note that there can only be a single `onUpdate` callback for each `ActorOwned`. Multiple invocations of this
    /// method overwrite existing value, and the last written one wins.
    ///
    /// - Parameter callback: Invoked when the `ActorOwned` instance has been updated for the owner to perform any additional custom processing.
    public func onUpdate(_ callback: @escaping (CRDT.Identity, DataType) -> Void) {
        self.wrapped.onUpdate(callback)
    }

    /// Register callback for owning actor to be notified when the CRDT instance has been deleted.
    ///
    /// Note that there can only be a single `onDelete` callback for each `ActorOwned`. Multiple invocations of this
    /// method overwrite existing value, and the last written one wins.
    ///
    /// - Parameter callback: Invoked when the `ActorOwned` instance has been deleted for the owner to perform any additional custom processing.
    public func onDelete(_ callback: @escaping (CRDT.Identity) -> Void) {
        self.wrapped.onDelete(callback)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Owned GCounter

extension CRDT.ActorableOwned where DataType == CRDT.GCounter {
    public var lastObservedValue: Int {
        self.wrapped.lastObservedValue
    }

    public func increment(by amount: Int, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.wrapped.increment(by: amount, writeConsistency: consistency, timeout: timeout)
    }
}

extension CRDT.GCounter {
    public static func makeOwned<Act>(
        by owner: Act.Myself.Context, id: String
    ) -> CRDT.ActorableOwned<CRDT.GCounter> where Act: Actorable {
        let ownerAddress = owner.address
        return .init(ownerContext: owner, id: CRDT.Identity(id), data: .init(replicaID: .actorAddress(ownerAddress)))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Owned LWWMap

// See comments in CRDT.ORSet
extension CRDT.ActorableOwned where DataType: LWWMapOperations {
    public var lastObservedValue: [DataType.Key: DataType.Value] {
        self.wrapped.lastObservedValue
    }

    public func set(forKey key: DataType.Key, value: DataType.Value, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.wrapped.set(forKey: key, value: value, writeConsistency: consistency, timeout: timeout)
    }
}

extension CRDT.LWWMap {
    public static func makeOwned<Act, Key, Value>(
        by owner: Act.Myself.Context, id: String, defaultValue: Value
    ) -> CRDT.ActorableOwned<CRDT.LWWMap<Key, Value>> where Act: Actorable {
        let ownerAddress = owner.address
        return .init(ownerContext: owner, id: CRDT.Identity(id), data: .init(replicaID: .actorAddress(ownerAddress), defaultValue: defaultValue))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned LWWRegister

// See comments in CRDT.ORSet
extension CRDT.ActorableOwned where DataType: LWWRegisterOperations {
    public var lastObservedValue: DataType.Value {
        self.wrapped.lastObservedValue
    }

    public func assign(_ value: DataType.Value, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.wrapped.assign(value, writeConsistency: consistency, timeout: timeout)
    }
}

extension CRDT.LWWRegister {
    public static func makeOwned<Act>(
        by owner: Act.Myself.Context, id: String, initialValue: Value
    ) -> CRDT.ActorableOwned<CRDT.LWWRegister<Value>> where Act: Actorable {
        let ownerAddress = owner.address
        return CRDT.ActorableOwned<CRDT.LWWRegister>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.LWWRegister<Value>(replicaID: .actorAddress(ownerAddress), initialValue: initialValue))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Owned ORMap

extension CRDT.ActorableOwned where DataType: ORMapWithUnsafeRemove {
    /// Removes `key` and the associated value from the `ORMap`. Must achieve the given `writeConsistency` within
    /// `timeout` to be considered successful.
    ///
    /// - ***Warning**: This might cause anomalies! See `CRDT.ORMap` documentation for more details.
    public func unsafeRemoveValue(forKey key: DataType.Key, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.wrapped.unsafeRemoveValue(forKey: key, writeConsistency: consistency, timeout: timeout)
    }

    /// Removes all entries from the `ORMap`. Must achieve the given `writeConsistency` within `timeout` to be
    /// considered successful.
    ///
    /// - ***Warning**: This might cause anomalies! See `CRDT.ORMap` documentation for more details.
    public func unsafeRemoveAllValues(writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.wrapped.unsafeRemoveAllValues(writeConsistency: consistency, timeout: timeout)
    }
}

extension CRDT.ActorableOwned where DataType: ORMapWithResettableValue {
    public func resetValue(forKey key: DataType.Key, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.wrapped.resetValue(forKey: key, writeConsistency: consistency, timeout: timeout)
    }

    public func resetAllValues(writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.wrapped.resetAllValues(writeConsistency: consistency, timeout: timeout)
    }
}

// See comments in CRDT.ORSet
extension CRDT.ActorableOwned where DataType: ORMapOperations {
    public var lastObservedValue: [DataType.Key: DataType.Value] {
        self.wrapped.lastObservedValue
    }

    public func update(key: DataType.Key, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount, mutator: (inout DataType.Value) -> Void) -> CRDT.OperationResult<DataType> {
        self.wrapped.update(key: key, writeConsistency: consistency, timeout: timeout, mutator: mutator)
    }
}

extension CRDT.ORMap {
    public static func makeOwned<Act>(
        by owner: Act.Myself.Context, id: String, defaultValue: Value
    ) -> CRDT.ActorableOwned<CRDT.ORMap<Key, Value>> where Act: Actorable {
        let ownerAddress = owner.address
        return .init(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.ORMap<Key, Value>(replicaID: .actorAddress(ownerAddress), defaultValue: defaultValue))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned ORMultiMap

// See comments in CRDT.ORSet
extension CRDT.ActorableOwned where DataType: ORMultiMapOperations {
    public var lastObservedValue: [DataType.Key: Set<DataType.Value>] {
        self.wrapped.lastObservedValue
    }

    public func add(forKey key: DataType.Key, value: DataType.Value, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.wrapped.add(forKey: key, value: value, writeConsistency: consistency, timeout: timeout)
    }

    public func remove(forKey key: DataType.Key, value: DataType.Value, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.wrapped.remove(forKey: key, value: value, writeConsistency: consistency, timeout: timeout)
    }

    public func removeAll(forKey key: DataType.Key, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.wrapped.removeAll(forKey: key, writeConsistency: consistency, timeout: timeout)
    }
}

extension CRDT.ORMultiMap {
    public static func makeOwned<Act>(
        by owner: Act.Myself.Context, id: String
    ) -> CRDT.ActorableOwned<CRDT.ORMultiMap<Key, Value>> where Act: Actorable {
        let ownerAddress = owner.address
        return .init(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.ORMultiMap<Key, Value>(replicaID: .actorAddress(ownerAddress)))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Owned ORSet

// `CRDT.ORSet` is a generic type and we are not allowed to have `extension CRDT.ActorableOwned where DataType == ORSet`. As
// a result we introduce the `ORSetOperations` in order to bind `Element`. A workaround would be to add generic parameter
// to each method:
//
//     extension CRDT.ActorableOwned {
//         public func insert<Element: Hashable>(_ element: Element, ...) -> Result<DataType> where DataType == CRDT.ORSet<Element> { ... }
//     }
//
// But this does not work for `lastObservedValue`, which is a computed property.
extension CRDT.ActorableOwned where DataType: ORSetOperations {
    public var lastObservedValue: Set<DataType.Element> {
        self.wrapped.lastObservedValue
    }

    public func insert(_ element: DataType.Element, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.wrapped.insert(element, writeConsistency: consistency, timeout: timeout)
    }

    public func remove(_ element: DataType.Element, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.wrapped.remove(element, writeConsistency: consistency, timeout: timeout)
    }

    public func removeAll(writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.wrapped.removeAll(writeConsistency: consistency, timeout: timeout)
    }
}

extension CRDT.ORSet {
    public static func makeOwned<Act, Element>(
        by owner: Act.Myself.Context, id: String
    ) -> CRDT.ActorableOwned<CRDT.ORSet<Element>> where Act: Actorable {
        let ownerAddress = owner.address
        return .init(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.ORSet<Element>(replicaID: .actorAddress(ownerAddress)))
    }
}
