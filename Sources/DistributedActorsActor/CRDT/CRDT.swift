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

import class NIO.EventLoopFuture

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Core CRDT protocols

/// Root type for all state-based CRDTs.
public protocol StateBasedCRDT {
    // State-based CRDT and CvRDT mean the same thing literally. This protocol is not necessary if the restriction of
    // the `CvRDT` protocol being used as a generic constraint only is lifted.
}

/// State-based CRDT aka Convergent Replicated Data Type (CvRDT).
///
/// The entire state is disseminated to replicas then merged, leading to convergence.
public protocol CvRDT: StateBasedCRDT {
    /// Merges the state of the given data type instance into this data type instance.
    ///
    /// `Self` type should be registered and (de-)serializable using the Actor serialization infrastructure.
    ///
    /// - SeeAlso: The framework's documentation on serialization for more information.
    ///
    /// - Parameter other: A data type instance to merge.
    mutating func merge(other: Self)
}

extension CvRDT {
    /// Creates a data type instance by merging the state of the given with this data type instance.
    ///
    /// `Self` type should be registered and (de-)serializable using the Actor serialization infrastructure.
    ///
    /// - SeeAlso: The framework's documentation on serialization for more information.
    ///
    /// - Parameter other: A data type instance to merge.
    /// - Returns: A new data type instance with the merged state of this data type instance and `other`.
    func merging(other: Self) -> Self {
        var result = self
        result.merge(other: other)
        return result
    }
}

extension CvRDT {
    internal var asAnyStateBasedCRDT: AnyStateBasedCRDT {
        return self.asAnyCvRDT
    }

    internal var asAnyCvRDT: AnyCvRDT {
        return AnyCvRDT(self)
    }
}

/// Delta State CRDT (ẟ-CRDT), a kind of state-based CRDT.
///
/// Incremental state (delta) rather than the entire state is disseminated as an optimization.
///
/// - SeeAlso: [Delta State Replicated Data Types](https://arxiv.org/abs/1603.01529)
/// - SeeAlso: [Efficient Synchronization of State-based CRDTs](https://arxiv.org/pdf/1803.02750.pdf)
public protocol DeltaCRDT: CvRDT {
    /// `Delta` type should be registered and (de-)serializable using the Actor serialization infrastructure.
    ///
    /// - SeeAlso: The framework's documentation on serialization for more information.
    associatedtype Delta: CvRDT

    var delta: Delta? { get }

    /// Merges the given delta into the state of this data type instance.
    ///
    /// - Parameter delta: The incremental, partial state to merge.
    mutating func mergeDelta(_ delta: Delta)

    // TODO: explain when this gets called
    /// Resets the delta of this data type instance.
    mutating func resetDelta()
}

extension DeltaCRDT {
    /// Creates a data type instance by merging the given delta with the state of this data type instance.
    ///
    /// - Parameter delta: The incremental, partial state to merge.
    /// - Returns: A new data type instance with the merged state of this data type instance and `delta`.
    func mergingDelta(_ delta: Delta) -> Self {
        var result = self
        result.mergeDelta(delta)
        return result
    }
}

extension DeltaCRDT {
    internal var asAnyStateBasedCRDT: AnyStateBasedCRDT {
        return self.asAnyDeltaCRDT
    }

    internal var asAnyDeltaCRDT: AnyDeltaCRDT {
        return AnyDeltaCRDT(self)
    }
}

/// Named ẟ-CRDT makes use of an identifier (e.g., replica ID) to change a specific part of the state.
///
/// - SeeAlso: [Delta State Replicated Data Types](https://arxiv.org/pdf/1603.01529.pdf)
public protocol NamedDeltaCRDT: DeltaCRDT {
    var replicaId: CRDT.ReplicaId { get }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Actor-owned CRDT

public enum CRDT {
    public enum Status {
        case active
        case deleted
    }

    public enum OperationConsistency: Equatable {
        case local
        case atLeast(Int)
        case quorum
        case all
    }

