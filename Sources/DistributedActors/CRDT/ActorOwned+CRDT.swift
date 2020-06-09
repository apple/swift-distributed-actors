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

import Logging
import NIO

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor-owned CRDT

// Each owned-CRDT has an owner (e.g., actor) and a "pure" CRDT (e.g., `CRDT.GCounter`). The owner has a reference to
// the local replicator, who is responsible for replicating pure CRDTs and/or their deltas to replicator on remote nodes.
//  - Pure CRDT has no knowledge of the replicator or owner.
//  - Owned-CRDT only knows about the single pure CRDT that it owns. It communicates with the local replicator.
//  - A pure CRDT may have more than one owner. i.e., multiple owned-CRDTs might be associated with the same pure CRDT.
//  - Replicator knows about *all* of the pure CRDTs through gossiping and operation consistency requirements. It
//    also keeps track of each pure CRDT's owners. It distributes CRDT changes received from remote peers to local
//    owned-CRDTs by sending them notifications. This means an owned-CRDT should always have an up-to-date copy of the
//    pure CRDT automatically ("active" owned-CRDT).

extension CRDT {
    /// Wrap around a `CvRDT` instance to associate it with an owning actor.
    public class ActorOwned<DataType: CvRDT> {
        let id: CRDT.Identity
        var data: DataType

        var _owner: ActorOwnedContext<DataType>?
        var owner: ActorOwnedContext<DataType> {
            guard let o = self._owner else {
                fatalError("Attempted to unwrap \(self)._owner, which was nil! This should never happen.")
            }
            return o
        }

        public internal(set) var status: Status = .active

        private let delegate: ActorOwnedDelegate<DataType>

        typealias RegisterResult = CRDT.Replicator.LocalCommand.RegisterResult
        typealias WriteResult = CRDT.Replicator.LocalCommand.WriteResult
        typealias ReadResult = CRDT.Replicator.LocalCommand.ReadResult
        typealias DeleteResult = CRDT.Replicator.LocalCommand.DeleteResult

        public init<Message: ActorMessage>(
            ownerContext: ActorContext<Message>,
            id: CRDT.Identity,
            data: DataType,
            delegate: ActorOwnedDelegate<DataType> = ActorOwnedDelegate<DataType>()
        ) {
            self.id = id
            self.data = data
            self.delegate = delegate

            let subReceive = ownerContext.subReceive(SubReceiveId(id: id.id), CRDT.Replication.DataOwnerMessage.self) { message in
                switch message {
                case .updated(let data):
                    guard let data = data as? DataType else {
                        throw Error.AnyStateBasedCRDTDoesNotMatchExpectedType
                    }
                    self.delegate.onUpdate(actorOwned: self, data: data)
                case .deleted:
                    self.delegate.onDelete(actorOwned: self)
                }
            }

            let replicator = ownerContext.system.replicator

            func continueAskResponseOnActorContext<Res>(_ future: AskResponse<Res>, continuation: @escaping (Result<Res, Swift.Error>) -> Void) where Res: ActorMessage {
                ownerContext.onResultAsync(of: future, timeout: .effectivelyInfinite) { res in
                    continuation(res)
                    return .same
                }
            }
            func continueEventLoopFutureOnActorContext<Res>(_ future: EventLoopFuture<Res>, continuation: @escaping (Result<Res, Swift.Error>) -> Void) {
                ownerContext.onResultAsync(of: future, timeout: .effectivelyInfinite) { res in
                    continuation(res)
                    return .same
                }
            }
            self._owner = ActorOwnedContext<DataType>(
                ownerContext,
                subReceive: subReceive,
                replicator: replicator,
                onWriteComplete: continueAskResponseOnActorContext,
                onReadComplete: continueAskResponseOnActorContext,
                onDeleteComplete: continueAskResponseOnActorContext,
                onDataOperationResultComplete: continueEventLoopFutureOnActorContext,
                onVoidOperationResultComplete: continueEventLoopFutureOnActorContext
            )

            // Register as owner of the CRDT instance with local replicator
            replicator.tell(.localCommand(.register(ownerRef: subReceive, id: id, data: data, replyTo: nil)))
        }

