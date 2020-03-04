//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Distributed Actors open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Distributed Actors project authors
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

/// Namespace for CRDT types.
public enum CRDT {
    public enum Status {
        case active
        case deleted
    }
}

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

        public init<Message>(ownerContext: ActorContext<Message>, id: CRDT.Identity, data: DataType, delegate: ActorOwnedDelegate<DataType> = ActorOwnedDelegate<DataType>()) {
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

            func continueAskResponseOnActorContext<Res>(_ future: AskResponse<Res>, continuation: @escaping (Result<Res, Swift.Error>) -> Void) {
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
            self._owner = ActorOwnedContext(
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
            replicator.tell(.localCommand(.register(ownerRef: subReceive, id: id, data: data.asAnyStateBasedCRDT, replyTo: nil)))
        }

        // TODO: handle error instead of throw? convert replicator error to something else?

        internal func write(consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
            let id = self.id
            let data = self.data

            // TODO: think more about timeouts: https://github.com/apple/swift-distributed-actors/issues/137
            let writeResponse = self.owner.replicator.ask(for: WriteResult.self, timeout: .effectivelyInfinite) { replyTo in
                .localCommand(.write(id, data.asAnyStateBasedCRDT, consistency: consistency, timeout: timeout, replyTo: replyTo))
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

        public func read(atConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<DataType> {
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

        public func deleteFromCluster(consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> OperationResult<Void> {
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
            let log: Logger
            let eventLoopGroup: MultiThreadedEventLoopGroup

            let subReceive: ActorRef<CRDT.Replication.DataOwnerMessage>
            let replicator: ActorRef<CRDT.Replicator.Message>

            // TODO: maybe possible to express as one closure?
            private let _onWriteComplete: (AskResponse<Replicator.LocalCommand.WriteResult>, @escaping (Result<Replicator.LocalCommand.WriteResult, Swift.Error>) -> Void) -> Void
            private let _onReadComplete: (AskResponse<Replicator.LocalCommand.ReadResult>, @escaping (Result<Replicator.LocalCommand.ReadResult, Swift.Error>) -> Void) -> Void
            private let _onDeleteComplete: (AskResponse<Replicator.LocalCommand.DeleteResult>, @escaping (Result<Replicator.LocalCommand.DeleteResult, Swift.Error>) -> Void) -> Void
            private let _onDataOperationResultComplete: (EventLoopFuture<DataType>, @escaping (Result<DataType, Swift.Error>) -> Void) -> Void
            private let _onVoidOperationResultComplete: (EventLoopFuture<Void>, @escaping (Result<Void, Swift.Error>) -> Void) -> Void

            init<M>(
                _ ownerContext: ActorContext<M>,
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
            ) -> OperationResult<DataType> {
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
            ) -> OperationResult<DataType> {
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
            ) -> OperationResult<Void> {
                let loop = self.eventLoopGroup.next()
                let promise = loop.makePromise(of: Void.self)
                self._onDeleteComplete(response) { result in
                    let result = onComplete(result)
                    promise.completeWith(result)
                }
                return OperationResult(promise.futureResult.map { _ in () }, safeOnComplete: self._onVoidOperationResultComplete)
            }
        }

        public struct OperationResult<DataType>: AsyncResult {
            let dataFuture: EventLoopFuture<DataType>

            private let _safeOnComplete: (EventLoopFuture<DataType>, @escaping (Result<DataType, Swift.Error>) -> Void) -> Void

            init(_ dataFuture: EventLoopFuture<DataType>, safeOnComplete: @escaping (EventLoopFuture<DataType>, @escaping (Result<DataType, Swift.Error>) -> Void) -> Void) {
                self.dataFuture = dataFuture
                self._safeOnComplete = safeOnComplete
            }

            public func _onComplete(_ callback: @escaping (Result<DataType, Swift.Error>) -> Void) {
                self.onComplete(callback)
            }

            public func onComplete(_ callback: @escaping (Result<DataType, Swift.Error>) -> Void) {
                self._safeOnComplete(self.dataFuture) { result in
                    callback(result)
                }
            }

            public func withTimeout(after timeout: TimeAmount) -> OperationResult<DataType> {
                OperationResult(self.dataFuture.withTimeout(after: timeout), safeOnComplete: self._safeOnComplete)
            }
        }

        public enum Error: Swift.Error {
            case AnyStateBasedCRDTDoesNotMatchExpectedType
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
// MARK: CRDT.Identity

extension CRDT {
    public struct Identity: Hashable {
        public let id: String

        public init(_ id: String) {
            self.id = id
        }
    }
}

extension CRDT.Identity: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: OperationConsistency

extension CRDT {
    public enum OperationConsistency {
        /// Perform operation in the local replica only.
        case local
        /// Perform operation in `.atLeast` replicas, including the local replica.
        case atLeast(Int)
        /// Perform operation in at least `n/2 + 1` replicas, where `n` is the total number of replicas in the
        /// cluster (at the moment the operation is issued), including the local replica.
        /// For example, when `n` is `4`, quorum would be `4/2 + 1 = 3`; when `n` is `5`, quorum would be `5/2 + 1 = 3`.
        case quorum
        /// Perform operation in all replicas.
        case all
    }
}

extension CRDT.OperationConsistency: Equatable {
    public static func == (lhs: CRDT.OperationConsistency, rhs: CRDT.OperationConsistency) -> Bool {
        switch (lhs, rhs) {
        case (.local, .local):
            return true
        case (.atLeast(let ln), .atLeast(let rn)):
            return ln == rn
        case (.quorum, .quorum):
            return true
        case (.all, .all):
            return true
        default:
            return false
        }
    }
}

extension CRDT.OperationConsistency {
    public enum Error: Swift.Error {
        case invalidNumberOfReplicasRequested(Int)
        case unableToFulfill(consistency: CRDT.OperationConsistency, localConfirmed: Bool, required: Int, remaining: Int, obtainable: Int)
        case tooManyFailures(allowed: Int, actual: Int)
        case remoteReplicasRequired
    }
}

extension CRDT.OperationConsistency.Error: Equatable {
    public static func == (lhs: CRDT.OperationConsistency.Error, rhs: CRDT.OperationConsistency.Error) -> Bool {
        switch (lhs, rhs) {
        case (.invalidNumberOfReplicasRequested(let lNum), .invalidNumberOfReplicasRequested(let rNum)):
            return lNum == rNum
        case (.unableToFulfill(let lConsistency, let lLocal, let lRequired, let lRemaining, let lObtainable), .unableToFulfill(let rConsistency, let rLocal, let rRequired, let rRemaining, let rObtainable)):
            return lConsistency == rConsistency && lLocal == rLocal && lRequired == rRequired && lRemaining == rRemaining && lObtainable == rObtainable
        case (.tooManyFailures(let lAllowed, let lActual), .tooManyFailures(let rAllowed, let rActual)):
            return lAllowed == rAllowed && lActual == rActual
        case (.remoteReplicasRequired, .remoteReplicasRequired):
            return true
        default:
            return false
        }
    }
}