    /// Wrap around a `CvRDT` instance to associate it with an owning actor.
    public class ActorOwned<DataType: CvRDT> {
        // Must be an implicitly unwrapped optional variable property because it requires (`ActorOwned`) `self`
        // during initialization, and `ActorOwned`'s initializer has a dependency on `AnyOwnerCell`.
        internal var owner: AnyOwnerCell<DataType>! = nil
        let id: CRDT.Identity
        internal var data: DataType
        public internal(set) var status: Status = .active

        private let delegate: ActorOwnedDelegate<DataType>

        typealias RegisterResult = CRDT.ReplicationProtocol.OwnerCommand.RegisterResult
        typealias WriteResult = CRDT.ReplicationProtocol.OwnerCommand.WriteResult
        typealias ReadResult = CRDT.ReplicationProtocol.OwnerCommand.ReadResult
        typealias DeleteResult = CRDT.ReplicationProtocol.OwnerCommand.DeleteResult

        public init<Message>(ownerContext: ActorContext<Message>, id: CRDT.Identity, data: DataType, delegate: ActorOwnedDelegate<DataType> = ActorOwnedDelegate<DataType>()) {
            self.id = id
            self.data = data
            self.delegate = delegate

            let subReceive = ownerContext.subReceive(SubReceiveId(id.id), ReplicatedDataOwnerProtocol.self) { message in
                switch message {
                case .updated(let data):
                    guard let data = data as? DataType else {
                        throw Error.replicatedDataDoesNotMatchExpectedType
                    }
                    self.delegate.onUpdate(actorOwned: self, data: data)
                case .deleted:
                    self.delegate.onDelete(actorOwned: self)
                }
            }
            let replicator = ownerContext.system.replicator
            self.owner = AnyOwnerCell(subReceive: subReceive, replicator: replicator)

            // Register as owner of the CRDT with local replicator
            _ = replicator.ask(for: RegisterResult.self, timeout: .milliseconds(100)) { replyTo in
                .ownerCommand(.register(ownerRef: subReceive, id: id, data: data.asAnyStateBasedCRDT, replyTo: replyTo))
            }
        }

        // TODO: handle error instead of throw? convert replicator error to something else?

        internal func write(consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> Result<DataType> {
            let id = self.id
            let data = self.data
            let askResponse = owner.replicator.ask(for: WriteResult.self, timeout: timeout) { replyTo in
                .ownerCommand(.write(id: id, data: data.asAnyStateBasedCRDT, consistency: consistency, ownerRef: self.owner.subReceive, replyTo: replyTo))
            }
            // TODO: concurrency here is not safe (https://github.com/apple/swift-distributed-actors/pull/870#discussion_r2003206)
            return Result(askResponse.nioFuture.flatMapThrowing { (response) throws -> DataType in
                switch response {
                case .success:
                    self.delegate.onWriteSuccess(actorOwned: self)
                    return data
                case .failed(let error):
                    throw error
                }
            })
        }

        public func read(atConsistency consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> Result<DataType> {
            let id = self.id
            let askResponse = owner.replicator.ask(for: ReadResult.self, timeout: timeout) { replyTo in
                .ownerCommand(.read(id: id, consistency: consistency, ownerRef: self.owner.subReceive, replyTo: replyTo))
            }
            return Result(askResponse.nioFuture.flatMapThrowing { (response) throws -> DataType in
                switch response {
                case .success(let data):
                    guard let data = data as? DataType else {
                        throw Error.replicatedDataDoesNotMatchExpectedType
                    }
                    self.data = data
                    return data
                case .failed(let error):
                    throw error
                }
            })
        }

        public func deleteFromCluster(consistency: CRDT.OperationConsistency, timeout: TimeAmount) -> Result<Void> {
            let id = self.id
            let askResponse = owner.replicator.ask(for: DeleteResult.self, timeout: timeout) { replyTo in
                .ownerCommand(.delete(id: id, consistency: consistency, ownerRef: self.owner.subReceive, replyTo: replyTo))
            }
            return Result(askResponse.nioFuture.flatMapThrowing { (response) throws -> Void in
                switch response {
                case .success:
                    self.status = .deleted
                    return ()
                case .failed(let error):
                    throw error
                }
            })
        }

        internal struct AnyOwnerCell<DataType: CvRDT> {
            let subReceive: ActorRef<ReplicatedDataOwnerProtocol>
            let replicator: ActorRef<ReplicationProtocol>
        }

        public struct Result<DataType>: AsyncResult {
            let dataFuture: EventLoopFuture<DataType>

            init(_ dataFuture: EventLoopFuture<DataType>) {
                self.dataFuture = dataFuture
            }

            public func onComplete(_ callback: @escaping (Swift.Result<DataType, ExecutionError>) -> Void) {
                self.dataFuture.onComplete(callback)
            }

            public func withTimeout(after timeout: TimeAmount) -> Result<DataType> {
                return Result(self.dataFuture.withTimeout(after: timeout))
            }
        }

        public enum Error: Swift.Error {
            case replicatedDataDoesNotMatchExpectedType
        }
    }
}

extension CRDT.ActorOwned {
    /// Register callback for owning actor to be notified when the CRDT has been updated.
    ///
    /// Note that there can only be a single `onUpdate` callback for each `ActorOwned`. Multiple invocations of this
    /// method overwrite existing value, and the last write one wins.
    ///
    /// - Parameter callback: Invoked when the `ActorOwned` instance has been updated to perform any additional custom processing.
    public func onUpdate(_ callback: @escaping (CRDT.Identity, DataType) -> Void) {
        self.delegate.ownerDefinedOnUpdate = callback
    }