        internal func write(consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
            let id = self.id
            let data = self.data

            // TODO: think more about timeouts: https://github.com/apple/swift-distributed-actors/issues/137
            let writeResponse = self.owner.replicator.ask(for: WriteResult.self, timeout: .effectivelyInfinite) { replyTo in
                .localCommand(.write(id, data, consistency: consistency, timeout: timeout, replyTo: replyTo))
            }

            return self.owner.onWriteComplete(writeResponse) {
                switch $0 {
                case .success(.success):
                    self.delegate.onWriteSuccess(actorOwned: self)
                    return .success(data)
                case .success(.failure(let error)):
                    self.owner.log.warning(
                        "Failed to update \(self.id): \(error)",
                        metadata: self.metadata()
                    )
                    return .failure(error) // TODO: configure if it should or not crash the actor?
                case .failure(let error):
                    self.owner.log.warning(
                        "Failed to update \(self.id): \(error)",
                        metadata: self.metadata()
                    )
                    return .failure(error) // TODO: configure if it should or not crash the actor?
                }
            }
        }

        public func read(atConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
            let id = self.id

            // TODO: think more about timeouts: https://github.com/apple/swift-distributed-actors/issues/137
            let readResponse = self.owner.replicator.ask(for: ReadResult.self, timeout: .effectivelyInfinite) { replyTo in
                .localCommand(.read(id, consistency: consistency, timeout: timeout, replyTo: replyTo))
            }

            // FIXME: inspect what happens to owning actor when we throw in here
            return self.owner.onReadComplete(readResponse) {
                switch $0 {
                case .success(.success(let data)):
                    guard let data = data as? DataType else {
                        return .failure(Error.AnyStateBasedCRDTDoesNotMatchExpectedType)
                    }
                    self.data = data
                    return .success(data)
                case .success(.failure(let readError)):
                    self.owner.log.warning(
                        "Failed to read(atConsistency: \(consistency), timeout: \(timeout.prettyDescription)), id: \(self.id): \(readError)",
                        metadata: self.metadata()
                    )
                    return .failure(readError) // TODO: configure if it should or not crash the actor?
                case .failure(let executionError):
                    self.owner.log.warning(
                        "Failed to read \(self.id): \(executionError)",
                        metadata: self.metadata()
                    )
                    return .failure(executionError) // TODO: configure if it should or not crash the actor?
                }
            }
        }

