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

/// State-based CRDT aka Convergent Replicated Data Type (CvRDT).
///
/// The entire state is disseminated to replicas then merged, leading to convergence.
public protocol CvRDT {
    /// Merges the state of this instance with another.
    ///
    /// `Self` type should be registered and (de-)serializable using the Actor serialization infrastructure.
    ///
    /// - SeeAlso: The framework's documentation on serialization for more information
    ///
    /// - Parameter other: The other CvRDT
    /// - Returns: `CvRDT` with the merged state
    mutating func merge(other: Self) -> Self
}

/// Delta State CRDT (ẟ-CRDT), a kind of state-based CRDT.
///
/// Incremental state (delta) rather than the entire state is disseminated as an optimization.
///
/// - SeeAlso: [Delta State Replicated Data Types](https://arxiv.org/abs/1603.01529)
/// - SeeAlso: [Efficient Synchronization of State-based CRDTs](https://arxiv.org/pdf/1803.02750.pdf)
public protocol DeltaCRDT: CvRDT {
    /// A delta group represents either a single delta mutation or several of them merged together
    /// (i.e., a join of several delta groups).
    ///
    /// `DeltaGroup` type should be registered and (de-)serializable using the Actor serialization infrastructure.
    ///
    /// - SeeAlso: The framework's documentation on serialization for more information
    associatedtype DeltaGroup: CvRDT

    /// Merges the delta group into the state of this instance.
    ///
    /// - Parameter delta: The incremental, partial state
    /// - Returns: `DeltaCRDT` with the merged state
    mutating func mergeDelta(_ delta: DeltaGroup) -> Self

    // TODO: explain when this gets called
    /// Resets delta.
    mutating func resetDelta() -> Self

    // TODO: delete?
    /// Computes the delta between this and the given instance.
    ///
    /// - Parameter other: The other `DeltaCRDT`
    /// - Returns: `Delta` between this and the other instance
    func delta(other: Self) -> DeltaGroup
}

/// Updates make use of an identifier (e.g., replica ID) to change a specific part of the state.
/// In [Delta State Replicated Data Types](https://arxiv.org/pdf/1603.01529.pdf) these are called "named CRDTs".
public protocol NamedCRDT {
    var replicaId: CRDT.ReplicaId { get }
}

public enum CRDT {
    public struct Identity {
        let id: String

        init(_ id: String) {
            self.id = id
        }
    }

    public enum ReplicaId: Hashable {
        case actorAddress(ActorAddress)
    }

    public enum OperationConsistency {
        case local
        case atLeast(Int)
        case quorum
        case all
    }

    public struct Result<Value>: AsyncResult {
        let answer: AskResponse<Value>

        init(_ answer: AskResponse<Value>) {
            self.answer = answer
        }

        public func onComplete(_ callback: @escaping (Swift.Result<Value, ExecutionError>) -> Void) {
            self.answer.onComplete(callback)
        }

        public func withTimeout(after timeout: TimeAmount) -> Result<Value> {
            return Result(self.answer.withTimeout(after: timeout))
        }
    }

    // TODO: to be implemented (https://github.com/apple/swift-distributed-actors/pull/787/files#r1945625)
    // "It will have to reach into swift-distributed-actors internals to be able to update the CRDT in place as well as
    // it'd have a ref like owner.replicator so we can send it requests to replicate our latest updates."
    public struct AnyOwnerCell<DataType: CvRDT> {
        func write(_ data: DataType, consistency: OperationConsistency) -> Result<DataType> {
            fatalError("To be implemented")
        }

        func read(atConsistency consistency: OperationConsistency) -> Result<DataType> {
            fatalError("To be implemented")
        }
    }

    /// Wrap around a `CvRDT` instance to associate it with an owner (e.g., actor).
    public struct ActorOwned<DataType: CvRDT> {
        let owner: AnyOwnerCell<DataType>
        var data: DataType

        init<Message>(owner: ActorContext<Message>, data: DataType) {
            self.owner = AnyOwnerCell() // TODO: make it work
            self.data = data
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
// When an owned-CRDT is mutated (e.g., incrementing a counter), it updates the pure CRDT that it encloses then asks
// the owner's [local] replicator to disseminate the changes. If the pure CRDT is a `DeltaCRDT`, only the delta would
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
// 1. `Owned<GCounter>` [local]: call gcounter.increment (i.e., update pure CRDT).
// 2. `Owned<GCounter>` [local]: ask owner.replicator to replicate, sending it the pure CRDT.
// 3. `Replicator` [local]: if pure CRDT is `DeltaCRDT`, tell it to compute delta.
// 4. `Replicator` [local]: update its own pure CRDT by calling gcounter.merge(owned).
// 5. `Replicator` [local]: distribute delta or pure CRDT to `Replicator` on other nodes by gossiping.
// 6. `Replicator` [remote]: apply update to its own CRDT by calling either pureCRDT.merge(incoming) or pureCRDT.mergeDelta(delta).
// 7. `Replicator` [remote]: find local `Owned<GCounter>`s associated with this pure CRDT and push them the updated pure CRDT.

// TODO: subscribe (https://github.com/apple/swift-distributed-actors/pull/787/files#r1942789)
// "read" is pull, "subscribe" is push. Akka provides both.
// Provide "subscribe" feature through active owned-CRDT (see above TODO)?