    /// Register callback for owning actor to be notified when the CRDT has been deleted.
    ///
    /// Note that there can only be a single `onDelete` callback for each `ActorOwned`. Multiple invocations of this
    /// method overwrite existing value, and the last write one wins.
    ///
    /// - Parameter callback: Invoked when the `ActorOwned` instance has been deleted to perform any additional custom processing.
    public func onDelete(_ callback: @escaping (CRDT.Identity) -> Void) {
        self.delegate.ownerDefinedOnDelete = callback
    }
}

extension CRDT {
    public class ActorOwnedDelegate<DataType: CvRDT> {
        // Callbacks defined by the owner
        var ownerDefinedOnUpdate: ((Identity, DataType) -> Void)?
        var ownerDefinedOnDelete: ((Identity) -> Void)?

        public init() {
        }

        // `ReplicatedDataOwnerProtocol.updated`
        func onUpdate(actorOwned: CRDT.ActorOwned<DataType>, data: DataType) {
            actorOwned.data = data
            self.ownerDefinedOnUpdate?(actorOwned.id, data)
        }

        // `ReplicatedDataOwnerProtocol.deleted`
        func onDelete(actorOwned: CRDT.ActorOwned<DataType>) {
            actorOwned.status = .deleted
            self.ownerDefinedOnDelete?(actorOwned.id)
        }

        // `OwnerCommand.WriteResult.success`
        func onWriteSuccess(actorOwned: CRDT.ActorOwned<DataType>) {
        }
    }

    public class ActorOwnedDeltaCRDTDelegate<DataType: DeltaCRDT>: ActorOwnedDelegate<DataType> {
        override func onWriteSuccess(actorOwned: CRDT.ActorOwned<DataType>) {
            actorOwned.data.resetDelta()
        }
    }
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
// MARK: CRDT.ReplicaId

extension CRDT {
    // TODO: actor address only? node? (https://github.com/apple/swift-distributed-actors/pull/870#discussion_r2003227)
    // The CRDT in ActorOwned should use actor address, but in Replicator we could potentially use node as an
    // optimization to save space. A drawback though is we would lose information about who did the updates.
    public enum ReplicaId: Hashable {
        case actorAddress(ActorAddress)
    }
}

extension CRDT.ReplicaId: CustomStringConvertible {
    public var description: String {
        switch self {
        case .actorAddress(let address):
            return "actor:\(address)"
        }
    }
}

extension CRDT.ReplicaId: Comparable {
    public static func <(lhs: CRDT.ReplicaId, rhs: CRDT.ReplicaId) -> Bool {
        switch (lhs, rhs) {
        case (.actorAddress(let l), .actorAddress(let r)):
            return l < r
        }
    }