        // FIXME: delete always at .all perhaps?
        public func deleteFromCluster(consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<Void> {
            let id = self.id

            // TODO: think more about timeouts: https://github.com/apple/swift-distributed-actors/issues/137
            let deleteResponse = self.owner.replicator.ask(for: DeleteResult.self, timeout: .effectivelyInfinite) { replyTo in
                .localCommand(.delete(id, consistency: consistency, timeout: timeout, replyTo: replyTo))
            }

            return self.owner.onDeleteComplete(deleteResponse) {
                switch $0 {
                case .success:
                    self.status = .deleted
                    return .success(())
                case .failure(let error):
                    self.owner.log.warning(
                        "Failed to delete \(self): \(error)",
                        metadata: self.metadata()
                    )
                    return .failure(error) // TODO: configure if it should or not crash the actor?
                }
            }
        }

        internal struct ActorOwnedContext<DataType: CvRDT> {
            let log: LoggerWithSource
            let eventLoopGroup: MultiThreadedEventLoopGroup

            let subReceive: ActorRef<CRDT.Replication.DataOwnerMessage>
            let replicator: ActorRef<CRDT.Replicator.Message>

            // TODO: maybe possible to express as one closure?
            private let _onWriteComplete: (AskResponse<Replicator.LocalCommand.WriteResult>, @escaping (Result<Replicator.LocalCommand.WriteResult, Swift.Error>) -> Void) -> Void
            private let _onReadComplete: (AskResponse<Replicator.LocalCommand.ReadResult>, @escaping (Result<Replicator.LocalCommand.ReadResult, Swift.Error>) -> Void) -> Void
            private let _onDeleteComplete: (AskResponse<Replicator.LocalCommand.DeleteResult>, @escaping (Result<Replicator.LocalCommand.DeleteResult, Swift.Error>) -> Void) -> Void
            private let _onDataOperationResultComplete: (EventLoopFuture<DataType>, @escaping (Result<DataType, Swift.Error>) -> Void) -> Void
            private let _onVoidOperationResultComplete: (EventLoopFuture<Void>, @escaping (Result<Void, Swift.Error>) -> Void) -> Void

            init<OwnerMessage: ActorMessage>(
                _ ownerContext: ActorContext<OwnerMessage>,
                subReceive: ActorRef<Replication.DataOwnerMessage>,
                replicator: ActorRef<Replicator.Message>,
                onWriteComplete: @escaping (AskResponse<Replicator.LocalCommand.WriteResult>, @escaping (Result<Replicator.LocalCommand.WriteResult, Swift.Error>) -> Void) -> Void,
                onReadComplete: @escaping (AskResponse<Replicator.LocalCommand.ReadResult>, @escaping (Result<Replicator.LocalCommand.ReadResult, Swift.Error>) -> Void) -> Void,
                onDeleteComplete: @escaping (AskResponse<Replicator.LocalCommand.DeleteResult>, @escaping (Result<Replicator.LocalCommand.DeleteResult, Swift.Error>) -> Void) -> Void,
                onDataOperationResultComplete: @escaping (EventLoopFuture<DataType>, @escaping (Result<DataType, Swift.Error>) -> Void) -> Void,
                onVoidOperationResultComplete: @escaping (EventLoopFuture<Void>, @escaping (Result<Void, Swift.Error>) -> Void) -> Void
            ) {
                // not storing ownerContext on purpose; it always is a bit dangerous to store "someone's" context, for retain cycles and potential concurrency issues
                self.log = ownerContext.log
                self.eventLoopGroup = ownerContext.system._eventLoopGroup

                self.subReceive = subReceive
                self.replicator = replicator
                self._onWriteComplete = onWriteComplete
                self._onReadComplete = onReadComplete
                self._onDeleteComplete = onDeleteComplete
                self._onDataOperationResultComplete = onDataOperationResultComplete
                self._onVoidOperationResultComplete = onVoidOperationResultComplete
            }

            // Implementation note:
            // the dance with the stored `_on*Complete` and invoking through here is necessary to safely:
            // - keep type information of the results
            // - protect from concurrently writing to self;
            //
            // This is achieved by the `_on*Complete` functions being implemented by passing through the actor context, see: `continueOnActorContext`.
            // That guarantees we are "in the actor" when the callbacks run, which allows us to run the onComplete callbacks which DO modify the ActorOwned state
            // e.g. changing the `data` to the latest data after a write, or changing the owned status to deleted etc.
            //
            // We potentially could simplify these a bit; though the style of API here is not that typical so we choose not to:
            // we not only need to perform the callback on actor context, we also want to return a `OperationResult`, that users may await on if they wanted to.
            // That `OperationResult` must fire _after_ we applied the callback, and it should fire with the updated state; thus the promise dance we do below here.

            func onWriteComplete(
                _ response: AskResponse<Replicator.LocalCommand.WriteResult>,
                _ onComplete: @escaping (Result<Replicator.LocalCommand.WriteResult, Swift.Error>) -> Result<DataType, Swift.Error>
            ) -> CRDT.OperationResult<DataType> {
                let loop = self.eventLoopGroup.next()
                let promise = loop.makePromise(of: DataType.self)
                self._onWriteComplete(response) { result in
                    let result = onComplete(result)
                    promise.completeWith(result)
                }
                return OperationResult(promise.futureResult, safeOnComplete: self._onDataOperationResultComplete)
            }

            func onReadComplete(
                _ response: AskResponse<Replicator.LocalCommand.ReadResult>,
                _ onComplete: @escaping (Result<Replicator.LocalCommand.ReadResult, Swift.Error>) -> Result<DataType, Swift.Error>
            ) -> CRDT.OperationResult<DataType> {
                let loop = self.eventLoopGroup.next()
                let promise = loop.makePromise(of: DataType.self)
                self._onReadComplete(response) { result in
                    let result = onComplete(result)
                    promise.completeWith(result)
                }
                return OperationResult(promise.futureResult, safeOnComplete: self._onDataOperationResultComplete)
            }

            func onDeleteComplete(
                _ response: AskResponse<Replicator.LocalCommand.DeleteResult>,
                _ onComplete: @escaping (Result<Replicator.LocalCommand.DeleteResult, Swift.Error>) -> Result<Void, Swift.Error>
            ) -> CRDT.OperationResult<Void> {
                let loop = self.eventLoopGroup.next()
                let promise = loop.makePromise(of: Void.self)
                self._onDeleteComplete(response) { result in
                    let result = onComplete(result)
                    promise.completeWith(result)
                }
                return OperationResult(promise.futureResult.map { _ in () }, safeOnComplete: self._onVoidOperationResultComplete)
            }
        }

        public enum Error: Swift.Error {
            case AnyStateBasedCRDTDoesNotMatchExpectedType
        }
    }

    public struct OperationResult<DataType>: AsyncResult {
        private let dataFuture: EventLoopFuture<DataType>

        private let _safeOnComplete: (EventLoopFuture<DataType>, @escaping (Result<DataType, Swift.Error>) -> Void) -> Void

        init(_ dataFuture: EventLoopFuture<DataType>, safeOnComplete: @escaping (EventLoopFuture<DataType>, @escaping (Result<DataType, Swift.Error>) -> Void) -> Void) {
            self.dataFuture = dataFuture
            self._safeOnComplete = safeOnComplete
        }

        public func _onComplete(_ callback: @escaping (Result<DataType, Swift.Error>) -> Void) {
            self.onComplete(callback)
        }

        /// Executed when the operation completes.
        ///
        /// This callback executed on the owner actors context. It is safe to access the owner's internal state in this callback.
        public func onComplete(_ callback: @escaping (Result<DataType, Swift.Error>) -> Void) {
            self._safeOnComplete(self.dataFuture) { result in
                callback(result)
            }
        }

        public func withTimeout(after timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
            OperationResult(self.dataFuture.withTimeout(after: timeout), safeOnComplete: self._safeOnComplete)
        }
    }
}

extension CRDT.ActorOwned {
    /// Register callback for owning actor to be notified when the CRDT instance has been updated.
    ///
    /// Note that there can only be a single `onUpdate` callback for each `ActorOwned`. Multiple invocations of this
    /// method overwrite existing value, and the last written one wins.
    ///
    /// - Parameter callback: Invoked when the `ActorOwned` instance has been updated for the owner to perform any additional custom processing.
    public func onUpdate(_ callback: @escaping (CRDT.Identity, DataType) -> Void) {
        self.delegate.ownerDefinedOnUpdate = callback
    }

    /// Register callback for owning actor to be notified when the CRDT instance has been deleted.
    ///
    /// Note that there can only be a single `onDelete` callback for each `ActorOwned`. Multiple invocations of this
    /// method overwrite existing value, and the last written one wins.
    ///
    /// - Parameter callback: Invoked when the `ActorOwned` instance has been deleted for the owner to perform any additional custom processing.
    public func onDelete(_ callback: @escaping (CRDT.Identity) -> Void) {
        self.delegate.ownerDefinedOnDelete = callback
    }
}

extension CRDT {
    public class ActorOwnedDelegate<DataType: CvRDT> {
        // Callbacks defined by the owner
        var ownerDefinedOnUpdate: ((Identity, DataType) -> Void)?
        var ownerDefinedOnDelete: ((Identity) -> Void)?

        public init() {}

        // `DataOwnerMessage.updated`
        func onUpdate(actorOwned: CRDT.ActorOwned<DataType>, data: DataType) {
            // TODO: could we use equalState to prevent triggering more often than necessary? #633
//            guard !actorOwned.data.equalState(to: data) else {
//                actorOwned.data = data // merge because maybe deltas changed, but don't trigger onUpdate
//            }
            // state changed, notify the user handler
            actorOwned.data = data
            self.ownerDefinedOnUpdate?(actorOwned.id, data)
        }