    public static func ==(lhs: CRDT.ReplicaId, rhs: CRDT.ReplicaId) -> Bool {
        switch (lhs, rhs) {
        case (.actorAddress(let l), .actorAddress(let r)):
            return l == r
        }
    }
}

// TODO: active vs. passive owned-CRDT (start of thread: https://github.com/apple/swift-distributed-actors/pull/787/files#r1949368)
// Owned-CRDT has an owner (e.g., actor) and a "pure" CRDT (e.g., `CRDT.GCounter`). The owner has a reference
// to the local replicator, who is responsible for replicating pure CRDTs and/or their deltas to replicator on remote
// nodes.
//    - Each replicator knows about *all* of the pure CRDTs through gossiping.
//    - Owned-CRDT only knows the single pure CRDT that it owns.
//    - Pure CRDT has no knowledge of replicator or owner (actor).
//
// *** For delta-CRDT, a mutation updates both state and delta. ***
//
// When an owned-CRDT is mutated (e.g., incrementing a counter), it updates the pure CRDT that it encloses then tells
// the owner's [local] replicator about the changes. If the pure CRDT is a delta-CRDT, only the delta would
// be replicated. Otherwise, the entire pure CRDT would be replicated.
// When a remote replicator receives the update, it applies the change to its copy of the pure CRDT. How the change gets
// propagated to owned-CRDTs that are local to the replicator depends on whether they are active or passive.
//    - Replicator sends updates to active owned-CRDT automatically. i.e., the pure CRDT of an owned-CRDT gets updated
//      asynchronously, automatically. The current thinking is this is how we will provide feature similar to Akka's
//      ddata "subscribe".
//    - Replicator does NOT send update to passive owned-CRDT. Owned-CRDT needs to pull/read the latest pure CRDT from
//      the replicator.
//
// Consider an `Owned<GCounter>`'s increment method is called:
// 1. `Owned<GCounter>` [local]: call gcounter.increment(); this updates pure CRDT's state and delta.
// 2. `Owned<GCounter>` [local]: call owner.replicator(owned.pureCRDT); replicator will distribute the update according to the consistency level.
// 3. `Replicator` [local]: update its pure CRDT's state by calling local.mergeDelta(owned.delta).
// 4. `Replicator` [local]: update its pure CRDT's delta by calling local.delta.merge(owned.delta) (?)
// 5. `Replicator` [local]: send owned.delta to remote replicators based on consistency level.
// 6. `Replicator` [local]: send "write success" response to `Owned<GCounter>`.
// 7. `Replicator` [local]: find other `Owned<GCounter>`s associated with this pure CRDT and push them the updated pure CRDT. owned.merge(updatedCrdt)?
// 8. `Replicator` [remote]: update its pure CRDT's state by calling local.mergeDelta(incoming) (or local.merge(incoming) if not delta-CRDT).
// 9. `Replicator` [remote]: find local `Owned<GCounter>`s associated with this pure CRDT and push them the updated pure CRDT. owned.merge(updatedCrdt)?
// 10. `Owned<GCounter>` [local]: on "write success" call gcounter.resetDelta(); this signifies replicator has applied the change locally. TODO: worry about concurrent write?

// Gossip
// 1. `Replicator` [local]: for delta-CRDT send delta, otherwise send whole CRDT.
// 2. `Replicator` [remote]: update its pure CRDT's state by calling local.merge(incoming) or local.mergeDelta(incoming).
// 3. `Replicator` [remote]: find local `Owned<GCounter>`s associated with this pure CRDT and push them the updated pure CRDT. owned.merge(updatedCrdt)?
// 4. `Replicator` [local]: after gossiping, call local.resetDelta(). TODO: worry about concurrent write?