        // `DataOwnerMessage.deleted`
        func onDelete(actorOwned: CRDT.ActorOwned<DataType>) {
            actorOwned.status = .deleted
            self.ownerDefinedOnDelete?(actorOwned.id)
        }

        // `OwnerCommand.WriteResult.success`
        func onWriteSuccess(actorOwned: CRDT.ActorOwned<DataType>) {}
    }

    public class ActorOwnedDeltaCRDTDelegate<DataType: DeltaCRDT>: ActorOwnedDelegate<DataType> {}
}

extension CRDT.ActorOwned where DataType: DeltaCRDT {
    public convenience init<Message>(ownerContext: ActorContext<Message>, id: CRDT.Identity, data: DataType) {
        self.init(ownerContext: ownerContext, id: id, data: data, delegate: CRDT.ActorOwnedDeltaCRDTDelegate<DataType>())
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Owned GCounter

extension CRDT.ActorOwned where DataType == CRDT.GCounter {
    public var lastObservedValue: Int {
        self.data.value
    }

    public func increment(by amount: Int, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        // Increment locally then propagate
        self.data.increment(by: amount)
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.GCounter {
    public static func makeOwned<Message>(by owner: ActorContext<Message>, id: String) -> CRDT.ActorOwned<CRDT.GCounter> {
        let ownerAddress = owner.address.ensuringNode(owner.system.settings.cluster.uniqueBindNode)
        return CRDT.ActorOwned<CRDT.GCounter>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.GCounter(replicaID: .actorAddress(ownerAddress)))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned LWWMap

// See comments in CRDT.ORSet
extension CRDT.ActorOwned where DataType: LWWMapOperations {
    public var lastObservedValue: [DataType.Key: DataType.Value] {
        self.data.underlying
    }

    public func set(forKey key: DataType.Key, value: DataType.Value, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        // Set value for key locally then propagate
        self.data.set(forKey: key, value: value)
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.LWWMap {
    public static func makeOwned<Message>(by owner: ActorContext<Message>, id: String, defaultValue: Value) -> CRDT.ActorOwned<CRDT.LWWMap<Key, Value>> {
        let ownerAddress = owner.address.ensuringNode(owner.system.settings.cluster.uniqueBindNode)
        return CRDT.ActorOwned<CRDT.LWWMap>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.LWWMap<Key, Value>(replicaID: .actorAddress(ownerAddress), defaultValue: defaultValue))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned LWWRegister

// See comments in CRDT.ORSet
extension CRDT.ActorOwned where DataType: LWWRegisterOperations {
    public var lastObservedValue: DataType.Value {
        self.data.value
    }

    public func assign(_ value: DataType.Value, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        // Assign value locally then propagate
        self.data.assign(value)
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.LWWRegister {
    public static func makeOwned<Message>(by owner: ActorContext<Message>, id: String, initialValue: Value) -> CRDT.ActorOwned<CRDT.LWWRegister<Value>> {
        let ownerAddress = owner.address.ensuringNode(owner.system.settings.cluster.uniqueBindNode)
        return CRDT.ActorOwned<CRDT.LWWRegister>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.LWWRegister<Value>(replicaID: .actorAddress(ownerAddress), initialValue: initialValue))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Owned ORMap

extension CRDT.ActorOwned where DataType: ORMapWithUnsafeRemove {
    /// Removes `key` and the associated value from the `ORMap`. Must achieve the given `writeConsistency` within
    /// `timeout` to be considered successful.
    ///
    /// - ***Warning**: This might cause anomalies! See `CRDT.ORMap` documentation for more details.
    public func unsafeRemoveValue(forKey key: DataType.Key, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        // Remove value associated with the given key locally then propagate
        _ = self.data.unsafeRemoveValue(forKey: key)
        return self.write(consistency: consistency, timeout: timeout)
    }

    /// Removes all entries from the `ORMap`. Must achieve the given `writeConsistency` within `timeout` to be
    /// considered successful.
    ///
    /// - ***Warning**: This might cause anomalies! See `CRDT.ORMap` documentation for more details.
    public func unsafeRemoveAllValues(writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        // Remove all values locally then propagate
        self.data.unsafeRemoveAllValues()
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.ActorOwned where DataType: ORMapWithResettableValue {
    public func resetValue(forKey key: DataType.Key, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        // Reset value associated with the given key locally then propagate
        self.data.resetValue(forKey: key)
        return self.write(consistency: consistency, timeout: timeout)
    }

    public func resetAllValues(writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        // Reset all values locally then propagate
        self.data.resetAllValues()
        return self.write(consistency: consistency, timeout: timeout)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: ActorOwned ORMultiMap

// See comments in CRDT.ORSet
extension CRDT.ActorOwned where DataType: ORMultiMapOperations {
    public var lastObservedValue: [DataType.Key: Set<DataType.Value>] {
        self.data.underlying
    }

    public func add(forKey key: DataType.Key, value: DataType.Value, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.data.add(forKey: key, value)
        return self.write(consistency: consistency, timeout: timeout)
    }

    public func remove(forKey key: DataType.Key, value: DataType.Value, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        self.data.remove(forKey: key, value)
        return self.write(consistency: consistency, timeout: timeout)
    }

    public func removeAll(forKey key: DataType.Key, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
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
// MARK: ActorOwned ORMap

// See comments in CRDT.ORSet
extension CRDT.ActorOwned where DataType: ORMapOperations {
    public var lastObservedValue: [DataType.Key: DataType.Value] {
        self.data.underlying
    }

    public func update(key: DataType.Key, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount, mutator: (inout DataType.Value) -> Void) -> CRDT.OperationResult<DataType> {
        // Apply mutator to the value associated with `key` locally then propagate
        self.data.update(key: key, mutator: mutator)
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.ORMap {
    public static func makeOwned<Message>(by owner: ActorContext<Message>, id: String, defaultValue: Value) -> CRDT.ActorOwned<CRDT.ORMap<Key, Value>> {
        let ownerAddress = owner.address.ensuringNode(owner.system.settings.cluster.uniqueBindNode)
        return CRDT.ActorOwned<CRDT.ORMap>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.ORMap<Key, Value>(replicaID: .actorAddress(ownerAddress), defaultValue: defaultValue))
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Owned ORSet

// `CRDT.ORSet` is a generic type and we are not allowed to have `extension CRDT.ActorOwned where DataType == ORSet`. As
// a result we introduce the `ORSetOperations` in order to bind `Element`. A workaround would be to add generic parameter
// to each method:
//
//     extension CRDT.ActorOwned {
//         public func insert<Element: Hashable>(_ element: Element, ...) -> Result<DataType> where DataType == CRDT.ORSet<Element> { ... }
//     }
//
// But this does not work for `lastObservedValue`, which is a computed property.
extension CRDT.ActorOwned where DataType: ORSetOperations {
    public var lastObservedValue: Set<DataType.Element> {
        self.data.elements
    }

    public func insert(_ element: DataType.Element, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        // Add element locally then propagate
        self.data.insert(element)
        return self.write(consistency: consistency, timeout: timeout)
    }

    public func remove(_ element: DataType.Element, writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        // Remove element locally then propagate
        self.data.remove(element)
        return self.write(consistency: consistency, timeout: timeout)
    }

    public func removeAll(writeConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> CRDT.OperationResult<DataType> {
        // Remove all elements locally then propagate
        self.data.removeAll()
        return self.write(consistency: consistency, timeout: timeout)
    }
}

extension CRDT.ORSet {
    public static func makeOwned<Message>(
        by owner: ActorContext<Message>, id: String
    ) -> CRDT.ActorOwned<CRDT.ORSet<Element>> {
        let ownerAddress = owner.address.ensuringNode(owner.system.settings.cluster.uniqueBindNode)
        return CRDT.ActorOwned<CRDT.ORSet>(ownerContext: owner, id: CRDT.Identity(id), data: CRDT.ORSet<Element>(replicaID: .actorAddress(ownerAddress)))
    }
}
